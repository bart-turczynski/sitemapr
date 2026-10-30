# sitemapr

R package. Parses XML, text and index sitemaps into tibbles and validates them
against Sitemap Protocol 0.9 and related W3C and RFC standards.

## Verification

Gate: local
Verify: .fleet-ci/gate auto

The merge gate is fleet-ci's local gate, run in the fleet image by the
pre-push hook (install it once per clone with `.fleet-ci/pre-push --install`);
its settings are `.fleet-ci.yml`. A diff against `main` that the classifier
calls docs-only (`docs/**/*.md`, `design/**/*.md` and the like) gets T0,
spelling and `pkgdown::check_pkgdown()`; any other gets T1, the cheap gates
and one `R CMD check`. Branch pushes, merge requests and pushes to `main`
create no pipeline, and an empty pipeline list is not a pass. CI runs
fleet-ci's template: T2 on the weekly `deep-check` schedule, T3 on a
`RELEASE=1` web pipeline and on the `v*` tag (seor ADR 0012; the event table
is in design/ci.md). A red gate is a red build. `man/` and `NAMESPACE` are
roxygen2-generated. air formats R at 80 columns on commit.

The gate refuses a push to `main` that adds more than one first-parent merge,
and skips a push to the local `backup` mirror (its URL is a path), so
`data-raw/backup.sh` mirrors without `--no-verify`.

## Vocabulary

**Finding** — a reason-coded validation result. The code set lives in
`docs/findings-registry.csv`, mirrored byte-identically in `inst/` and shared
with a sibling validator; a gate fails on drift.

**Layer** — a pipeline stage A–F. Code, docs and issues share that axis.

**Corpus** — `tests/testthat/fixtures/corpus/`: byte-sensitive fixtures with
BOMs, CRLF and UTF-16. The whitespace and line-ending hooks exclude it; leave
those bytes alone.

## Rules

Planning notes go in `_scratch/` (gitignored). `.fp/` is gitignored too, so the
`SITE-*` ids cited in `docs/` resolve only on this machine. Git follows the
house `agent-workflow` skill, and fp status changes stay decoupled from git
(the `fp` skill's `references/decoupling.md`).

The `.feature` files in `tests/testthat/` are frozen: no new `.feature` file or
scenario. New tests are plain testthat files in `tests/testthat/`. When a
scenario gets in the way of a change, replace it with a plain test that checks
the same outcome, then delete it.

A `NEWS.md` bullet is one terse line, only for a change a package user acts on
or notices. Where a standard decides it, cite the clause in a few words
("(RFC 3986 §2.2)"); add at most one issue or MR reference. No housekeeping
bullets (CI, gates, lint, spelling, metadata, agent files) and no Internal
section. The `news-terse` pre-push hook (`scripts/check-news.py`) enforces it.

For the tiers, the hook and the gaps the fleet-ci migration accepted, see
design/ci.md.
For the hygiene hooks, the gate's checks and tracker snapshots, see
docs/repo-hygiene.md.
For the layer model and output contracts, see docs/architecture.md.
For finding codes and the layer vocabulary, see docs/findings-contract.md.
For traps that made a gate report the wrong answer, see
docs/verification-traps.md.
For settled design decisions, see docs/decisions/.

## A red gate on an untouched tree

The gate runs in the image the fleet-ci pin names, so this machine's R
library cannot turn it red. A dependency that moved on CRAN can: the gate
resolves the dependencies afresh on every run. The pre-push
`check-toolchain` hook (`scripts/check-toolchain.R`) still checks this
machine, roxygen2 and pandoc against the pins, so that a local
`devtools::document()` or `build_readme()` writes what the gate accepts
(SEOR-tcytizic).

If the gate is red on a tree you have not touched, say so and keep the
evidence (`FLEET_GATE_KEEP=<dir>` keeps the container's output) rather than
assuming your change caused it.
