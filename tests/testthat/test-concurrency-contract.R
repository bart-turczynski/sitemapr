# Contract tests for ADR-008 (deterministic bounded concurrency).
#
# These tests ENCODE the observable invariants that opt-in bounded concurrency
# must preserve. The scheduler is implemented (SITE-tktfxoxe), so they run.
#
# The load-bearing invariant (ADR-008 §0): concurrency is a scheduling
# optimization only. For the same input and limits, the rows / sources /
# problems / tree AND their order AND the budget-truncation point are
# byte-identical between sequential and concurrent mode, regardless of the order
# in which child fetches complete. Output is emitted in source/catalog order,
# never completion order.
#
# Seams (helper-concurrency.R): permute_completion_order() forces child fetches
# to COMPLETE in a caller-chosen order; local_inflight_probe() records the peak
# concurrent in-flight fetches; the sequential expand_index() result is the
# REFERENCE oracle, asserted identical() to the concurrent output.

test_that("concurrent output is byte-identical to sequential (rows/tree)", {
  # Build one index over several same-host leaves whose bodies differ, so row
  # order is observable. The sequential expansion is the reference oracle.
  root <- "https://example.com/sitemap.xml"
  map <- list(
    "https://example.com/child-1.xml" = urlset_xml("https://example.com/a"),
    "https://example.com/child-2.xml" = urlset_xml("https://example.com/b"),
    "https://example.com/child-3.xml" = urlset_xml("https://example.com/c")
  )
  local_index_server(map)
  body <- index_xml(names(map)[[1]], names(map)[[2]], names(map)[[3]])

  reference <- expand_root(root, body)

  # Concurrent mode with a worker cap must reproduce the reference exactly:
  # same rows, same source records, same tree, same problems, same ORDER.
  concurrent <- expand_root(root, body, max_active = 3L)

  expect_identical(concurrent$rows, reference$rows)
  expect_identical(
    stable_sources(concurrent)$sources,
    stable_sources(reference)$sources
  )
  expect_identical(concurrent$tree, reference$tree)
  expect_identical(concurrent$problems, reference$problems)
})

test_that("output is stable across every permuted child completion order", {
  root <- "https://example.com/sitemap.xml"
  map <- list(
    "https://example.com/child-1.xml" = urlset_xml("https://example.com/a"),
    "https://example.com/child-2.xml" = urlset_xml("https://example.com/b"),
    "https://example.com/child-3.xml" = urlset_xml("https://example.com/c")
  )
  local_index_server(map)
  body <- index_xml(names(map)[[1]], names(map)[[2]], names(map)[[3]])

  reference <- expand_root(root, body)

  # For every permutation of the completion order, the emitted result must be
  # identical to the reference: completion order changes only WHEN bytes arrive,
  # never WHERE a child's rows land (ADR-008 §0 emits in catalog order).
  orders <- list(c(1L, 2L, 3L), c(3L, 2L, 1L), c(2L, 3L, 1L), c(3L, 1L, 2L))
  for (order in orders) {
    permute_completion_order(order)
    out <- expand_root(root, body, max_active = 3L)
    expect_identical(out$rows, reference$rows)
    expect_identical(out$tree, reference$tree)
  }
})

test_that("the global worker cap (max_active) is never exceeded", {
  # A probe records the number of fetches simultaneously in flight. With
  # max_active = 2 over many children, the observed peak must never exceed 2.
  root <- "https://example.com/sitemap.xml"
  map <- list()
  for (i in seq_len(8L)) {
    child <- sprintf("https://example.com/child-%d.xml", i)
    map[[child]] <- urlset_xml(sprintf("https://example.com/p%d", i))
  }
  probe <- local_inflight_probe()
  local_index_server(map)
  body <- do.call(index_xml, as.list(names(map)))

  expand_root(root, body, max_active = 2L)

  expect_lte(probe$peak_inflight(), 2L)
})

test_that("the per-host throttle bounds rate even under concurrency", {
  # A virtual clock (same seam as test-index-expansion.R) records slept-for
  # delays. All children share one example.com host bucket, so even with idle
  # workers the throttle paces them: the worker cap and the throttle compose,
  # and a single host is never fetched faster than min_interval (ADR-008 §2).
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
  body <- index_xml(names(map)[[1]], names(map)[[2]], names(map)[[3]])

  expand_root(root, body, max_active = 3L, throttle_state = state)

  # Three children on the one shared bucket: first free, next two wait a full
  # interval each -- identical pacing to the sequential throttle test.
  expect_identical(cl$slept, c(5, 5))
})

test_that("budget truncation lands at the sequential catalog position", {
  # Two URLs per leaf; max_total_urls = 5 admits child-1 (2) and child-2 (2) =
  # 4, then child-3 would breach 5 and is left out WHOLE. Concurrency must cut
  # at the identical catalog position regardless of completion order.
  root <- "https://example.com/sitemap.xml"
  map <- list(
    "https://example.com/child-1.xml" = urlset_xml(
      "https://example.com/a1",
      "https://example.com/a2"
    ),
    "https://example.com/child-2.xml" = urlset_xml(
      "https://example.com/b1",
      "https://example.com/b2"
    ),
    "https://example.com/child-3.xml" = urlset_xml(
      "https://example.com/c1",
      "https://example.com/c2"
    )
  )
  local_index_server(map)
  limits <- index_limits(max_total_urls = 5)
  body <- index_xml(names(map)[[1]], names(map)[[2]], names(map)[[3]])

  reference <- expand_root(root, body, limits = limits)

  # Reverse-completion concurrent run truncates at the same place: child-3 is
  # the rejected node with reason "url-budget"; child-1 and child-2 accepted.
  permute_completion_order(c(3L, 2L, 1L))
  out <- expand_root(root, body, limits = limits, max_active = 3L)

  expect_identical(out$rows, reference$rows)
  expect_identical(out$tree, reference$tree)
  expect_identical(nrow(out$rows), 4L)
  rejected <- out$tree[out$tree$status == "rejected", ]
  expect_identical(nrow(rejected), 1L)
  expect_identical(rejected$reason, "url-budget")
})

test_that("a per-child fetch error becomes the same finding as sequential", {
  # A dead middle child must not abort the walk: it is captured in place as the
  # same rejected tree row + fetch problem sequential mode produces, and the
  # surviving children still contribute their rows in catalog order (ADR-008
  # §4, the on_error = "continue" analog).
  root <- "https://example.com/sitemap.xml"
  map <- list(
    "https://example.com/child-1.xml" = urlset_xml("https://example.com/a"),
    "https://example.com/child-3.xml" = urlset_xml("https://example.com/c")
  )
  # child-2 is intentionally absent from the server -> unfetchable.
  local_index_server(map)
  body <- index_xml(
    "https://example.com/child-1.xml",
    "https://example.com/child-2.xml",
    "https://example.com/child-3.xml"
  )

  # A child 4xx surfaces as a non-fatal `sitemapr_http_error` warning in both
  # modes (same as setup-steps-index.R); suppress it to compare the outputs.
  reference <- suppressWarnings(expand_root(root, body))
  concurrent <- suppressWarnings(expand_root(root, body, max_active = 3L))

  expect_identical(concurrent$rows, reference$rows)
  expect_identical(concurrent$tree, reference$tree)
  expect_identical(concurrent$problems, reference$problems)
})

test_that("sequential fallback (max_active = 1) equals the default path", {
  # max_active = 1 MUST be observably identical to the sequential default: it is
  # the reference semantics, not a distinct mode (ADR-008 §1).
  root <- "https://example.com/sitemap.xml"
  map <- list(
    "https://example.com/child-1.xml" = urlset_xml("https://example.com/a"),
    "https://example.com/child-2.xml" = urlset_xml("https://example.com/b")
  )
  local_index_server(map)
  body <- index_xml(names(map)[[1]], names(map)[[2]])

  reference <- expand_root(root, body)
  serial <- expand_root(root, body, max_active = 1L)

  expect_identical(serial$rows, reference$rows)
  expect_identical(
    stable_sources(serial)$sources,
    stable_sources(reference)$sources
  )
  expect_identical(serial$tree, reference$tree)
  expect_identical(serial$problems, reference$problems)
})

test_that("one operation shares a single per-host bucket across phases", {
  # ADR-008 §6 throttle unification: discovery + every index expansion of one
  # sitemap_tree() operation pace against ONE host-bucket store. A single
  # per-operation store grants exactly one free ("first") request across the
  # whole operation, not one per phase.
  state <- throttle_state_new(request_throttle(min_interval = 5))
  expect_identical(operation_free_requests(state), 1L)
})

test_that("sitemap_tree paces all phases against one shared bucket", {
  # End-to-end proof of ADR-008 §6: discovery (guessed-path catalog) AND the
  # index expansion of one walk share a SINGLE per-host throttle store. All
  # requests target one host, so a shared bucket grants exactly ONE free (the
  # very first) request across the whole walk and paces every later one. If each
  # phase built its own store, discovery and expansion would each get a free
  # request and the sleep count would be lower. A virtual clock keeps it offline
  # and instant.
  cl <- new.env(parent = emptyenv())
  cl$t <- 1000
  cl$slept <- numeric(0)
  cl$now <- function() cl$t
  cl$sleep <- function(seconds) {
    cl$slept <- c(cl$slept, seconds)
    cl$t <- cl$t + seconds
  }
  state <- throttle_state_new(
    request_throttle(min_interval = 5),
    now = cl$now,
    sleep = cl$sleep
  )

  # One accepted index at a guessed path plus two children, all on one host.
  # Every other guessed path 404s but is still fetched (and paced).
  map <- list(
    "https://example.com/sitemap_index.xml" = index_xml(
      "https://example.com/child-1.xml",
      "https://example.com/child-2.xml"
    ),
    "https://example.com/child-1.xml" = urlset_xml("https://example.com/a"),
    "https://example.com/child-2.xml" = urlset_xml("https://example.com/b")
  )
  tracker <- local_index_server(map)

  tree <- sitemap_tree_from_root(
    "https://example.com",
    use_robots = FALSE,
    use_known_paths = TRUE,
    user_agent = default_user_agent(),
    limits = discovery_limits(),
    net_limits = fetch_limits(),
    index_limits = index_limits(),
    policy = request_policy(),
    throttle_state = state
  )

  # Both children were reached (the walk actually expanded the index).
  expanded <- c(
    "https://example.com/child-1.xml",
    "https://example.com/child-2.xml"
  )
  expect_true(all(expanded %in% tracker$urls))
  # Every fetch hit the one host, so one shared bucket => exactly one free
  # request across discovery + expansion; each of the rest slept once.
  n_requests <- length(tracker$urls)
  expect_gt(n_requests, 1L)
  expect_length(cl$slept, n_requests - 1L)
})

# ---- public surface: top-level max_active argument (SITE-gxqpebtb) -----------

test_that("read_sitemap(max_active=) engages the scheduler, output unchanged", {
  # The user-facing knob (ADR-008 §1): read_sitemap()'s top-level max_active is
  # folded into the policy and reaches expand_index()'s scheduler. Proven two
  # ways: the in-flight probe records >1 concurrent fetch, and the URL rows are
  # byte-identical to the sequential default (max_active omitted).
  root <- "https://example.com/sitemap.xml"
  children <- list(
    "https://example.com/child-1.xml" = urlset_xml("https://example.com/a"),
    "https://example.com/child-2.xml" = urlset_xml("https://example.com/b"),
    "https://example.com/child-3.xml" = urlset_xml("https://example.com/c")
  )
  # read_sitemap() fetches the root URL, so the index body is in the map too.
  map <- c(
    list(
      root = index_xml(
        "https://example.com/child-1.xml",
        "https://example.com/child-2.xml",
        "https://example.com/child-3.xml"
      )
    ),
    children
  )
  names(map)[[1]] <- root
  local_index_server(map)

  strip_meta <- function(t) {
    attr(t, "sources") <- NULL
    attr(t, "problems") <- NULL
    t
  }
  sequential <- read_sitemap(root)

  probe <- local_inflight_probe()
  concurrent <- read_sitemap(root, max_active = 3L)

  expect_gt(probe$peak_inflight(), 1L)
  expect_identical(strip_meta(concurrent), strip_meta(sequential))
})
