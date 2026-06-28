# Guessed-path discovery catalog (Discovery slice; docs/sitemap-spec.md §9).
#
# Pure data. `discovery_catalog()` returns the fixed, documented-order list of
# sitemap path guesses sitemapr tries against a site root. v1 discovery is the
# guessed-path catalog ONLY: robots.txt `Sitemap:` directives are deferred
# (ADR-002), so robots.txt never appears here and is never fetched.
#
# Order is contractual (SPEC §10): every GENERIC guess first, in the documented
# sequence, then the CMS-oriented guesses. The candidate builder joins these
# paths to the root and dedupes by full-URL identity, so a CMS entry whose path
# equals a generic one (Shopify `/sitemap.xml` == the generic `/sitemap.xml`)
# is intentionally retained here; the duplicate URL is collapsed downstream,
# not in the catalog. `/sitemap/` is deliberately absent (HTML/redirect noise).
#
# CMS coverage is WordPress + Shopify only for v1 (SPEC §31.3 open); broader CMS
# detection is tracked upstream.

# The generic guesses, in contractual order (docs/sitemap-spec.md §9).
discovery_generic_paths <- function() {
  c(
    "/sitemap.xml",
    "/sitemap_index.xml",
    "/sitemap-index.xml",
    "/sitemap.xml.gz",
    "/sitemap.txt",
    "/sitemap/index.xml",
    "/sitemaps.xml",
    "/news-sitemap.xml",
    "/sitemap-news.xml"
  )
}

# The settled CMS guesses as (path, source) pairs, in contractual order. Shopify
# reuses the generic `/sitemap.xml`; it is kept distinct here (source label) so
# provenance is explicit and URL-level dedup is the candidate builder's job.
discovery_cms_entries <- function() {
  list(
    list(path = "/wp-sitemap.xml", source = "wordpress"),
    list(path = "/sitemap.xml", source = "shopify")
  )
}

#' The guessed-path discovery catalog
#'
#' Returns the fixed catalog of sitemap path guesses, in contractual order:
#' every generic guess first (documented sequence), then the CMS-oriented
#' guesses. Each row carries the `path`, its `kind` (`"generic"` or `"cms"`),
#' and a `source` slug (`NA` for generic guesses, the CMS name for CMS guesses)
#' so an accepted candidate's reason can record the catalog match.
#'
#' The catalog is intentionally allowed to contain a path that also appears as a
#' generic guess (Shopify's `/sitemap.xml`); the duplicate URL it would produce
#' is collapsed by the candidate builder's full-URL dedup, not here. robots.txt
#' is not part of the catalog and is never consulted in v1 (ADR-002).
#'
#' @return A tibble with columns `path` (character), `kind` (character, one of
#'   `"generic"`/`"cms"`), and `source` (character, `NA` for generic). Generic
#'   rows precede CMS rows; rows are unique.
#' @keywords internal
#' @noRd
discovery_catalog <- function() {
  generic <- discovery_generic_paths()
  cms <- discovery_cms_entries()

  tibble::tibble(
    path = c(generic, vapply(cms, `[[`, character(1L), "path")),
    kind = c(rep("generic", length(generic)), rep("cms", length(cms))),
    source = c(
      rep(NA_character_, length(generic)),
      vapply(cms, `[[`, character(1L), "source")
    )
  )
}
