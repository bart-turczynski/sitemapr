# Bounded sitemapindex expansion (Index-expansion slice; architecture.md §4,
# docs/findings-contract.md INDEX_* codes).
#
# A top-level `sitemapindex` is expanded by fetching each child sitemap, parsing
# it, and attributing its rows to the child URL. Expansion is RECURSIVE but
# strictly bounded: a maximum depth, a per-index child-count cap, and cycle
# detection on the full-URL identity key together guarantee the traversal
# terminates and never materializes an unbounded global tree.
#
# Layering (architecture.md §3). This engine runs inside the parse API
# (`read_sitemap()` / `sitemap_tree()`), so the bounded-traversal events it
# detects are recorded as `problems` (the code-free parse companion), never as
# findings. The stable INDEX_* finding codes (INDEX_CYCLE_DETECTED,
# INDEX_DEPTH_EXCEEDED, INDEX_CHILD_COUNT_EXCEEDED, SITEMAP_INDEX_NESTED) are
# emitted later by `validate_sitemap()` (Layer F), which maps these problems to
# the findings contract.
#
# Reused internals (do NOT reimplement here):
#   fetch_source()          R/fetch.R          child fetch + metadata record
#   parse_dispatch()        R/read-sitemap.R   body bytes -> list(kind, rows, ...)
#   build_loc_key()         R/url.R            full-URL identity key
#   parse_url_adapter()     R/url.R            canonical URL component parse
#   parse_problems()        R/problems.R       problems companion constructor

#' Default limits for sitemapindex expansion
#'
#' Returns the configurable bounds the index-expansion engine applies while
#' recursively expanding a `sitemapindex`. Both are safety bounds, not protocol
#' rules: they keep a hostile or accidentally huge index tree from triggering an
#' unbounded burst of requests or unbounded recursion.
#'
#' `max_depth` counts levels below the root index: the root index is depth 0, its
#' children are depth 1, and an index whose children would land beyond
#' `max_depth` is not descended (an `INDEX_DEPTH_EXCEEDED` event). `max_children`
#' caps how many child entries a single index contributes after deduplication;
#' entries beyond the cap are dropped (an `INDEX_CHILD_COUNT_EXCEEDED` event).
#'
#' @param max_depth Maximum recursion depth below the root index (integer).
#'   Resolves from the argument, then `getOption("sitemapr.max_index_depth")`,
#'   then the default of 3.
#' @param max_children Maximum number of distinct child entries expanded per
#'   index (integer). Resolves from the argument, then
#'   `getOption("sitemapr.max_index_children")`, then the default of 50 000 (the
#'   sitemap-protocol per-index entry limit).
#' @return A named list of limits with coerced types.
#' @keywords internal
#' @noRd
index_limits <- function(
    max_depth = getOption("sitemapr.max_index_depth", 3L),
    max_children = getOption("sitemapr.max_index_children", 50000L)) {
  list(
    max_depth = as.integer(max_depth),
    max_children = as.integer(max_children)
  )
}

# Full-URL identity key for one URL: the canonical form used for cycle detection
# and child deduplication. Mirrors discovery's `build_loc_key(parse_url_adapter())`
# composition (R/discovery.R) so an index child and a discovery candidate that
# denote the same resource share a key.
index_loc_key <- function(url) {
  build_loc_key(parse_url_adapter(url))
}
