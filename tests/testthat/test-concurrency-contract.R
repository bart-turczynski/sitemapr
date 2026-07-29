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
# DISPATCH WIDTH handed to the worker pool; the sequential expand_index() result
# is the REFERENCE oracle, asserted identical() to the concurrent output.
#
# What the probe can and cannot prove: responses here are mocked, so nothing in
# this file overlaps in wall-clock terms and no test in it can demonstrate real
# concurrency. The probe bounds the cap and the single-dispatch test below
# guards the structure; actual overlap is evidenced out-of-band by benchmarking
# against a server that counts its own concurrency (SITE-hxzmvlkn).

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
  # A probe records the number of requests handed to the pool at once. With
  # max_active = 2 over many children, that width must never exceed 2.
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
  # ways: the probe records a dispatch width >1, so the children reached the
  # pool together rather than one at a time, and the URL rows are byte-identical
  # to the sequential default (max_active omitted).
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

# ---- concurrent dispatch (SITE-hxzmvlkn) ------------------------------------
#
# The scheduler used to WINDOW a sequential for-loop over fetch_source(): the
# worker cap was honoured trivially because the in-flight count was always 1.
# These tests pin the structure that a windowed sequential loop cannot satisfy,
# and cover the failure branches of the batch path, which no longer share
# fetch_source()'s abort handling.

test_that("a batch reaches the worker pool in one parallel dispatch", {
  # Regression guard: all eight children must be handed to
  # req_perform_parallel() TOGETHER, in a single call, under the worker cap.
  # A sequential loop (or a windowed one) produces eight calls, or one per
  # window, never one call carrying eight requests.
  seen <- new.env(parent = emptyenv())
  seen$calls <- list()
  testthat::local_mocked_bindings(
    req_perform_parallel = function(reqs, ..., max_active = 10) {
      seen$calls[[length(seen$calls) + 1L]] <- list(
        n = length(reqs),
        max_active = max_active
      )
      lapply(reqs, function(req) {
        httr2::response(
          status_code = 200L,
          url = req$url,
          headers = list("Content-Type" = "application/xml"),
          body = charToRaw(urlset_xml("https://example.com/p"))
        )
      })
    },
    .package = "httr2"
  )

  urls <- sprintf("https://example.com/child-%d.xml", seq_len(8L))
  records <- fetch_batch_follow(
    urls = urls,
    limits = fetch_limits(),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 4L
  )

  expect_length(seen$calls, 1L)
  expect_identical(seen$calls[[1]]$n, 8L)
  expect_identical(seen$calls[[1]]$max_active, 4L)
  expect_length(records, 8L)
  expect_identical(records[[1]]$requested_url, urls[[1]])
})

test_that("records come back in catalog order, not completion order", {
  # The pool may complete in any order; fetch_batch_follow() builds every
  # record only once all URLs are terminal, walking them in catalog order. A
  # mock that returns its responses REVERSED must not disturb that.
  testthat::local_mocked_bindings(
    req_perform_parallel = function(reqs, ..., max_active = 10) {
      rev(lapply(rev(reqs), function(req) {
        httr2::response(
          status_code = 200L,
          url = req$url,
          headers = list("Content-Type" = "application/xml"),
          body = charToRaw(urlset_xml("https://example.com/p"))
        )
      }))
    },
    .package = "httr2"
  )

  urls <- sprintf("https://example.com/child-%d.xml", seq_len(4L))
  records <- fetch_batch_follow(
    urls = urls,
    limits = fetch_limits(),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 4L
  )

  expect_identical(
    vapply(records, function(r) r$requested_url, character(1)),
    urls
  )
})

test_that("an SSRF-blocked child retires alone, siblings still fetched", {
  # The guard runs before every hop. In a batch its abort must retire only the
  # blocked child -- it must not tear down the whole dispatch.
  local_index_server(list(
    "https://example.com/ok.xml" = urlset_xml("https://example.com/a")
  ))

  records <- fetch_batch_follow(
    urls = c("http://127.0.0.1/blocked.xml", "https://example.com/ok.xml"),
    limits = fetch_limits(),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 2L
  )

  expect_null(records[[1]])
  expect_identical(records[[2]]$status, 200L)
})

test_that("a batch of only blocked children dispatches nothing", {
  # Every pending URL fails its guard, so the round has no request to send and
  # the loop must terminate rather than spin.
  records <- fetch_batch_follow(
    urls = c("http://127.0.0.1/a.xml", "http://127.0.0.1/b.xml"),
    limits = fetch_limits(),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 2L
  )

  expect_length(records, 2L)
  expect_true(all(vapply(records, is.null, logical(1))))
})

test_that("a redirect is followed across rounds, chain recorded", {
  # Redirects advance one hop per round, so the per-hop guard still precedes
  # every request. The terminal record reports the final URL and the chain.
  local_index_server(list(
    "https://example.com/final.xml" = urlset_xml("https://example.com/a")
  ))
  hops <- new.env(parent = emptyenv())
  hops$n <- 0L
  httr2::local_mocked_responses(function(req) {
    if (grepl("start", req$url, fixed = TRUE)) {
      hops$n <- hops$n + 1L
      return(httr2::response(
        status_code = 301L,
        url = req$url,
        headers = list(Location = "https://example.com/final.xml")
      ))
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/xml"),
      body = charToRaw(urlset_xml("https://example.com/a"))
    )
  })

  records <- fetch_batch_follow(
    urls = "https://example.com/start.xml",
    limits = fetch_limits(),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 2L
  )

  expect_identical(hops$n, 1L)
  expect_identical(records[[1]]$status, 200L)
  expect_identical(records[[1]]$final_url, "https://example.com/final.xml")
  expect_true(
    "https://example.com/start.xml" %in% records[[1]]$redirect_chain[[1]]
  )
})

test_that("a redirect loop is retired at the redirect limit", {
  # Exceeding max_redirects aborts in the sequential path; in the batch path it
  # retires that URL with no record, which the caller reads as unfetchable.
  httr2::local_mocked_responses(function(req) {
    httr2::response(
      status_code = 302L,
      url = req$url,
      headers = list(Location = "https://example.com/next.xml")
    )
  })

  records <- fetch_batch_follow(
    urls = "https://example.com/start.xml",
    limits = fetch_limits(max_redirects = 2L),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 2L
  )

  expect_null(records[[1]])
})

test_that("a transport failure retires its URL without a record", {
  # on_error = "continue" hands back a condition instead of a response.
  testthat::local_mocked_bindings(
    req_perform_parallel = function(reqs, ..., max_active = 10) {
      list(rlang::catch_cnd(rlang::abort("boom", class = "httr2_failure")))
    },
    .package = "httr2"
  )

  records <- fetch_batch_follow(
    urls = "https://example.com/child.xml",
    limits = fetch_limits(),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 2L
  )

  expect_null(records[[1]])
})

test_that("a body over the safety ceiling retires its URL alone", {
  # read_capped_body() aborts; that abort must not escape the batch and kill
  # the sibling children with it.
  httr2::local_mocked_responses(function(req) {
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/xml"),
      body = charToRaw(strrep("x", 4096L))
    )
  })

  records <- fetch_batch_follow(
    urls = c("https://example.com/big.xml", "https://example.com/also.xml"),
    limits = fetch_limits(max_bytes = 16L),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 2L
  )

  expect_true(all(vapply(records, is.null, logical(1))))
})

test_that("a response with no body yields an empty-bodied record", {
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 204L, url = req$url)
  })

  records <- suppressWarnings(fetch_batch_follow(
    urls = "https://example.com/child.xml",
    limits = fetch_limits(),
    user_agent = default_user_agent(),
    ssrf_guard = TRUE,
    max_active = 2L
  ))

  expect_identical(records[[1]]$status, 204L)
  expect_identical(records[[1]]$bytes, 0L)
})
