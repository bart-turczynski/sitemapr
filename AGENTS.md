# sitemapr

R package. Parses XML, text and index sitemaps into tibbles and validates them
against Sitemap Protocol 0.9 and related W3C and RFC standards.

## Toolchain

`Rscript tools/verify.R` is the single definition of "verified"; the pre-push
hook and CI both run it. Use it instead of a bare `devtools::check()`. `man/`
and `NAMESPACE` are roxygen2-generated against the 8.0.0 pin in `DESCRIPTION`.
air formats R at 80 columns on commit.

## Vocabulary

**Finding** — a reason-coded validation result. The code set lives in
`docs/findings-registry.csv`, shared with a sibling validator; a verify stage
fails on drift.

**Layer** — a pipeline stage A–F. Code, docs and issues share that axis.

**Corpus** — `tests/testthat/fixtures/corpus/`: byte-sensitive fixtures with
BOMs, CRLF and UTF-16. The whitespace and line-ending hooks exclude it; leave
those bytes alone.

## Rules

Planning notes go in `_scratch/`. Do not commit `_scratch/`, `.fp/`, secrets,
dependencies or build outputs.

`.fp/` is gitignored, so the tracker behind every `SITE-*` id cited in `docs/`
exists only on this machine.

For the verify gate, hook setup and tracker snapshots, see docs/repo-hygiene.md.
For the layer model and output contracts, see docs/architecture.md.
For finding codes and the layer vocabulary, see docs/findings-contract.md.
For settled design decisions, see docs/decisions/.

@FP_AGENTS.md
