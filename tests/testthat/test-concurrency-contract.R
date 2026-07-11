# Pending contract tests for ADR-008 (deterministic bounded concurrency).
#
# These tests ENCODE the observable invariants that opt-in bounded concurrency
# must preserve. They are intentionally PENDING: every test skips until
# SITE-tktfxoxe implements the scheduler, so the suite stays GREEN now while the
# contract is documented executably. When SITE-tktfxoxe lands it deletes the
# skip() at the top of each test and implements against these assertions.
#
# The load-bearing invariant (ADR-008 §0): concurrency is a scheduling
# optimization only. For the same input and limits, the rows / sources /
# problems / tree AND their order AND the budget-truncation point are
# byte-identical between sequential and concurrent mode, regardless of the order
# in which child fetches complete. Output is emitted in source/catalog order,
# never completion order.
#
# Test-design notes for the implementer (SITE-tktfxoxe):
#   * `permute_completion_order()` is the hook these tests need from the
#     scheduler: a seam that forces child fetches to COMPLETE in a caller-chosen
#     order (e.g. reverse, or an arbitrary permutation) while the input catalog
#     order is fixed. The virtual-clock throttle seam in test-index-expansion.R
#     ("a throttle state paces index children on a shared host bucket") is the
#     model for injecting deterministic timing without real sleeps.
#   * The sequential result from today's `expand_index()` is the REFERENCE
#     oracle; concurrent output is asserted `identical()` to it.

pending_concurrency <- function() {
  skip("pending SITE-tktfxoxe: bounded-concurrency implementation")
}

test_that("concurrent output is byte-identical to sequential (rows/tree)", {
  pending_concurrency()

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
  expect_identical(concurrent$sources, reference$sources)
  expect_identical(concurrent$tree, reference$tree)
  expect_identical(concurrent$problems, reference$problems)
})

test_that("output is stable across every permuted child completion order", {
  pending_concurrency()

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
  pending_concurrency()

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
  pending_concurrency()

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
  # interval each — identical pacing to the sequential throttle test.
  expect_identical(cl$slept, c(5, 5))
})

test_that("budget truncation lands at the sequential catalog position", {
  pending_concurrency()

  # Two URLs per leaf; max_total_urls = 5 admits child-1 (2) and child-2 (2) =
  # 4, then child-3 would breach 5 and is left out WHOLE. Concurrency must cut
  # at the identical catalog position regardless of completion order.
  root <- "https://example.com/sitemap.xml"
  map <- list(
    "https://example.com/child-1.xml" = urlset_xml(
      "https://example.com/a1", "https://example.com/a2"
    ),
    "https://example.com/child-2.xml" = urlset_xml(
      "https://example.com/b1", "https://example.com/b2"
    ),
    "https://example.com/child-3.xml" = urlset_xml(
      "https://example.com/c1", "https://example.com/c2"
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
  pending_concurrency()

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

  reference <- expand_root(root, body)
  concurrent <- expand_root(root, body, max_active = 3L)

  expect_identical(concurrent$rows, reference$rows)
  expect_identical(concurrent$tree, reference$tree)
  expect_identical(concurrent$problems, reference$problems)
})

test_that("sequential fallback (max_active = 1) equals the default path", {
  pending_concurrency()

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
  expect_identical(serial$sources, reference$sources)
  expect_identical(serial$tree, reference$tree)
  expect_identical(serial$problems, reference$problems)
})

test_that("one operation shares a single per-host bucket across phases", {
  pending_concurrency()

  # ADR-008 §6 throttle unification: discovery + every index expansion of one
  # sitemap_tree() operation pace against ONE host-bucket store. Two same-host
  # top-level indexes plus the discovery requests that preceded them must pace
  # on the shared bucket, not restart pacing per phase. With a shared virtual
  # clock, the total slept time reflects one continuous pace across the whole
  # operation (not one free "first request" per phase).
  cl <- new.env(parent = emptyenv())
  cl$t <- 1000
  cl$slept <- numeric(0)
  cl$now <- function() cl$t
  cl$sleep <- function(seconds) {
    cl$slept <- c(cl$slept, seconds)
    cl$t <- cl$t + seconds
  }

  # The scheduler must build ONE throttle_state and thread it through discovery,
  # robots, and all expand_index() calls. This asserts the store is shared: only
  # the very first request across the whole operation is free.
  state <- throttle_state_new(
    request_throttle(min_interval = 5),
    now = cl$now,
    sleep = cl$sleep
  )
  expect_identical(operation_free_requests(state), 1L)
})
