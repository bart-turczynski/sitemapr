# Contributing

Install dependencies:

```sh
Rscript -e 'pak::local_install_deps(dependencies = TRUE)'
```

Run verification:

```sh
Rscript tools/check-docs.R && Rscript -e 'lints <- lintr::lint_package(); if (length(lints)) { print(lints); quit(status = 1) }' && Rscript -e 'rcmdcheck::rcmdcheck(args = "--as-cran", error_on = "warning")'
```

## Formatting

R code is formatted with [air](https://posit-dev.github.io/air/). Style and
exclusions live in `air.toml` (line width 80, to match lintr; `data-raw/` is
excluded, like `.lintr`). Install it and format before committing:

```sh
brew install air        # macOS; see the air docs for other platforms
air format .            # format the whole tree
air format --check .    # check mode: non-zero exit if anything is unformatted
```

The `air-format` pre-commit hook runs `air format` on staged R files at commit
time, so install air on your PATH after cloning. Editors with the air extension
(VS Code, Positron, etc.) can format on save using the same `air.toml`.

`man/` and `NAMESPACE` are roxygen2-generated. The generating version is pinned
in `DESCRIPTION` under `Config/roxygen2/version`; install that exact version so
`devtools::document()` is reproducible and contributors don't get spurious diffs:

```sh
Rscript -e 'pak::pak("roxygen2@8.0.0")'
```

`tools/check-docs.R` (run by the pre-push verify gate) enforces this: it fails
if the installed roxygen2 differs from the pin, or if regenerating the docs
changes any committed file under `man/` or `NAMESPACE`.

Source lives in `src/`, behavior features live in `features/`, tests live in `tests/`, and durable project context lives in `docs/`.

Keep local-only planning state in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or generated caches.

