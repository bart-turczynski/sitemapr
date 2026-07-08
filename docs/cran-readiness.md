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
meaningfully changing release risk. The GitHub `coverage` workflow continues to
print the full covr summary and archive Cobertura output so future drops remain
visible.

## White-Box Test Access

Some tests intentionally call internal helpers with `sitemapr:::`. Those helpers
implement protocol-sensitive parsing, URL identity, SSRF classification, and
format sniffing behavior that is easier to verify directly than indirectly
through the public API. Exporting those helpers only to satisfy a style
recommendation would expand the package API without user benefit.

Keep new `:::` usage rare. Prefer public API tests when they can express the
same behavior clearly, and use direct internal tests only for small, stable
helpers whose edge cases would be obscured through the public entry points.

## Superassignment In Tests

Test callbacks should avoid `<<-` when ordinary lexical state is sufficient.
Use an explicit environment for request capture or counters inside mocked
callbacks; this keeps callback state visible without relying on superassignment.
