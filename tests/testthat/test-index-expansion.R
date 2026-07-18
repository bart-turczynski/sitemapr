test_that("index_limits() returns the documented defaults with correct types", {
  withr::local_options(list(
    sitemapr.max_index_depth = NULL,
    sitemapr.max_index_children = NULL
  ))

  lim <- index_limits()

  expect_identical(lim$max_depth, 3L)
  expect_identical(lim$max_children, 50000L)

  expect_type(lim$max_depth, "integer")
  expect_type(lim$max_children, "integer")
})

test_that("index_limits() arguments override the defaults", {
  withr::local_options(list(
    sitemapr.max_index_depth = NULL,
    sitemapr.max_index_children = NULL
  ))

  lim <- index_limits(max_depth = 1L, max_children = 2L)

  expect_identical(lim$max_depth, 1L)
  expect_identical(lim$max_children, 2L)
})

test_that("index_limits() falls back to sitemapr.* options", {
  withr::local_options(list(
    sitemapr.max_index_depth = 5L,
    sitemapr.max_index_children = 9L
  ))

  lim <- index_limits()

  expect_identical(lim$max_depth, 5L)
  expect_identical(lim$max_children, 9L)
})

test_that("index_loc_key() canonicalizes for cycle detection and dedup", {
  # Default port collapses to no port (identity-equivalent).
  expect_identical(
    index_loc_key("https://example.com:443/sitemap.xml"),
    index_loc_key("https://example.com/sitemap.xml")
  )
  # Query is significant (a paginated index child is a distinct resource).
  expect_false(identical(
    index_loc_key("https://example.com/sitemap.xml?page=1"),
    index_loc_key("https://example.com/sitemap.xml?page=2")
  ))
})

# ---- Recursive expansion engine ---------------------------------------------
#
# All fetches go through httr2's native mocking, so the real network is never
# hit (CRAN-safe). The dispatcher serves a URL -> XML-body map and records every
# requested URL so "fetched exactly once" can be asserted.

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
# Returns the tracker environment; a URL absent from the map 404s.
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

test_that("a two-child index expands both children with depth-1 provenance", {
  root <- "https://example.com/sitemap.xml"
  map <- list(
    "https://example.com/child-1.xml" = urlset_xml("https://example.com/a"),
    "https://example.com/child-2.xml" = urlset_xml("https://example.com/b")
  )
  local_index_server(map)

  res <- expand_root(root, index_xml(names(map)[[1]], names(map)[[2]]))

  expect_setequal(
    res$rows$loc,
    c("https://example.com/a", "https://example.com/b")
  )
  expect_identical(nrow(res$tree), 2L)
  expect_true(all(res$tree$depth == 1L))
  expect_true(all(res$tree$parent_sitemap == root))
  expect_true(all(res$tree$provenance == "child-of-index"))
  expect_true(all(res$tree$status == "accepted"))
  expect_identical(nrow(res$problems), 0L)
})

test_that("a throttle state paces index children on a shared host bucket", {
  # A virtual clock: records slept-for delays and advances, so the suite paces
  # the traversal deterministically without any real wall-clock sleep.
  cl <- new.env(parent = emptyenv())
  cl$t <- 1000
  cl$slept <- numeric(0)
  cl$now <- function() cl$t
  cl$sleep <- function(seconds) {
    cl$slept <- c(cl$slept, seconds)
    cl$t <- cl$t + seconds
  }

  root <- "https://example.com/sitemap.xml"
  map <- list(
    "https://example.com/child-1.xml" = urlset_xml("https://example.com/a"),
    "https://example.com/child-2.xml" = urlset_xml("https://example.com/b"),
    "https://example.com/child-3.xml" = urlset_xml("https://example.com/c")
  )
  local_index_server(map)

  state <- throttle_state_new(
    request_throttle(min_interval = 5),
    now = cl$now,
    sleep = cl$sleep
  )
  expand_root(
    root,
    index_xml(names(map)[[1]], names(map)[[2]], names(map)[[3]]),
    throttle_state = state
  )

  # All three children share the one example.com bucket: the first fetch is
  # free, each of the next two waits a full interval on the shared bucket.
  expect_identical(cl$slept, c(5, 5))
})

test_that("a duplicate child URL is fetched and expanded exactly once", {
  root <- "https://example.com/sitemap.xml"
  child <- "https://example.com/child.xml"
  map <- list()
  map[[child]] <- urlset_xml("https://example.com/a")
  tracker <- local_index_server(map)

  res <- expand_root(root, index_xml(child, child))

  expect_identical(sum(tracker$urls == child), 1L)
  expect_identical(nrow(res$tree), 1L)
  expect_identical(nrow(res$rows), 1L)
})

test_that("a self-referential index is detected and not followed", {
  root <- "https://example.com/sitemap.xml"
  tracker <- local_index_server(list()) # root never re-fetched

  res <- expand_root(root, index_xml(root))

  expect_false(root %in% tracker$urls)
  expect_true(any(
    res$problems$category == "index-expansion" &
      grepl("cycle", res$problems$message, fixed = TRUE)
  ))
  expect_true(any(res$tree$reason == "cycle"))
})

test_that("an A -> B -> A cross-index cycle terminates without recursion", {
  a <- "https://example.com/a.xml"
  b <- "https://example.com/b.xml"
  map <- list()
  map[[b]] <- index_xml(a) # B points back at A
  tracker <- local_index_server(map)

  res <- expand_root(a, index_xml(b))

  # B is fetched once; the loop back to A is caught, A is never fetched.
  expect_identical(sum(tracker$urls == b), 1L)
  expect_false(a %in% tracker$urls)
  expect_true(any(grepl("cycle", res$problems$message, fixed = TRUE)))
})

test_that("the recursion depth limit is enforced; deeper nodes unfetched", {
  root <- "https://example.com/root.xml"
  lvl1 <- "https://example.com/lvl1.xml" # depth 1 (accepted, nested)
  lvl2 <- "https://example.com/lvl2.xml" # depth 2 -> exceeds max_depth 1
  map <- list()
  map[[lvl1]] <- index_xml(lvl2)
  map[[lvl2]] <- urlset_xml("https://example.com/deep")
  tracker <- local_index_server(map)

  res <- expand_root(
    root,
    index_xml(lvl1),
    limits = index_limits(max_depth = 1L)
  )

  expect_true(lvl1 %in% tracker$urls)
  expect_false(lvl2 %in% tracker$urls)
  expect_true(any(grepl("depth limit", res$problems$message, fixed = TRUE)))
  expect_true(any(res$tree$reason == "depth-exceeded"))
})

test_that("the per-index child-count cap truncates and records one event", {
  root <- "https://example.com/sitemap.xml"
  c1 <- "https://example.com/c1.xml"
  c2 <- "https://example.com/c2.xml"
  c3 <- "https://example.com/c3.xml"
  map <- list()
  map[[c1]] <- urlset_xml("https://example.com/1")
  map[[c2]] <- urlset_xml("https://example.com/2")
  map[[c3]] <- urlset_xml("https://example.com/3")
  tracker <- local_index_server(map)

  res <- expand_root(
    root,
    index_xml(c1, c2, c3),
    limits = index_limits(max_children = 2L)
  )

  expect_length(tracker$urls, 2L)
  expect_true(any(grepl("cap", res$problems$message, fixed = TRUE)))
})

test_that("a child the SSRF guard blocks is recorded as unfetchable", {
  # fetch_source aborts (sitemapr_ssrf_blocked) before any network call when a
  # child resolves to a blocked address; expansion catches it, records a fetch
  # problem, and marks the tree node rejected/unfetchable rather than crashing.
  root <- "https://example.com/sitemap.xml"
  blocked <- "http://127.0.0.1/child.xml"
  local_index_server(list()) # child never reaches the network

  res <- expand_root(root, index_xml(blocked))

  expect_identical(nrow(res$tree), 1L)
  expect_identical(res$tree$status, "rejected")
  expect_identical(res$tree$reason, "unfetchable")
  expect_true(any(
    res$problems$category == "fetch" &
      grepl("could not be fetched", res$problems$message, fixed = TRUE)
  ))
  expect_identical(nrow(res$rows), 0L)
})

test_that("an index with no children yields an empty tree", {
  # A childless <sitemapindex> (built inline; index_xml() with no args would
  # instead emit a single empty-<loc> child). With nothing to iterate, the
  # accumulator stays empty and the engine returns the empty-tree template.
  root <- "https://example.com/sitemap.xml"
  empty_index <- paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n",
    "</sitemapindex>\n"
  )
  local_index_server(list())

  res <- expand_root(root, empty_index)

  expect_identical(nrow(res$tree), 0L)
  expect_identical(colnames(res$tree), colnames(empty_sitemap_tree()))
  expect_identical(nrow(res$rows), 0L)
})

test_that("index_limits() defaults to no aggregate budget (Inf)", {
  withr::local_options(list(
    sitemapr.max_total_sitemaps = NULL,
    sitemapr.max_total_urls = NULL
  ))

  lim <- index_limits()

  expect_identical(lim$max_total_sitemaps, Inf)
  expect_identical(lim$max_total_urls, Inf)
  expect_type(lim$max_total_sitemaps, "double")
  expect_type(lim$max_total_urls, "double")
})

test_that("max_total_sitemaps stops at the exact total with a partial result", {
  root <- "https://example.com/sitemap.xml"
  c1 <- "https://example.com/c1.xml"
  c2 <- "https://example.com/c2.xml"
  c3 <- "https://example.com/c3.xml"
  map <- list()
  map[[c1]] <- urlset_xml("https://example.com/1")
  map[[c2]] <- urlset_xml("https://example.com/2")
  map[[c3]] <- urlset_xml("https://example.com/3")
  tracker <- local_index_server(map)

  res <- expand_root(
    root,
    index_xml(c1, c2, c3),
    limits = index_limits(max_total_sitemaps = 2)
  )

  # Exactly two child sitemaps fetched; the third is never requested.
  expect_length(tracker$urls, 2L)
  expect_false(c3 %in% tracker$urls)
  # Partial result is internally consistent: sources, tree, and rows all align.
  expect_identical(nrow(res$sources), 2L)
  expect_identical(nrow(res$tree), 2L)
  expect_true(all(res$tree$status == "accepted"))
  expect_setequal(
    res$rows$loc,
    c("https://example.com/1", "https://example.com/2")
  )
  # The partial-result problem is exposed for later finding mapping.
  expect_true(any(
    res$problems$category == "index-expansion" &
      grepl("Aggregate sitemap budget", res$problems$message, fixed = TRUE)
  ))
})

test_that("max_total_urls stops at the exact total, leaving rows consistent", {
  root <- "https://example.com/sitemap.xml"
  c1 <- "https://example.com/c1.xml"
  c2 <- "https://example.com/c2.xml"
  c3 <- "https://example.com/c3.xml"
  map <- list()
  map[[c1]] <- urlset_xml("https://example.com/1", "https://example.com/2")
  map[[c2]] <- urlset_xml("https://example.com/3", "https://example.com/4")
  map[[c3]] <- urlset_xml("https://example.com/5", "https://example.com/6")
  local_index_server(map)

  res <- expand_root(
    root,
    index_xml(c1, c2, c3),
    limits = index_limits(max_total_urls = 2)
  )

  # The first leaf fills the budget exactly; no partial leaf is ever emitted.
  expect_identical(nrow(res$rows), 2L)
  expect_setequal(
    res$rows$loc,
    c("https://example.com/1", "https://example.com/2")
  )
  # The over-budget leaf is recorded as rejected, not silently dropped.
  expect_true(any(
    res$tree$status == "rejected" & res$tree$reason == "url-budget"
  ))
  expect_true(any(
    res$problems$category == "index-expansion" &
      grepl("Aggregate URL budget", res$problems$message, fixed = TRUE)
  ))
})

test_that("default aggregate budgets expand every child unchanged", {
  root <- "https://example.com/sitemap.xml"
  c1 <- "https://example.com/c1.xml"
  c2 <- "https://example.com/c2.xml"
  map <- list()
  map[[c1]] <- urlset_xml("https://example.com/1")
  map[[c2]] <- urlset_xml("https://example.com/2")
  local_index_server(map)

  res <- expand_root(root, index_xml(c1, c2))

  expect_identical(nrow(res$rows), 2L)
  expect_identical(nrow(res$tree), 2L)
  expect_false(any(grepl("budget", res$problems$message, fixed = TRUE)))
})

test_that("a nested sitemapindex warns but is still expanded", {
  root <- "https://example.com/root.xml"
  nested <- "https://example.com/nested.xml"
  leaf <- "https://example.com/leaf.xml"
  map <- list()
  map[[nested]] <- index_xml(leaf)
  map[[leaf]] <- urlset_xml("https://example.com/deep")
  local_index_server(map)

  res <- expand_root(root, index_xml(nested))

  expect_true(any(
    res$problems$category == "index-expansion" &
      grepl("[Nn]ested", res$problems$message)
  ))
  expect_true("https://example.com/deep" %in% res$rows$loc)
})

# ---- Chunked row sink (SITE-lzynozgl) ---------------------------------------
#
# A caller-supplied sink consumes each completed leaf as it lands, so the
# combined tibble is never materialized. The default (NULL) sink retains rows in
# the accumulator exactly as before; these tests pin both behaviors.

test_that("a caller row sink streams each leaf once, retaining no rows", {
  root <- "https://example.com/sitemap.xml"
  c1 <- "https://example.com/child-1.xml"
  c2 <- "https://example.com/child-2.xml"
  map <- list()
  map[[c1]] <- urlset_xml("https://example.com/a", "https://example.com/b")
  map[[c2]] <- urlset_xml("https://example.com/c")
  local_index_server(map)

  seen <- new.env(parent = emptyenv())
  seen$rows <- list()
  seen$srcs <- character(0)
  sink <- function(rows, source) {
    seen$rows[[length(seen$rows) + 1L]] <- rows
    seen$srcs <- c(seen$srcs, as.character(source$final_url))
  }

  res <- expand_root(root, index_xml(c1, c2), sink = sink)

  # The sink saw each completed leaf exactly once, with its source provenance.
  expect_length(seen$rows, 2L)
  expect_setequal(seen$srcs, c(c1, c2))
  # The combined result retains NO rows (bounded retention), yet the tree and
  # per-source metadata are still recorded.
  expect_identical(nrow(res$rows), 0L)
  expect_identical(nrow(res$tree), 2L)
  expect_identical(nrow(res$sources), 2L)

  # The streamed rows are exactly what the default in-memory sink collects.
  streamed <- do.call(rbind, seen$rows)
  default <- expand_root(root, index_xml(c1, c2))$rows
  expect_identical(nrow(streamed), nrow(default))
  expect_setequal(streamed$loc, default$loc)
})

test_that("stream_emit_leaf wraps a callback error with leaf context", {
  src <- tibble::tibble(final_url = "https://example.com/leaf.xml")
  cb <- function(rows, source) stop("kaboom")

  expect_error(
    stream_emit_leaf(cb, data.frame(), src),
    class = "sitemapr_stream_callback_error"
  )

  cnd <- rlang::catch_cnd(stream_emit_leaf(cb, data.frame(), src))
  expect_identical(cnd$leaf, "https://example.com/leaf.xml")
  expect_identical(conditionMessage(cnd$parent), "kaboom")
})

# --- (b) index-child scope (§12.2b) ---
#
# The (b) index-child scope axis (§12.2b) is a SEPARATE scope relation from the
# (a) page-scope axis. Pure evaluators, tested directly (no network): baseline /
# bing / yandex require the child on the same site as the index; google adds the
# same-or-lower-directory dimension. Emitted only under an engine overlay.

idx_deep <- "https://example.com/deep/sitemap-index.xml"
idx_base <- "sitemap://example.com/deep/sitemap-index.xml"

test_that("index_child_out_of_scope flags a cross-site child (google)", {
  google_spec <- findings_ruleset_spec("google", ruleset_context())
  oos <- index_child_out_of_scope(
    idx_deep,
    c("https://example.com/deep/child.xml", "https://other.com/child.xml"),
    google_spec
  )
  # Same-site, same-directory child is in scope; cross-site child is not.
  expect_identical(oos, c(FALSE, TRUE))
})

test_that("only google adds the same-or-lower-directory dimension", {
  google_spec <- findings_ruleset_spec("google", ruleset_context())
  yandex_spec <- findings_ruleset_spec("yandex", ruleset_context())
  bing_spec <- findings_ruleset_spec("bing", ruleset_context())
  # Same-site child ABOVE the index directory (index at /deep/).
  above <- "https://example.com/child.xml"
  expect_true(index_child_out_of_scope(idx_deep, above, google_spec))
  expect_false(index_child_out_of_scope(idx_deep, above, yandex_spec))
  expect_false(index_child_out_of_scope(idx_deep, above, bing_spec))
})

test_that("index_child_scope_findings is dormant on the baseline path", {
  out <- index_child_scope_findings(
    idx_deep,
    "https://other.com/child.xml",
    idx_base,
    NULL
  )
  expect_identical(nrow(out), 0L)
})

test_that("index_child_scope_findings emits one row per out-of-scope child", {
  google_spec <- findings_ruleset_spec("google", ruleset_context())
  out <- index_child_scope_findings(
    idx_deep,
    "https://other.com/child.xml",
    idx_base,
    google_spec
  )
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "INDEX_CHILD_OUT_OF_SCOPE")
  expect_identical(out$severity, "warning")
  expect_true(grepl("#index-child:", out$subject_ref, fixed = TRUE))
})

test_that("bing inherits the same-site rule (cross-site child out of scope)", {
  bing_spec <- findings_ruleset_spec("bing", ruleset_context())
  expect_true(
    index_child_out_of_scope(idx_deep, "https://other.com/child.xml", bing_spec)
  )
})
