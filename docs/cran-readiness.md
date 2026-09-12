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
more — no CI job runs the suite (see below) — so a drop is only visible if
someone runs `Rscript tools/verify.R coverage`, which prints the full covr
summary and fails on any uncovered line.

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

**Nothing in CI checks the package code.** `origin`'s `.gitlab-ci.yml` holds
two jobs. `pages` builds and publishes the pkgdown site so the documentation
URL that `DESCRIPTION` declares actually resolves (SITE-rysgulhf).
`citation-version` runs `scripts/check-citation.py` on a Python image. Neither
runs tests, lint or `R CMD check`; a green pipeline there means the docs built
and the citation metadata agrees with `DESCRIPTION`, nothing more. A fuller
ported pipeline (guards, lint, docs, check, coverage, readme) is parked on
`feature/gitlab-ci-verify-pipeline` (SITE-fxkbboia) and is on hold. The
repository once held a GitHub Actions workflow tree covering `R-CMD-check`,
pkgcheck, security and OSV audits, pkgdown and cross-platform checks, but the
account is permanently suspended, so that tree was deleted rather than left to
look like coverage it could not provide (SITE-kgpdfhoh; git history keeps it
restorable).

`Rscript tools/verify.R`, run by the pre-push hook, is therefore the only gate
that checks the package itself, and there is no server-side branch protection
behind it. Treat a red gate as a red build: nothing downstream will catch what
it lets through.

This changes how one pkgcheck message must be read. `pkgcheck::pkgcheck()`
reports "Package has no continuous integration checks", and that report is
still substantively **correct** — no CI job runs the tests or `R CMD check`
— rather than a
token/access artefact. It was previously documented here as a local
false-negative to disregard; that explanation is obsolete and inverted. The
finding stands until a verifying pipeline actually runs, and it is an accepted,
deliberate gap rather than a defect to explain away.

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
