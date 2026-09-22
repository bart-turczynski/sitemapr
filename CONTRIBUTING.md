# Contributing

Install dependencies:

```sh
Rscript -e 'pak::local_install_deps(dependencies = TRUE)'
```

Run verification:

```sh
Rscript tools/verify.R
```

That is the same chain the pre-push hook runs — docs, findings registry, lint,
`R CMD check --as-cran` — and the same chain `origin`'s `check` job runs on
every push to `main` (SITE-dzikrmnh). It is the first gate, and on a branch the
only one that runs on its own: branch and merge-request pipelines are no longer
created (SEOR-bmgkzhvy), so nothing runs between your push and the merge unless
you ask for it. You can — start a pipeline at **Build > Pipelines > Run
pipeline**, pick the branch, and the same `check` runs on the server. See
[docs/repo-hygiene.md](docs/repo-hygiene.md) for the individual stages and for
`--all`.

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

Source lives in `R/`, tests and their Cucumber `.feature` files live in
`tests/testthat/`, and durable project context lives in `docs/`.

Keep local-only planning state in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or generated caches.
