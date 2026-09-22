# sitemapr

R package. Parses XML, text and index sitemaps into tibbles and validates them
against Sitemap Protocol 0.9 and related W3C and RFC standards.

## Toolchain

`Rscript tools/verify.R` — not a bare `devtools::check()` — is the single
definition of "verified": the pre-push hook invokes it, and `origin`'s `check`
job runs the same chain on every push to `main` (SITE-dzikrmnh). CI is not
created for branches or merge requests at all (SEOR-bmgkzhvy), so on a feature
branch the hook is the only thing that runs *by itself* — you can start a
pipeline by hand at Build > Pipelines > Run pipeline and pick the branch, and
`check` runs there. A red gate is a red build. `man/` and `NAMESPACE` are roxygen2-generated. air formats R at
80 columns on commit.

## Vocabulary

**Finding** — a reason-coded validation result. The code set lives in
`docs/findings-registry.csv`, mirrored byte-identically in `inst/` and shared
with a sibling validator; a verify stage fails on drift.

**Layer** — a pipeline stage A–F. Code, docs and issues share that axis.

**Corpus** — `tests/testthat/fixtures/corpus/`: byte-sensitive fixtures with
BOMs, CRLF and UTF-16. The whitespace and line-ending hooks exclude it; leave
those bytes alone.

## Rules

Planning notes go in `_scratch/` (gitignored). `.fp/` is gitignored too, so the
`SITE-*` ids cited in `docs/` resolve only on this machine.

For the verify gate, hook setup and tracker snapshots, see docs/repo-hygiene.md.
For the layer model and output contracts, see docs/architecture.md.
For finding codes and the layer vocabulary, see docs/findings-contract.md.
For traps that made a gate report the wrong answer, see
docs/verification-traps.md.
For settled design decisions, see docs/decisions/.

@FP_AGENTS.md
