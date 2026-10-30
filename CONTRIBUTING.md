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

Verification is fleet-ci's local gate, which runs in the fleet Docker image
(settings in `.fleet-ci.yml`). Install the hooks once per clone, from the
package root:

```sh
pre-commit install
.fleet-ci/pre-push --install
```

From then on the gate runs on every push, on each pushed ref's tip, followed
by the pre-commit pre-push hooks. `pre-commit install -f` (which installs
both hook types, from `.pre-commit-config.yaml`'s
`default_install_hook_types`) and `pre-commit install -f --hook-type
pre-push` replace that hook and drop the gate; re-run
`.fleet-ci/pre-push --install` after either. Without `-f`,
`pre-commit install` keeps the gate (pre-commit's migration mode). To run the
gate by hand on `HEAD`:

```sh
.fleet-ci/gate auto
```

The gate checks the committed tree, never uncommitted edits. A docs-only
change runs spelling and `pkgdown::check_pkgdown()`; any other runs the docs
drift, findings-registry, R-floor, line-width, CRAN incoming, lint, URL,
README and NEWS checks, then `R CMD check --as-cran`. See
[design/ci.md](https://gitlab.com/bart-turczynski/sitemapr/-/blob/main/design/ci.md)
for the tiers and
[docs/repo-hygiene.md](https://gitlab.com/bart-turczynski/sitemapr/-/blob/main/docs/repo-hygiene.md)
for the individual checks.

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
Rscript -e 'pak::pak("roxygen2@8.1.1")'
```

The gate's docs drift check (`scripts/check-docs-drift.R`) enforces this. It
fails if the roxygen2 in the fleet image differs from the pin, or if
regenerating the docs changes `man/`, `NAMESPACE` or `DESCRIPTION`. It judges
the commit, not your working tree, so commit the output of
`devtools::document()` before you push.

Source lives in `R/`, tests and their Cucumber `.feature` files live in
`tests/testthat/`, and durable project context lives in `docs/`.
`ARCHITECTURE.md` is the entry point to it, and `design/` holds the maintainer
notes this file does not: the CRAN release deltas in
[`design/release-deltas.md`](https://gitlab.com/bart-turczynski/sitemapr/-/blob/main/design/release-deltas.md),
and the CI tiers and the local gate in
[`design/ci.md`](https://gitlab.com/bart-turczynski/sitemapr/-/blob/main/design/ci.md).

Keep local-only planning state in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets, dependency folders, build outputs, or generated caches.
