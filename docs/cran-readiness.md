# CRAN Readiness Notes

This note records local decisions for automated CRAN-readiness recommendations
that are advisory rather than hard `R CMD check` requirements.

## Test Coverage

`goodpractice` and `pkgcheck` recommend raising package coverage above the
current high-water mark, observed at roughly 98.3% during the
SITE-nveyjkps review. That recommendation is accepted as advisory for now.

The package already has broad unit, cucumber, fixture-corpus, and CRAN-check
coverage. The remaining uncovered branches are mostly defensive fallback paths
or generated report markup where extra tests would add maintenance cost without
meaningfully changing release risk. Nothing archives coverage automatically any
more — the CI `check` job does not run coverage (see below) — so a drop is only
visible if someone runs `Rscript tools/verify.R coverage`, which prints the full
covr summary and fails on any uncovered line.

## White-Box Test Access

Some tests intentionally call internal helpers with `sitemapr:::`. Those helpers
implement protocol-sensitive parsing, URL identity, SSRF classification, and
format sniffing behavior that is easier to verify directly than indirectly
through the public API. Exporting those helpers only to satisfy a style
recommendation would expand the package API without user benefit.

Keep new `:::` usage rare. Prefer public API tests when they can express the
same behavior clearly, and use direct internal tests only for small, stable
helpers whose edge cases would be obscured through the public entry points.

## Continuous Integration

**CI checks the package only after the fact.** `origin`'s `.gitlab-ci.yml`
has a `check` job that runs bare `Rscript tools/verify.R`, the same chain as the
pre-push hook. It also has `citation-version`, `pages` (builds and publishes the
pkgdown site so the documentation URL that `DESCRIPTION` declares resolves,
SITE-rysgulhf) and schedule-only `osv-audit` and `security-audit`. Pipelines
start only on pushes to `main`, tags and hand-started runs, so nothing runs on
a branch or merge request. A split pipeline with separate guard, lint,
coverage and readme jobs was proposed (SITE-fxkbboia) and dropped: seor's ADR
0005 folds cheap jobs into one to cut per-job runner overhead. The
repository once held a GitHub Actions workflow tree covering `R-CMD-check`,
pkgcheck, security and OSV audits, pkgdown and cross-platform checks, but the
account is permanently suspended, so that tree was deleted rather than left to
look like coverage it could not provide (SITE-kgpdfhoh; git history keeps it
restorable).

`Rscript tools/verify.R`, run by the pre-push hook, is therefore the only gate
in front of `main`, and there is no server-side branch protection behind it
(`only_allow_merge_if_pipeline_succeeds` is off). Treat a red gate as a red
build: CI's `check` job reruns the chain only once the change is on `main`.

This changes how one pkgcheck message must be read. `pkgcheck::pkgcheck()`
reports "Package has no continuous integration checks". That report is
stale in part: the `check` job now runs the tests and `R CMD check` on `main`.
It remains true that no CI runs on branches or merge requests, so treat the
message as a known, deliberate gap rather than a defect to explain away.

## Citation Metadata Names The Release

`CITATION.cff`'s `version:` and `.zenodo.json`'s `"version"` carry **the release
`DESCRIPTION`'s `Version` names** — `X.Y.Z` stays `X.Y.Z`, and `X.Y.Z.9000`
drops to `X.Y.Z`. sitemapr has never released, so the named release is `0.0.0`
and both files carry the development version `0.0.0.9000` verbatim, with no
`date-released` and no DOI. Every `http(s)` URL those two files declare must
also appear in `DESCRIPTION`'s `URL:` field.

**Move both files at the `DESCRIPTION` bump that opens a release cycle, not at
the tag.** They are part of the release, not a record of it.
`scripts/check-citation.py` enforces this from the pre-push hook and from the
`citation-version` CI job. The reasoning lives in seor's `design/adr/`, as
`0001-citation-metadata-names-the-release.md` and
`0002-citation-urls-are-the-ones-about-this-package.md`.

## Superassignment In Tests

Test callbacks should avoid `<<-` when ordinary lexical state is sufficient.
Use an explicit environment for request capture or counters inside mocked
callbacks; this keeps callback state visible without relying on superassignment.
