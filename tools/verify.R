# The project's verification chain, runnable locally without CI.
#
#   Rscript tools/verify.R             # the pre-push gate (the default stages)
#   Rscript tools/verify.R --all       # adds coverage + README
#   Rscript tools/verify.R lint check  # named stages only
#   Rscript tools/verify.R --list      # what stages exist
#
# This file is the SINGLE definition of the gate: `.pre-commit-config.yaml`'s
# pre-push `verify` hook invokes it with no arguments, so the hook and a manual
# run can never disagree about what "verified" means.
#
# It is also the ONLY gate that runs at all, anywhere. `origin` is GitLab and
# carries no CI config. There are no CI workflows: the repository once carried a
# GitHub Actions workflow tree, but that account is permanently suspended,
# so the tree was deleted rather than left to rot (SITE-kgpdfhoh — git history
# keeps it restorable). There is no server-side branch protection behind this
# either. Treat a failure here as a red build: nothing downstream will catch
# what this lets through.
#
# Stages run in declared order and the chain stops at the first failure, so the
# cheap guards (seconds) always report before the expensive ones (minutes).
#
# Two stages reach the network: `check` (--as-cran queries CRAN for incoming
# feasibility) and `readme` (pak resolves the dependency chain). Everything
# else is offline. A stage that needs the network must prove it RAN, not merely
# that it reported nothing -- see verify_assert_check_completed() below.

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
  # Runs with the manual built, so a manual-only problem is caught here
  # rather than at CRAN submission.
  check = list(
    label = "R CMD check --as-cran",
    default = TRUE,
    run = function() {
      res <- rcmdcheck::rcmdcheck(args = "--as-cran", error_on = "warning")
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
