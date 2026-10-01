# The project's verification chain, runnable locally without CI.
#
#   Rscript tools/verify.R             # the pre-push gate (the default stages)
#   Rscript tools/verify.R --all       # adds coverage + README
#   Rscript tools/verify.R lint check  # named stages only
#   Rscript tools/verify.R --list      # what stages exist
#   Rscript tools/verify.R --self-test # the gate's own offline self-tests
#
# This file is the SINGLE definition of the gate: `.pre-commit-config.yaml`'s
# pre-push `verify` hook invokes it with no arguments, so the hook and a manual
# run can never disagree about what "verified" means.
#
# It is also the only gate IN FRONT OF `main`. `origin` is GitLab; its
# `.gitlab-ci.yml` has a `check` job that runs this same chain (bare
# `Rscript tools/verify.R`), plus `citation-version`, `pages` and the
# schedule-only `osv-audit`/`security-audit`. But CI runs only on pushes to
# `main`, tags and hand-started pipelines, and merging does not wait on a green
# pipeline, so it is a second opinion after the fact, not a gate. The
# repository once carried a GitHub Actions workflow tree, but GitHub holds only
# a read-only mirror of `origin`, so the tree was deleted rather than left to
# rot (SITE-kgpdfhoh -- git history keeps it restorable). There is no
# server-side branch protection behind this either. Treat a failure here as a
# red build: nothing upstream of `main` will catch what this lets through.
#
# Stages run in declared order and the chain stops at the first failure, so the
# cheap guards (seconds) always report before the expensive ones (minutes).
#
# Three stages reach the network: `urls` (fetches every URL the package
# declares), `check` (--as-cran queries CRAN for incoming feasibility) and
# `readme` (pak resolves the dependency chain). Everything else is offline.
# A stage that needs the network must prove it RAN, not merely that it
# reported nothing -- see verify_assert_check_completed() and verify_urls()
# below.

# Assert that an `R CMD check` run actually REACHED ITS END.
#
# rcmdcheck derives `$errors`, `$warnings` and `$notes` by grepping the check
# stdout for the per-check result markers -- see `new_rcmdcheck()` in rcmdcheck
# 1.4.0, which builds all three with `grep("ERROR\n", entries)` and friends. A
# run that DIES before emitting any marker therefore yields three empty vectors,
# `error_on=` has nothing to fire on, and `rcmdcheck()` returns normally. The
# check stage would then report a green over a check that never ran.
#
# That is not hypothetical. On 2026-09-05 a timeout fetching CRAN's archive.rds
# halted the very FIRST check (`checking CRAN incoming feasibility`) and this
# stage still printed `ok`. Nothing else ran -- no install, no tests, no
# examples, no Rd checks -- and with no CI and no branch protection behind this
# gate, nothing downstream would have caught it (SITE-uzzefkgi).
#
# The terminal `Status:` line is the load-bearing assertion: `R CMD check`
# always emits one on a complete run, whatever its exit code, so it does not
# depend on how an aborted run happens to exit. `$status` and `$timeout` are
# cheaper signals for the same failure and are tested first purely so the
# message names the cause.
verify_assert_check_completed <- function(res) {
  if (isTRUE(res$timeout)) {
    stop("R CMD check timed out; nothing was verified.", call. = FALSE)
  }

  status <- suppressWarnings(as.integer(res$status))
  if (!identical(status, 0L)) {
    stop(
      sprintf(
        "R CMD check exited with status %s; the run did not complete.",
        format(res$status)
      ),
      call. = FALSE
    )
  }

  stdout <- if (is.character(res$stdout)) res$stdout else ""
  lines <- strsplit(stdout, "\n", fixed = TRUE)[[1L]]
  if (!any(grepl("^Status:", lines))) {
    cat(utils::tail(lines, 15L), sep = "\n")
    stop(
      "R CMD check emitted no terminal `Status:` line, so it aborted before ",
      "finishing. Reporting this stage clean would be a green over an unrun ",
      "check.",
      call. = FALSE
    )
  }

  invisible(res)
}

# Sort the rows `tools:::check_url_db()` returns into what they mean for the
# gate: "red" (a real defect: fail), "warn" (no answer at all: report, pass) or
# "exempt" (the one known, deliberate 404). Pure and offline, so
# verify_url_self_test() can pin it with a constructed data frame.
#
# check_url_db() returns only the URLs it objects to, one row each. Its
# `Status` column holds the HTTP status as a string when the server answered,
# and the literal "Error" when no HTTP exchange happened at all -- DNS failure,
# refused connection, timeout -- with libcurl's message in `Message` (read off
# `.check_http_A()` in R 4.6.0, and seen live: "libcurl error code 6: Could not
# resolve host"). A row can also carry no status and a static complaint
# instead (`Message` "Empty URL" or "Invalid URI scheme", or a non-empty
# `New`/`CRAN`/`Spaces`/`R` column: moved permanently, a non-canonical CRAN
# link, a space, an http:// r-project link). Those are defects in the text the
# package declares, and R CMD check reports them the same way it reports a 404.
#
# So only "Error" rows with no static complaint are downgraded to a warning: a
# transient network blip must never reject a push (the `check` stage learned
# that as SITE-xolykhjm). Everything else check_url_db() returns is red, except
# the exemption below. That includes 403, which R CMD check's incoming step
# drops by default (`_R_CHECK_URLS_TAKE_403_STATUS_AS_OK_`) because bot-shy
# hosts answer it; GitLab answers 403, not 404, for a project that does not
# exist, so here it stays a failure.
#
# The exemption. DESCRIPTION's BugReports keeps GitLab's `/-/issues` form,
# which 404s for a signed-out client since GitLab moved issues to
# `/-/work_items`. That is a fleet decision, not a defect: CRAN's incoming
# check string-tests BugReports for `/issues`, and a sibling package was
# archived at CRAN incoming for declaring `/-/work_items` (SEOR-ocbtrrnl;
# scripts/check-bugreports.py holds the split). So exactly that URL, in exactly
# that form, answering exactly 404, is exempt. Nothing else is.
verify_classify_urls <- function(bad, bugreports = NA_character_) {
  absent <- setdiff(c("URL", "Status", "Message"), names(bad))
  if (length(absent)) {
    stop(
      sprintf(
        "tools:::check_url_db() returned no %s column(s); its result shape ",
        toString(absent)
      ),
      "changed in this R release, so the URL check cannot be read.",
      call. = FALSE
    )
  }

  n <- nrow(bad)
  complaint <- function(col) {
    if (col %in% names(bad)) nzchar(bad[[col]]) else logical(n)
  }
  static <- complaint("New") |
    complaint("CRAN") |
    complaint("Spaces") |
    complaint("R")

  issues <- bugreports[
    !is.na(bugreports) & grepl("/-/issues/?$", bugreports)
  ]

  kind <- rep("red", n)
  kind[bad$Status == "Error" & !static] <- "warn"
  kind[bad$Status == "404" & bad$URL %in% issues & !static] <- "exempt"
  kind
}

# Pins verify_classify_urls() offline. The `urls` stage runs it before it
# touches the network, so a classifier edit that would wave a dead link
# through fails the gate on the spot; `Rscript tools/verify.R --self-test`
# runs it alone.
verify_url_self_test <- function() {
  br <- "https://gitlab.com/o/p/-/issues"
  wi <- "https://gitlab.com/o/p/-/work_items"
  row <- function(url, status, message = "", new = "") {
    data.frame(
      URL = url,
      Status = status,
      Message = message,
      New = new,
      CRAN = "",
      Spaces = "",
      R = ""
    )
  }
  cases <- list(
    list(row(br, "404", "Not Found"), br, "exempt"),
    list(row(br, "403", "Forbidden"), br, "red"), # the exemption is 404 only
    list(row(wi, "404", "Not Found"), wi, "red"), # and /-/issues form only
    list(row(br, "404", "Not Found"), NA_character_, "red"), # not BugReports
    list(row("https://x.example/", "404", "Not Found"), br, "red"),
    list(row("https://x.example/", "500", "Server Error"), br, "red"),
    list(row("https://nonexistent.invalid/", "Error", "error 6"), br, "warn"),
    list(row("https://10.255.255.1/", "Error", "error 28"), br, "warn"),
    list(
      row("https://x.example/a", "200", new = "https://x.example/b"),
      br,
      "red"
    ),
    list(row("", "", "Empty URL"), br, "red")
  )
  for (case in cases) {
    got <- verify_classify_urls(case[[1L]], case[[2L]])
    if (!identical(got, case[[3L]])) {
      stop(
        sprintf(
          "URL classifier self-test: %s (status %s, BugReports %s) gave %s, ",
          case[[1L]]$URL,
          case[[1L]]$Status,
          case[[2L]],
          toString(got)
        ),
        sprintf("expected %s.", case[[3L]]),
        call. = FALSE
      )
    }
  }
  if (length(verify_classify_urls(row(br, "404")[0L, ], br))) {
    stop(
      "URL classifier self-test: an empty result was not empty.",
      call. = FALSE
    )
  }
  invisible(TRUE)
}

# The `urls` stage: fetch every URL the package declares and fail on a dead
# one, which nothing else here does. `check` does fetch them -- --as-cran's
# `checking CRAN incoming feasibility` step calls this same check_url_db() --
# but a dead link there is only a NOTE, and `check` fails on warnings, not
# notes (`error_on = "warning"`). So the gate printed the dead link, passed,
# and CRAN incoming was the first thing to object.
#
# It reuses base R's own implementation -- the two unexported `tools`
# functions R CMD check calls -- rather than urlchecker, which wraps the same
# logic but would be one more dev dependency CI's `check` job must install.
# The price is that unexported functions may change without notice, so their
# absence, or a changed result shape, stops the stage with a message naming
# the fix instead of passing it silently.
#
# Like `check`, it has to prove it RAN: an empty URL db would mean the lookup
# read nothing, not that every URL is fine, so it fails, and the stage prints
# how many URLs it checked. `url_db_from_package_sources()` reads DESCRIPTION,
# man/, inst/CITATION, NEWS and README.md; vignettes count only once built to
# inst/doc, which a source tree lacks.
verify_urls <- function(dir = ".") {
  verify_url_self_test()

  fns <- c("url_db_from_package_sources", "check_url_db")
  ns <- asNamespace("tools")
  gone <- fns[!vapply(fns, exists, NA, envir = ns, inherits = FALSE)]
  if (length(gone)) {
    stop(
      sprintf(
        "%s no longer exist(s) in R %s, so the `urls` stage cannot ",
        toString(sprintf("tools:::%s()", gone)),
        getRversion()
      ),
      "run. Port it to urlchecker::url_check(), which wraps the same logic.",
      call. = FALSE
    )
  }
  url_db <- get(fns[[1L]], envir = ns)
  check_url_db <- get(fns[[2L]], envir = ns)

  db <- url_db(dir)
  urls <- unique(db$URL)
  if (!length(urls)) {
    stop(
      "found no URLs to check, yet DESCRIPTION declares several. The ",
      "lookup read nothing, so this stage verified nothing.",
      call. = FALSE
    )
  }

  # Each unanswered URL costs one timeout, sequentially; R's 60s default would
  # let a dead network hold a push for minutes only to warn at the end.
  old <- options(timeout = 30)
  on.exit(options(old), add = TRUE)
  bad <- check_url_db(db)

  bugreports <- read.dcf(file.path(dir, "DESCRIPTION"), "BugReports")[[1L]]
  kind <- verify_classify_urls(bad, bugreports)

  cat(sprintf(
    "  checked %d URL(s) from %s\n",
    length(urls),
    toString(unique(db$Parent))
  ))
  show <- function(which, heading) {
    rows <- bad[kind == which, , drop = FALSE]
    if (!nrow(rows)) {
      return(invisible())
    }
    cat(heading, "\n", sep = "")
    for (i in seq_len(nrow(rows))) {
      cat(sprintf(
        "    %s\n      status %s: %s (from %s)\n",
        rows$URL[[i]],
        if (nzchar(rows$Status[[i]])) rows$Status[[i]] else "-",
        gsub("[[:space:]]+", " ", rows$Message[[i]]),
        toString(unlist(rows$From[i]))
      ))
      if ("New" %in% names(rows) && nzchar(rows$New[[i]])) {
        cat(sprintf("      moved permanently to %s\n", rows$New[[i]]))
      }
    }
  }
  show(
    "exempt",
    paste(
      "  exempted (DESCRIPTION's BugReports keeps the CRAN-incoming /-/issues",
      "form by fleet decision, SEOR-ocbtrrnl):"
    )
  )
  show(
    "warn",
    "  WARNING, not reached (no HTTP status; network, not the URL):"
  )
  show("red", "  BROKEN:")

  red <- sum(kind == "red")
  if (red) {
    stop(sprintf("%d broken URL(s)", red), call. = FALSE)
  }
  invisible(bad)
}

verify_stages <- list(
  docs = list(
    label = "docs reproducible",
    default = TRUE,
    run = function() source("tools/check-docs.R")
  ),
  registry = list(
    label = "findings registry in sync",
    default = TRUE,
    run = function() source("tools/check-findings-registry.R")
  ),
  # Cheap, offline, and placed before lint/check because it answers a question
  # neither of those asks: `R CMD check --as-cran` never compares DESCRIPTION's
  # declared R floor against the floors its dependencies declare.
  rfloor = list(
    label = "declared R floor covers dependencies",
    default = TRUE,
    run = function() source("tools/check-r-floor.R")
  ),
  # Placed before lint because it explains a whole class of lint failure the
  # lint stage can only report one line at a time: air reformatting to a
  # width lintr rejects.
  linewidth = list(
    label = "air.toml and .lintr agree on line width",
    default = TRUE,
    run = function() source("tools/check-line-width.R")
  ),
  # `R CMD check` skips its DESCRIPTION spelling check on a machine with no
  # English aspell/hunspell dictionary, so a typo first shows up in
  # win-builder's incoming NOTE. spelling bundles its own hunspell dictionaries
  # and also reads man/, vignettes, README and NEWS (SEOR-mtbzfroz). Offline and
  # quick. Genuine terms go in inst/WORDLIST; a typo gets fixed at its source.
  spelling = list(
    label = "en-US spelling, genuine terms in inst/WORDLIST",
    default = TRUE,
    run = function() {
      bad <- spelling::spell_check_package()
      if (nrow(bad)) {
        print(bad)
        stop(sprintf("%d misspelled word(s)", nrow(bad)), call. = FALSE)
      }
    }
  ),
  # `lint_package()` alone is NOT enough: it skips `tools/`, which is
  # .Rbuildignore'd, so every script this gate is made of was exempt from the
  # gate's own lint stage until SITE-pzrosmkn. `lint_dir("tools")` closes that.
  # The two are run and reported separately because `c()` on two `lints`
  # objects drops the class and with it the useful print method.
  lint = list(
    label = "lintr on the package and tools/",
    default = TRUE,
    run = function() {
      found <- 0L
      for (lints in list(lintr::lint_package(), lintr::lint_dir("tools"))) {
        if (length(lints)) {
          print(lints)
          found <- found + length(lints)
        }
      }
      if (found) {
        stop(sprintf("%d lint(s)", found), call. = FALSE)
      }
    }
  ),
  # Seconds, but it needs the network, so it sits after every offline guard
  # and before `check`. A dead link (HTTP 4xx/5xx) fails; a URL that could not
  # be reached at all only warns, so a network blip never rejects a push. See
  # verify_urls() and verify_classify_urls().
  urls = list(
    label = "declared URLs resolve",
    default = TRUE,
    run = function() verify_urls()
  ),
  # `--no-manual` skips `checking PDF version of manual without index`, which
  # shells out to `texi2pdf`/`texi2dvi`. The dev machine has LaTeX installed,
  # so this stage used to build the manual and a manual-only problem would
  # have been caught here rather than at CRAN submission -- but the CI image
  # this same chain also runs under (`rocker/r-ver`, via `tools/verify.R` from
  # the `check` job in .gitlab-ci.yml, SITE-dzikrmnh) ships no LaTeX at all,
  # so that check ERRORs there on every push regardless of package content.
  # Ported from pagerankr's `.githooks/pre-push`, which hit and fixed the same
  # divergence. Losing PDF-manual coverage here is not a regression worth
  # keeping: a genuine Rd/LaTeX problem is still caught at CRAN submission
  # time (cran-comments.md / win-builder), which builds the manual too.
  #
  # `--as-cran`'s first step downloads CRAN's archive.rds, and R's default
  # download timeout is 60s. A stalled connection there halts the whole run
  # before a single result marker -- a false RED that rejects the push
  # (SITE-xolykhjm, seen three times on 2026-09-05, each retry passing in
  # seconds). It is not bandwidth: curl fetched that same 5,423,044-byte file
  # in 0.79s during a failing run. So the ceiling is raised for this gate's own
  # runs rather than left at a default tuned for interactive use.
  #
  # It has to travel as an environment variable: `R CMD check` runs in a child
  # R process, so `options(timeout=)` set here would not reach it, but the
  # child reads R_DEFAULT_INTERNET_TIMEOUT at startup. rcmdcheck merges a named
  # `env` onto `callr::rcmd_safe_env()`, so this adds one variable rather than
  # replacing that env.
  #
  # Raising it cannot mask a real failure: the run still has to reach a
  # terminal `Status:` line for this stage to report clean. A stall now costs
  # five minutes before it fails instead of one, which is the price of not
  # rejecting good pushes.
  check = list(
    label = "R CMD check --no-manual --as-cran",
    default = TRUE,
    run = function() {
      res <- rcmdcheck::rcmdcheck(
        args = c("--no-manual", "--as-cran"),
        error_on = "warning",
        env = c(R_DEFAULT_INTERNET_TIMEOUT = "300")
      )
      verify_assert_check_completed(res)
    }
  ),
  # Off by default -- it re-runs the whole test suite, roughly doubling the
  # chain -- but the project holds 100%, so a release-shaped run should
  # include it.
  coverage = list(
    label = "test coverage",
    default = FALSE,
    run = function() {
      cov <- covr::package_coverage()
      pct <- covr::percent_coverage(cov)
      zero <- covr::zero_coverage(cov)
      cat(sprintf("  coverage: %.5f%%\n", pct))
      if (nrow(zero)) {
        print(unique(zero[, c("filename", "functions", "line")]))
        stop(
          sprintf("%d uncovered line(s)", nrow(zero)),
          call. = FALSE
        )
      }
    }
  ),
  # Off by default. build_readme() installs the package into a temporary
  # library, resolving the dependency chain (sitemapr -> rurl) through pak, so
  # it needs network AND needs every `Remotes:` target to be publicly readable
  # -- a private GitLab project fails it with a pak 403, not a README problem.
  #
  # It is not the only networked stage, though this comment long claimed it
  # was: `check` runs --as-cran, whose `checking CRAN incoming feasibility`
  # step queries CRAN. That is what made SITE-uzzefkgi reachable.
  readme = list(
    label = "README.md in sync with README.Rmd",
    default = FALSE,
    run = function() {
      devtools::build_readme()
      diff <- system2(
        "git",
        c("diff", "--exit-code", "--", "README.md"),
        stdout = TRUE,
        stderr = TRUE
      )
      if (!identical(attr(diff, "status"), NULL)) {
        cat(diff, sep = "\n")
        stop(
          "README.md is out of sync; commit the re-rendered file.",
          call. = FALSE
        )
      }
    }
  )
)

verify_usage <- function() {
  cat("stages (default marked *):\n")
  for (nm in names(verify_stages)) {
    st <- verify_stages[[nm]]
    cat(sprintf("  %-9s %s %s\n", nm, if (st$default) "*" else " ", st$label))
  }
}

verify_selection <- function(args) {
  if ("--list" %in% args) {
    verify_usage()
    quit(status = 0)
  }
  if ("--self-test" %in% args) {
    verify_url_self_test()
    cat("self-test OK: URL classifier\n")
    quit(status = 0)
  }
  if ("--all" %in% args) {
    return(names(verify_stages))
  }
  named <- setdiff(args, "--all")
  if (length(named) == 0L) {
    return(Filter(
      function(nm) verify_stages[[nm]]$default,
      names(verify_stages)
    ))
  }
  unknown <- setdiff(named, names(verify_stages))
  if (length(unknown)) {
    cat(sprintf("unknown stage(s): %s\n\n", toString(unknown)))
    verify_usage()
    quit(status = 2)
  }
  named
}

verify_main <- function(args = commandArgs(trailingOnly = TRUE)) {
  selected <- verify_selection(args)
  started <- Sys.time()

  for (nm in selected) {
    stage <- verify_stages[[nm]]
    cat(sprintf("==> %s (%s)\n", nm, stage$label))
    at <- Sys.time()
    ok <- tryCatch(
      {
        stage$run()
        TRUE
      },
      error = function(e) {
        cat(sprintf("\nFAILED: %s -- %s\n", nm, conditionMessage(e)))
        FALSE
      }
    )
    took <- as.numeric(difftime(Sys.time(), at, units = "secs"))
    if (!ok) {
      cat(sprintf("verify FAILED at '%s' after %.0fs\n", nm, took))
      quit(status = 1)
    }
    cat(sprintf("    ok (%.0fs)\n", took))
  }

  cat(sprintf(
    "verify OK: %s (%.0fs)\n",
    toString(selected),
    as.numeric(difftime(Sys.time(), started, units = "secs"))
  ))
}

verify_main()
