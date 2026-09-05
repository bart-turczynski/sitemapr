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
more — there is no CI (see below) — so a drop is only visible if someone runs
`Rscript tools/verify.R coverage`, which prints the full covr summary and fails
on any uncovered line.

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

**There is none.** `origin` is GitLab and carries no CI config. The repository
once held a GitHub Actions workflow tree covering `R-CMD-check`, pkgcheck,
security and OSV audits, pkgdown and cross-platform checks, but the account is
permanently suspended, so that tree was deleted rather than left to look like
coverage it could not provide (SITE-kgpdfhoh; git history keeps it restorable).

`Rscript tools/verify.R`, run by the pre-push hook, is therefore the only gate
that runs at all, and there is no server-side branch protection behind it. Treat
a red gate as a red build: nothing downstream will catch what it lets through.

This changes how one pkgcheck message must be read. `pkgcheck::pkgcheck()`
reports "Package has no continuous integration checks", and that report is now
simply **correct** — it is an accurate finding about this repository, not a
token/access artefact. It was previously documented here as a local
false-negative to disregard; that explanation is obsolete and inverted. The
finding stands until CI actually exists somewhere, and it is an accepted,
deliberate gap rather than a defect to explain away.

## Superassignment In Tests

Test callbacks should avoid `<<-` when ordinary lexical state is sufficient.
Use an explicit environment for request capture or counters inside mocked
callbacks; this keeps callback state visible without relying on superassignment.
