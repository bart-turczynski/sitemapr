# Sitemap discovery from a site root (Discovery slice; docs/sitemap-spec.md §9).
#
# Builds the ordered, deduplicated set of candidate sitemap URLs to try against
# a site root, from the guessed-path catalog (R/discovery-catalog.R). v1
# discovery is the guessed-path catalog only — robots.txt is never consulted
# (ADR-002). The fetch/classification of candidates into accepted/rejected rows
# is a later subtask; this file owns catalog -> candidate-URL assembly, full-URL
# deduplication, and the candidate-count cap.
#
# Reused internals (do NOT reimplement here):
#   create_source_records()  R/input.R  root -> normalized origin (as = "site")
#   parse_url_adapter()       R/url.R    canonical URL component parse
#   build_loc_key()           R/url.R    full-URL identity key for dedup
#   discovery_catalog()       R/discovery-catalog.R  ordered guess catalog

#' Default limits for discovery
#'
#' Returns the configurable limits applied while discovering candidates. The
#' candidate cap bounds how many distinct guessed-path candidates are evaluated
#' against a single site root (after deduplication), so a large catalog can
#' never trigger an unbounded burst of requests.
#'
#' @param max_candidates Maximum number of distinct candidates to evaluate.
#'   Resolves from the argument, then `getOption("sitemapr.max_candidates")`,
#'   then the default of 50.
#' @return A named list of limits with coerced types.
#' @keywords internal
#' @noRd
discovery_limits <- function(
    max_candidates = getOption("sitemapr.max_candidates", 50L)) {
  list(max_candidates = as.integer(max_candidates))
}

#' Build the ordered, deduplicated candidate set for a site root
#'
#' Joins each guessed-path catalog entry to the normalized origin of `root`,
#' producing absolute candidate URLs in catalog order (every generic guess
#' first, then CMS guesses). Candidates are deduplicated on the full-URL
#' identity key — keeping the first (catalog-order) occurrence — so a CMS entry
#' whose URL equals a generic one (Shopify's `/sitemap.xml`) yields a single
#' candidate and a single request. The candidate cap then truncates the list.
#'
#' The root is normalized through the shared site-entrypoint policy
#' (`create_source_records(as = "site")`): a schemeless root gets `https://`,
#' the host is IDNA/lower-cased, and any path/query/fragment is dropped to the
#' bare `scheme://host[:port]` origin before the catalog paths are appended.
#'
#' @param root A single site-root URL (character). A bare host is accepted.
#' @param catalog The guess catalog, as from `discovery_catalog()`.
#' @param limits Discovery limits, as from `discovery_limits()`.
#' @return A tibble with columns `candidate_url`, `catalog_path`, `kind`,
#'   `source`, and `loc_key`, ordered by catalog precedence, deduplicated on
#'   `loc_key`, and truncated to the candidate cap. A root that cannot be
#'   parsed raises the underlying `create_source_records()` classed error.
#' @keywords internal
#' @noRd
discovery_candidates <- function(root, catalog = discovery_catalog(),
                                 limits = discovery_limits()) {
  if (!is.character(root) || length(root) != 1L || is.na(root) ||
        !nzchar(root)) {
    rlang::abort(
      "`root` must be a single non-empty site-root URL.",
      class = "sitemapr_bad_input"
    )
  }

  root_rec <- create_source_records(root, as = "site")
  origin <- root_rec$normalized_url[[1L]]

  # Build the fetch URLs from the normalized origin + catalog paths. The origin
  # retains any explicit port; `rurl::clean_url` would drop a non-default port,
  # so the identity key (`build_loc_key`, which keeps the port) drives dedup.
  candidate_url <- paste0(origin, catalog$path)
  cand <- tibble::tibble(
    candidate_url = candidate_url,
    catalog_path = catalog$path,
    kind = catalog$kind,
    source = catalog$source,
    loc_key = build_loc_key(parse_url_adapter(candidate_url))
  )

  # Dedup on the full-URL identity, keeping the first (catalog-order) hit, THEN
  # enforce the candidate cap — mirroring create_source_records()' ordering.
  cand <- cand[!duplicated(cand$loc_key), , drop = FALSE]
  if (nrow(cand) > limits$max_candidates) {
    cand <- cand[seq_len(limits$max_candidates), , drop = FALSE]
  }

  tibble::as_tibble(cand)
}
