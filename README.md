# sitemapr

One-sentence package purpose goes here.

## Setup

Install package dependencies (from `DESCRIPTION`) plus the dev tooling used by
the checks:

```sh
Rscript -e 'pak::local_install_deps(dependencies = TRUE)'
```

## Verification

```sh
Rscript -e 'lints <- lintr::lint_package(); if (length(lints)) { print(lints); quit(status = 1) }' && Rscript -e 'rcmdcheck::rcmdcheck(args = "--as-cran", error_on = "warning")'
```

`R CMD check` runs testthat plus the active top-level cucumber specs. The
feature files under `tests/testthat/features/` are pending v1 acceptance drafts
mapped to fp tracer-bullet tickets and should be activated as those tickets
land.

## Project Layout

- `R/` contains the package source.
- `man/` contains generated help pages (regenerate with `devtools::document()`).
- `NAMESPACE` and `man/` are roxygen2-generated — edit the roxygen comments in `R/`, not these.
- `tests/testthat/` contains testthat tests, active cucumber specs, and pending
  v1 acceptance drafts under `features/`.
- `vignettes/` contains long-form documentation.
- `DESCRIPTION` declares package metadata and dependencies.
- `docs/architecture.md` contains durable project context.
- `_scratch/` is local-only planning space and is ignored by git.
