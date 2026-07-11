# Test helpers for the ADR-008 bounded-concurrency contract
# (tests/testthat/test-concurrency-contract.R).
#
# Two seams the scheduler exposes for deterministic testing without real
# concurrency, network, or wall-clock sleeps:
#   * permute_completion_order() forces the order child fetches COMPLETE while
#     the input catalog order is fixed, so a test can prove committed output is
#     byte-identical regardless of completion order (ADR-008 §0).
#   * local_inflight_probe() records the peak number of fetches simultaneously
#     in flight, so a test can assert the global worker cap is never exceeded.
# Both scope their state to the calling test frame (withr), auto-reset on exit.
#
# The index-body builders and the `expand_root()` harness are the same ones
# test-index-expansion.R uses; defining them here (a helper loaded before all
# test files) lets the contract file reuse them. test-index-expansion.R's own
# top-level copies shadow these within that file, so its behaviour is unchanged.

# Force child fetches to complete in `order` (a permutation of catalog
# positions) for the duration of the calling test. Sets the scheduler's
# `sitemapr.completion_order` seam; auto-restored when the test frame exits.
permute_completion_order <- function(order, env = parent.frame()) {
  withr::local_options(
    list(sitemapr.completion_order = as.integer(order)),
    .local_envir = env
  )
  invisible(order)
}

# Install an in-flight probe for the duration of the calling test. Returns a
# list with `peak_inflight()`, the largest number of fetches the scheduler
# dispatched concurrently (i.e. in one worker-cap window). Auto-removed on exit.
local_inflight_probe <- function(env = parent.frame()) {
  probe <- new.env(parent = emptyenv())
  probe$peak <- 0L
  withr::local_options(
    list(sitemapr.inflight_probe = probe),
    .local_envir = env
  )
  list(peak_inflight = function() as.integer(probe$peak))
}

# ---- index-body builders + expansion harness --------------------------------

urlset_xml <- function(...) {
  locs <- c(...)
  entries <- paste0("  <url><loc>", locs, "</loc></url>", collapse = "\n")
  paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n",
    entries,
    "\n</urlset>\n"
  )
}

index_xml <- function(...) {
  locs <- c(...)
  entries <- paste0(
    "  <sitemap><loc>",
    locs,
    "</loc></sitemap>",
    collapse = "\n"
  )
  paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n",
    entries,
    "\n</sitemapindex>\n"
  )
}

# Install a mock that serves `map` (URL -> XML string) and tracks fetched URLs.
# A URL absent from the map 404s. Returns the tracker environment.
local_index_server <- function(map, env = parent.frame()) {
  tracker <- new.env(parent = emptyenv())
  tracker$urls <- character(0)
  httr2::local_mocked_responses(
    function(req) {
      u <- req$url
      tracker$urls <- c(tracker$urls, u)
      body <- map[[u]]
      if (is.null(body)) {
        return(httr2::response(status_code = 404, url = u))
      }
      httr2::response(
        status_code = 200,
        url = u,
        headers = list("Content-Type" = "application/xml; charset=UTF-8"),
        body = charToRaw(body)
      )
    },
    env = env
  )
  tracker
}

# Parse a root index body to its child table, then expand it from depth 0.
expand_root <- function(root_url, root_body, ...) {
  children <- parse_sitemap_xml(charToRaw(root_body))$children
  expand_index(root_url, children, ...)
}

# Source records carry a wall-clock `timing` field: environmental noise that is
# not reproducible even between two sequential runs, so it is not part of the
# deterministic byte-identical contract (ADR-008 §0 is content + order). Zero it
# so the deterministic source content can be compared byte-for-byte.
stable_sources <- function(res) {
  if (!is.null(res$sources)) {
    res$sources$timing <- 0
  }
  res
}
