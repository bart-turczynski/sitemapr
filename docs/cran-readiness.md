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
meaningfully changing release risk. CI's `coverage` job, in the weekly T2
deep check and every T3 release run, reports the figure and fails below the
fleet floor of 95%; nothing fails on a smaller drop or an uncovered line any
more (the former verify's opt-in `coverage` stage did; design/ci.md, "Gaps
accepted").

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

**CI checks the package on a schedule and at release, never per change.**
`origin`'s `.gitlab-ci.yml` includes fleet-ci's template (seor ADR 0012): the
weekly T2 deep check runs `R CMD check` on R release, oldrel, devel and the
4.1 floor, a locale leg, `--as-cran` with CRAN incoming, `coverage` (fails
below 95%), `osv-audit`, `security-audit` and `citation-version`; T3, a
`RELEASE=1` web pipeline or a `v*` tag, adds the PDF manual, and the tag
publishes the pkgdown site (SITE-rysgulhf). No push, branch or merge request
starts a pipeline (design/ci.md). The
repository once held a GitHub Actions workflow tree covering `R-CMD-check`,
pkgcheck, security and OSV audits, pkgdown and cross-platform checks, but
`origin` is GitLab and GitHub holds only a read-only mirror of it, so that tree
was deleted rather than left to look like coverage it could not provide
(SITE-kgpdfhoh; git history keeps it restorable). The README's pipeline and
coverage badges read this GitLab CI, not those workflows: seor's ADR 0007
reverses the old rule against CI badges (SEOR-dunwqfkj).

fleet-ci's local gate (`.fleet-ci/gate`), run by the pre-push hook in the
fleet Docker image, is therefore the only gate in front of `main`. `main` is a
protected branch (Maintainer-only push and merge), but nothing on the server
requires a passing pipeline (`only_allow_merge_if_pipeline_succeeds` is off).
Treat a red gate as a red build.

This changes how one pkgcheck message must be read. `pkgcheck::pkgcheck()`
reports "Package has no continuous integration checks". That report is
stale in part: the weekly T2 pipeline runs the tests and `R CMD check` on
`main`. It remains true that no CI runs on branches or merge requests, so
treat the message as a known, deliberate gap rather than a defect to explain
away.

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
`citation-version` CI job (T2 and T3). The reasoning lives in seor's `design/adr/`, as
`0001-citation-metadata-names-the-release.md` and
`0002-citation-urls-are-the-ones-about-this-package.md`.

## Superassignment In Tests

Test callbacks should avoid `<<-` when ordinary lexical state is sufficient.
Use an explicit environment for request capture or counters inside mocked
callbacks; this keeps callback state visible without relying on superassignment.
