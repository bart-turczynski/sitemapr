# The project's verification chain, runnable locally without CI.
#
#   Rscript tools/verify.R              # the pre-push gate (docs+registry+lint+check)
#   Rscript tools/verify.R --all        # everything CI runs, incl. coverage + README
#   Rscript tools/verify.R lint check   # named stages only
#   Rscript tools/verify.R --list       # what stages exist
#
# This file is the SINGLE definition of the gate: `.pre-commit-config.yaml`'s
# pre-push `verify` hook invokes it with no arguments, so the hook and a manual
# run can never disagree about what "verified" means. It deliberately mirrors
# .github/workflows/verify.yml job-for-job — see `verify_stages` — so a green
# local run predicts a green CI run. GitHub Actions is a backstop here, not the
# primary gate: server-side branch protection is unavailable on this plan, and
# the gate has to keep working while the remote is unreachable.
#
# Stages run in declared order and the chain stops at the first failure, so the
# cheap guards (seconds) always report before the expensive ones (minutes).

verify_stages <- list(
  # CI: verify.yml job "lint", step "Docs are reproducible"
  docs = list(
    label = "docs reproducible",
    default = TRUE,
    run = function() source("tools/check-docs.R")
  ),
  # CI: verify.yml job "lint", step "Findings registry in sync"
  registry = list(
    label = "findings registry in sync",
    default = TRUE,
    run = function() source("tools/check-findings-registry.R")
  ),
  # CI: verify.yml job "lint", step "Lint" (LINTR_ERROR_ON_LINT=true)
  lint = list(
    label = "lintr::lint_package()",
    default = TRUE,
    run = function() {
      lints <- lintr::lint_package()
      if (length(lints)) {
        print(lints)
        stop(sprintf("%d lint(s)", length(lints)), call. = FALSE)
      }
    }
  ),
  # CI: verify.yml job "check" (r-lib/actions/check-r-package, --as-cran,
  # error-on warning). Local runs keep the manual so a manual-only problem is
  # caught here rather than at CRAN submission.
  check = list(
    label = "R CMD check --as-cran",
    default = TRUE,
    run = function() {
      rcmdcheck::rcmdcheck(args = "--as-cran", error_on = "warning")
    }
  ),
  # CI: verify.yml job "coverage". Off by default -- it re-runs the whole test
  # suite, roughly doubling the chain -- but the project holds 100%, so a
  # release-shaped run should include it.
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
  # CI: verify.yml job "readme". Off by default, and the ONLY stage that needs
  # network access: build_readme() installs the package into a temporary
  # library, which resolves the GitHub-hosted dependency chain
  # (sitemapr -> rurl -> pslr) through pak. It therefore cannot run while
  # GitHub is unreachable -- it fails with a pak 403, not a README problem.
  # Every other stage is fully offline.
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
