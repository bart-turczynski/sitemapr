# Contributing

Report bugs and request features in the GitLab issue tracker:
<https://gitlab.com/bart-turczynski/sitemapr/-/work_items>. Report security issues
privately as described in `SECURITY.md`. Send changes as merge requests on
GitLab; the GitHub repository is a read-only mirror.

New code needs tests, and each user-facing change needs one `NEWS.md` bullet.
A merge request must pass the verification command below.

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
every push to `main` (SITE-dzikrmnh). See
[docs/repo-hygiene.md](https://gitlab.com/bart-turczynski/sitemapr/-/blob/main/docs/repo-hygiene.md)
for the individual stages and for `--all`.

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

The pre-push verify gate's `docs` stage enforces this. It exports the commit
being pushed with `git archive` and runs `scripts/check-docs-drift.R` (seor's
copy, vendored byte for byte; change it in seor) on the export. It fails if the
installed roxygen2 differs from the pin, or if regenerating the docs changes
`man/`, `NAMESPACE` or `DESCRIPTION`. It judges the commit, not your working
tree, so commit the output of `devtools::document()` before you push.

Source lives in `R/`, tests and their Cucumber `.feature` files live in
`tests/testthat/`, and durable project context lives in `docs/`.
`ARCHITECTURE.md` is the entry point to it, and `design/` holds the maintainer
notes this file does not: the CRAN release deltas in
[`design/release-deltas.md`](https://gitlab.com/bart-turczynski/sitemapr/-/blob/main/design/release-deltas.md),
and what CI runs on a branch in
[`design/ci-on-branches.md`](https://gitlab.com/bart-turczynski/sitemapr/-/blob/main/design/ci-on-branches.md).

Keep local-only planning state in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or generated caches.
