# Offline tests for page-inspection selection + budget orchestration
# (R/page-inspect.R; Layer E, Contract A budget / E.1s).
#
# All network behavior is exercised through httr2's native mocking; the real
# network is never hit, so the suite is CRAN-safe. Internal functions are called
# directly (testthat loads the package namespace), mirroring test-page-fetch.R.

# A 200 response carrying a raw body; the mock keys off the request URL so a run
# over several distinct locs can be driven by one response function.
pi_mock_ok <- function(url, body = charToRaw("<html></html>")) {
  httr2::response(
    status_code = 200,
    url = url,
    headers = list("Content-Type" = "text/html; charset=UTF-8"),
    body = body
  )
}

# Install a URL-keyed mock that records every fetched URL into `log` (an env) so
# a test can assert dedup (one fetch per canonical key) and per-URL behavior.
# `on_url` maps a request URL to a response (or an abort, for failure tests).
pi_install_mock <- function(log, on_url) {
  httr2::local_mocked_responses(
    function(req) {
      log$urls <- c(log$urls, req$url)
      on_url(req$url)
    },
    env = parent.frame()
  )
}

pi_new_log <- function() {
  log <- new.env(parent = emptyenv())
  log$urls <- character(0)
  log
}

# A virtual clock returning 0, step, 2*step, ... on successive calls, so
# wall-time capping is deterministic and never sleeps on the real clock.
pi_clock <- function(step) {
  env <- new.env(parent = emptyenv())
  env$t <- -step
  function() {
    env$t <- env$t + step
    env$t
  }
}

# A no-network fetch stand-in: returns a usable_body artifact of `nbytes` bytes.
# Lets selection/budget mechanics be tested without httr2 at all.
fake_fetch <- function(nbytes = 4L) {
  function(
    url,
    page_body_cap,
    limits,
    user_agent,
    ssrf_guard,
    policy,
    throttle_state
  ) {
    n <- min(nbytes, page_body_cap)
    page_fetch_artifact(
      requested_url = url,
      final_url = url,
      body = as.raw(rep(0x41, n)),
      outcome = "usable_body",
      request_user_agent = user_agent
    )
  }
}

# ---- budget constructor ------------------------------------------------------

test_that("page_inspection_budget carries the caps with safe defaults", {
  b <- page_inspection_budget()
  expect_identical(b$page_body_cap, page_body_cap_default())
  expect_gt(b$max_pages, 0)
  expect_gt(b$max_requests, 0)
  expect_gt(b$max_bytes, 0)
  expect_gt(b$max_seconds, 0)
})

test_that("page_inspection_budget caps are caller-overridable, no hard floor", {
  b <- page_inspection_budget(
    max_pages = 1L,
    max_requests = 1L,
    max_bytes = 1L,
    page_body_cap = 8L,
    max_seconds = Inf
  )
  expect_identical(b$max_pages, 1L)
  expect_identical(b$max_bytes, 1L)
  expect_identical(b$page_body_cap, 8L)
  expect_identical(b$max_seconds, Inf)
})

test_that("page_inspection_budget rejects a negative cap", {
  expect_error(
    page_inspection_budget(max_pages = -1L),
    class = "sitemapr_invalid_limits"
  )
})

# ---- dedup by canonical loc identity -----------------------------------------

test_that("locs advertised multiple times dedup to one fetch key", {
  # Three raw forms of the SAME canonical URL (case + default-port variants).
  locs <- c(
    "https://example.com/a",
    "https://EXAMPLE.com/a",
    "https://example.com:443/a"
  )
  dedup <- page_inspection_dedup(locs)
  expect_length(dedup$entries, 1L)
  expect_identical(dedup$eligible, 3L)
  entry <- dedup$entries[["https://example.com/a"]]
  # Every advertising raw loc is retained for E.1f subject_ref anchoring.
  expect_identical(entry$advertised, locs)
})

test_that("dedup drops non-http(s) and unparseable locs from eligibility", {
  locs <- c(
    "https://example.com/a",
    "ftp://example.com/b",
    "not a url",
    ""
  )
  dedup <- page_inspection_dedup(locs)
  expect_identical(dedup$eligible, 1L)
  expect_named(dedup$entries, "https://example.com/a")
})

test_that("a duplicate loc is fetched exactly once by the run", {
  log <- pi_new_log()
  pi_install_mock(log, function(url) pi_mock_ok(url))
  locs <- c("https://example.com/a", "https://example.com/a")

  run <- page_inspection_run(locs, mode = "full")
  # One canonical key, one network fetch, both raw locs retained.
  expect_length(run$artifacts, 1L)
  expect_length(log$urls, 1L)
  expect_identical(run$coverage$deduplicated, 1L)
  expect_identical(run$coverage$attempted, 1L)
})

# ---- deterministic selection & output order ----------------------------------

test_that("selection is deterministic across input order and repeats", {
  keys <- c(
    "https://example.com/1",
    "https://example.com/2",
    "https://example.com/3",
    "https://example.com/4",
    "https://example.com/5"
  )
  a <- page_inspection_select(keys, sample_size = 3L, mode = "sample")
  b <- page_inspection_select(rev(keys), sample_size = 3L, mode = "sample")
  expect_length(a, 3L)
  # Same key SET + N -> identical sample AND identical order, twice.
  expect_identical(a, b)
  expect_identical(a, page_inspection_select(keys, 3L, "sample"))
})

test_that("full mode selects every deduped key, still deterministically", {
  keys <- c("https://example.com/1", "https://example.com/2")
  full <- page_inspection_select(keys, sample_size = 1L, mode = "full")
  expect_setequal(full, keys)
  expect_identical(full, page_inspection_select(rev(keys), 1L, "full"))
})

test_that("the run reproduces the same sample and artifact order twice", {
  locs <- sprintf("https://example.com/p%d", 1:6)
  budget <- page_inspection_budget(max_pages = 3L)
  run1 <- page_inspection_run(
    locs,
    budget = budget,
    sample_size = 3L,
    fetch = fake_fetch()
  )
  run2 <- page_inspection_run(
    rev(locs),
    budget = budget,
    sample_size = 3L,
    fetch = fake_fetch()
  )
  expect_named(run1$artifacts, names(run2$artifacts))
  expect_length(run1$artifacts, 3L)
})

# ---- cap: max pages ----------------------------------------------------------

test_that("max_pages cap stops the run and marks it partial", {
  locs <- sprintf("https://example.com/p%d", 1:5)
  run <- page_inspection_run(
    locs,
    budget = page_inspection_budget(max_pages = 2L),
    mode = "full",
    fetch = fake_fetch()
  )
  expect_identical(run$coverage$attempted, 2L)
  expect_identical(run$coverage$caps_hit, "max_pages")
  expect_true(run$coverage$partial_run)
  expect_identical(run$coverage$skipped, run$coverage$selected - 2L)
})

# ---- cap: max requests (hop count) -------------------------------------------

test_that("max_requests cap counts hops and stops the run", {
  # fake_fetch produces one hop-less artifact; simulate hops via a fetch that
  # reports two hops per page so the hop cap bites before the page cap.
  two_hop <- function(
    url,
    page_body_cap,
    limits,
    user_agent,
    ssrf_guard,
    policy,
    throttle_state
  ) {
    page_fetch_artifact(
      requested_url = url,
      final_url = url,
      hops = list(
        list(url = url, status = 301L, location = url),
        list(url = url, status = 200L, location = NA_character_)
      ),
      body = as.raw(rep(0x41, 4L)),
      outcome = "usable_body",
      request_user_agent = user_agent
    )
  }
  locs <- sprintf("https://example.com/p%d", 1:5)
  run <- page_inspection_run(
    locs,
    budget = page_inspection_budget(max_requests = 3L),
    mode = "full",
    fetch = two_hop
  )
  # Page 1 => 2 hops (<3, continue); page 2 => 4 hops (>=3 before page 3).
  expect_identical(run$coverage$attempted, 2L)
  expect_identical(run$coverage$requests, 4L)
  expect_identical(run$coverage$caps_hit, "max_requests")
})

# ---- cap: max aggregate bytes ------------------------------------------------

test_that("max_bytes cap stops the run on accumulated body bytes", {
  locs <- sprintf("https://example.com/p%d", 1:5)
  run <- page_inspection_run(
    locs,
    budget = page_inspection_budget(max_bytes = 15L),
    mode = "full",
    fetch = fake_fetch(nbytes = 10L)
  )
  # 10 (<15, continue) -> 20 (>=15 before the 3rd fetch).
  expect_identical(run$coverage$attempted, 2L)
  expect_identical(run$coverage$bytes, 20L)
  expect_identical(run$coverage$caps_hit, "max_bytes")
})

# ---- cap: max wall time (injected clock) -------------------------------------

test_that("max_seconds cap stops the run via the injected clock", {
  locs <- sprintf("https://example.com/p%d", 1:5)
  run <- page_inspection_run(
    locs,
    budget = page_inspection_budget(max_seconds = 5),
    mode = "full",
    clock = pi_clock(step = 3),
    fetch = fake_fetch()
  )
  # start=0; before p1 elapsed=3 (<5, fetch); before p2 elapsed=6 (>=5, stop).
  expect_identical(run$coverage$attempted, 1L)
  expect_identical(run$coverage$caps_hit, "max_seconds")
  expect_true(run$coverage$partial_run)
})

test_that("a fully-covered run is NOT marked partial (no false cap)", {
  locs <- sprintf("https://example.com/p%d", 1:3)
  run <- page_inspection_run(
    locs,
    budget = page_inspection_budget(max_pages = 10L),
    mode = "full",
    fetch = fake_fetch()
  )
  expect_identical(run$coverage$attempted, 3L)
  expect_identical(run$coverage$caps_hit, character(0))
  expect_false(run$coverage$partial_run)
})

# ---- failure isolation -------------------------------------------------------

test_that("one failing URL does not abort the sample", {
  log <- pi_new_log()
  pi_install_mock(log, function(url) {
    if (grepl("/bad", url, fixed = TRUE)) {
      rlang::abort("boom", class = c("httr2_failure", "httr2_error"))
    }
    pi_mock_ok(url)
  })
  locs <- c(
    "https://example.com/ok1",
    "https://example.com/bad",
    "https://example.com/ok2"
  )
  run <- page_inspection_run(locs, mode = "full")

  # All three attempted; the failure is captured, the rest still fetched.
  expect_identical(run$coverage$attempted, 3L)
  expect_identical(run$coverage$completed, 2L)
  expect_identical(run$coverage$failed, 1L)
  bad <- run$artifacts[["https://example.com/bad"]]$artifact
  expect_identical(bad$outcome, "transport_fail")
})

# ---- coverage bookkeeping ----------------------------------------------------

test_that("coverage counts eligible / deduplicated / selected / completed", {
  locs <- c(
    "https://example.com/a",
    "https://EXAMPLE.com/a", # dup of /a
    "https://example.com/b",
    "https://example.com/c",
    "ftp://example.com/skip" # ineligible
  )
  run <- page_inspection_run(
    locs,
    budget = page_inspection_budget(max_pages = 2L),
    sample_size = 2L,
    fetch = fake_fetch()
  )
  cov <- run$coverage
  expect_identical(cov$eligible, 4L) # 4 http(s) locs (one a dup)
  expect_identical(cov$deduplicated, 3L) # a, b, c
  expect_identical(cov$selected, 2L) # sample of 2
  expect_identical(cov$attempted, 2L)
  expect_identical(cov$completed, 2L)
  expect_identical(cov$mode, "sample")
})

test_that("partial outcomes are counted in coverage$partial", {
  partial_fetch <- function(
    url,
    page_body_cap,
    limits,
    user_agent,
    ssrf_guard,
    policy,
    throttle_state
  ) {
    page_fetch_artifact(
      requested_url = url,
      final_url = url,
      body = as.raw(rep(0x41, page_body_cap)),
      truncated = TRUE,
      outcome = "partial",
      request_user_agent = user_agent
    )
  }
  locs <- sprintf("https://example.com/p%d", 1:2)
  run <- page_inspection_run(
    locs,
    budget = page_inspection_budget(page_body_cap = 4L),
    mode = "full",
    fetch = partial_fetch
  )
  expect_identical(run$coverage$partial, 2L)
  expect_identical(run$coverage$completed, 2L) # partial bodies are usable
})

test_that("an empty loc set yields a zeroed, non-partial coverage", {
  run <- page_inspection_run(character(0))
  expect_length(run$artifacts, 0L)
  expect_identical(run$coverage$eligible, 0L)
  expect_identical(run$coverage$attempted, 0L)
  expect_false(run$coverage$partial_run)
})

# ---- one shared throttle_state threads across the run ------------------------

test_that("a single throttle_state paces same-host fetches across the run", {
  # Inject a virtual-clock throttle state; if ONE state threads the whole run,
  # the second same-host fetch must pace against the first (sleep invoked).
  slept <- new.env(parent = emptyenv())
  slept$calls <- numeric(0)
  vclock <- pi_clock(step = 0) # frozen clock: now never advances on its own
  state <- throttle_state_new(
    request_throttle(min_interval = 10),
    now = function() 0,
    sleep = function(secs) slept$calls <- c(slept$calls, secs)
  )
  log <- pi_new_log()
  pi_install_mock(log, function(url) pi_mock_ok(url))

  locs <- sprintf("https://example.com/p%d", 1:2)
  page_inspection_run(
    locs,
    mode = "full",
    throttle_state = state,
    clock = vclock
  )
  # First request is free; the second pays the min_interval pace once.
  expect_length(slept$calls, 1L)
  expect_identical(slept$calls, 10)
})
