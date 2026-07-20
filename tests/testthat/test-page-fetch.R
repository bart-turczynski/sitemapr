# Offline tests for the engine-neutral page-fetch artifact + acquisition
# (R/page-fetch.R + the page_fetch_follow capture path in R/fetch.R; Layer E,
# Contract A / E.1a).
#
# All network behavior is exercised through httr2's native mocking; the real
# network is never hit, so the suite is CRAN-safe. Internal functions are called
# directly (testthat loads the package namespace), mirroring test-fetch.R.

# A 200 response carrying a raw body, content type, and OPTIONAL extra headers
# (a named list that may repeat a field name, e.g. two X-Robots-Tag lines).
page_mock_ok <- function(
  url = "https://example.com/p",
  body = charToRaw("<html><head></head></html>"),
  content_type = "text/html; charset=UTF-8",
  extra_headers = list()
) {
  httr2::response(
    status_code = 200,
    url = url,
    headers = c(list("Content-Type" = content_type), extra_headers),
    body = body
  )
}

page_mock_redirect <- function(url, location, status = 301L) {
  httr2::response(
    status_code = status,
    url = url,
    headers = list(Location = location)
  )
}

page_mock_status <- function(status, url = "https://example.com/p") {
  httr2::response(status_code = status, url = url)
}

# ---- artifact constructor ----------------------------------------------------

test_that("page_fetch_artifact shape-checks and defaults its fields", {
  art <- page_fetch_artifact(
    requested_url = "https://example.com/p",
    outcome = "usable_body",
    request_user_agent = "inspector/1.0"
  )
  expect_s3_class(art, "page_fetch_artifact")
  expect_identical(art$requested_url, "https://example.com/p")
  expect_true(is.na(art$final_url))
  expect_identical(art$hops, list())
  expect_identical(art$terminal_headers, list())
  expect_identical(art$body, raw())
  expect_false(art$truncated)
  expect_identical(art$outcome, "usable_body")
  expect_identical(art$request_user_agent, "inspector/1.0")
})

test_that("page_fetch_artifact rejects an out-of-enum outcome", {
  expect_error(
    page_fetch_artifact(
      requested_url = "https://example.com/p",
      outcome = "definitely_not_a_status",
      request_user_agent = "inspector/1.0"
    )
  )
})

# ---- outcome classification: 2xx / non-2xx -----------------------------------

test_that("a 2xx full body classifies as usable_body", {
  httr2::local_mocked_responses(list(page_mock_ok()))
  art <- page_fetch("https://example.com/p")
  expect_identical(art$outcome, "usable_body")
  expect_identical(art$final_url, "https://example.com/p")
  expect_false(art$truncated)
  expect_gt(length(art$body), 0L)
})

test_that("a terminal 4xx classifies as http_status", {
  httr2::local_mocked_responses(list(page_mock_status(404L)))
  art <- page_fetch("https://example.com/p")
  expect_identical(art$outcome, "http_status")
})

test_that("a terminal 5xx classifies as http_status", {
  httr2::local_mocked_responses(list(page_mock_status(503L)))
  art <- page_fetch("https://example.com/p")
  expect_identical(art$outcome, "http_status")
})

test_that("a terminal 3xx with no Location classifies as http_status", {
  # Not a follow-able redirect: fetch_redirect_target() reports it as terminal.
  httr2::local_mocked_responses(list(
    httr2::response(status_code = 302L, url = "https://example.com/p")
  ))
  art <- page_fetch("https://example.com/p")
  expect_identical(art$outcome, "http_status")
})

# ---- hops captured as an ordered redirect chain ------------------------------

test_that("hops are captured as an ordered chain, not a counter", {
  httr2::local_mocked_responses(list(
    page_mock_redirect("https://example.com/0", "https://example.com/1"),
    page_mock_redirect("https://example.com/1", "https://example.com/2"),
    page_mock_ok(url = "https://example.com/2")
  ))
  art <- page_fetch("https://example.com/0")

  expect_identical(art$outcome, "usable_body")
  expect_identical(art$final_url, "https://example.com/2")
  expect_length(art$hops, 3L)
  expect_identical(
    vapply(art$hops, `[[`, character(1), "url"),
    c("https://example.com/0", "https://example.com/1", "https://example.com/2")
  )
  expect_identical(
    vapply(art$hops, `[[`, integer(1), "status"),
    c(301L, 301L, 200L)
  )
  # Each hop carries its resolved Location; the terminal hop has none.
  expect_identical(art$hops[[1L]]$location, "https://example.com/1")
  expect_identical(art$hops[[2L]]$location, "https://example.com/2")
  expect_true(is.na(art$hops[[3L]]$location))
})

# ---- terminal_headers preserve repeated field values -------------------------

test_that("terminal_headers preserve repeated X-Robots-Tag / Link lines", {
  # Build the header list with a REPEATED field name via stats::setNames() so
  # the two X-Robots-Tag lines survive (a literal duplicate-argument call would
  # trip the lint and is not what a real multi-header response looks like).
  repeated <- stats::setNames(
    list("noindex", "nofollow", "<https://example.com/c>; rel=\"canonical\""),
    c("X-Robots-Tag", "X-Robots-Tag", "Link")
  )
  httr2::local_mocked_responses(list(
    page_mock_ok(extra_headers = repeated)
  ))
  art <- page_fetch("https://example.com/p")

  # Both repeated values survive, in order (not collapsed to the first).
  expect_identical(
    page_header_values(art$terminal_headers, "X-Robots-Tag"),
    c("noindex", "nofollow")
  )
  # Case-insensitive field lookup.
  expect_identical(
    page_header_values(art$terminal_headers, "x-robots-tag"),
    c("noindex", "nofollow")
  )
  expect_identical(
    page_header_values(art$terminal_headers, "Link"),
    "<https://example.com/c>; rel=\"canonical\""
  )
  # An absent field yields the empty character vector.
  expect_identical(
    page_header_values(art$terminal_headers, "X-Absent"),
    character(0)
  )
})

# ---- truncate-and-retain: outcome = partial ----------------------------------

test_that("a body over the per-page cap is truncated-and-retained as partial", {
  body <- as.raw(rep(0x41, 50L))
  httr2::local_mocked_responses(list(page_mock_ok(body = body)))

  art <- page_fetch("https://example.com/p", page_body_cap = 10L)

  expect_identical(art$outcome, "partial")
  expect_true(art$truncated)
  # The prefix is RETAINED (not discarded) and is exactly the head region.
  expect_length(art$body, 10L)
  expect_identical(art$body, body[seq_len(10L)])
})

test_that("a body at or under the per-page cap is a full usable_body", {
  body <- as.raw(rep(0x41, 10L))
  httr2::local_mocked_responses(list(page_mock_ok(body = body)))

  art <- page_fetch("https://example.com/p", page_body_cap = 10L)
  expect_identical(art$outcome, "usable_body")
  expect_false(art$truncated)
  expect_length(art$body, 10L)
})

# ---- 500 MB per-resource ceiling discard -> incomplete -----------------------

test_that("a body over the 500 MB per-resource ceiling is incomplete", {
  # The ceiling (max_bytes) is the OUTER discard backstop, distinct from the
  # per-page truncate cap: exceeding it yields no usable body -> incomplete.
  body <- as.raw(rep(0x41, 50L))
  httr2::local_mocked_responses(list(page_mock_ok(body = body)))

  art <- page_fetch(
    "https://example.com/p",
    page_body_cap = 1024L^2,
    limits = fetch_limits(max_bytes = 10L)
  )
  expect_identical(art$outcome, "incomplete")
  expect_length(art$body, 0L)
})

# ---- safety precedence: SSRF / scheme -> safety_refused ----------------------

test_that("an SSRF-blocked URL classifies as safety_refused, not a verdict", {
  state <- new.env(parent = emptyenv())
  state$called <- FALSE
  httr2::local_mocked_responses(function(req) {
    state$called <- TRUE
    page_mock_ok()
  })

  art <- page_fetch("http://127.0.0.1/p")
  expect_identical(art$outcome, "safety_refused")
  expect_false(state$called)
  expect_identical(art$hops, list())
  expect_true(is.na(art$final_url))
})

test_that("a redirect to a blocked host is refused at the redirect hop", {
  httr2::local_mocked_responses(list(
    page_mock_redirect("https://example.com/0", "http://192.168.1.10/internal")
  ))
  art <- page_fetch("https://example.com/0")
  expect_identical(art$outcome, "safety_refused")
  # The one performed hop (the redirect) is captured before the guard refuses.
  expect_length(art$hops, 1L)
})

test_that("a non-HTTP(S) scheme is refused as safety_refused", {
  art <- page_fetch("ftp://example.com/p")
  expect_identical(art$outcome, "safety_refused")
})

# ---- HTTPS->HTTP downgrade -> safety_refused (ADR-010 section 3) -------------

test_that("an https->http downgrade redirect classifies as safety_refused", {
  state <- new.env(parent = emptyenv())
  state$requested <- character(0)
  httr2::local_mocked_responses(function(req) {
    state$requested <- c(state$requested, req$url)
    page_mock_redirect("https://example.com/0", "http://example.com/1")
  })

  art <- page_fetch("https://example.com/0")
  expect_identical(art$outcome, "safety_refused")
  # The refused target is never requested; only the hop that issued the
  # downgrading Location was performed, and it is captured.
  expect_identical(state$requested, "https://example.com/0")
  expect_length(art$hops, 1L)
  expect_identical(art$hops[[1L]]$location, "http://example.com/1")
  expect_true(is.na(art$final_url))
  expect_length(art$body, 0L)
})

test_that("a downgrade deeper in the chain is refused at that hop", {
  httr2::local_mocked_responses(list(
    page_mock_redirect("https://example.com/0", "https://example.com/1"),
    page_mock_redirect("https://example.com/1", "http://example.com/2")
  ))
  art <- page_fetch("https://example.com/0")
  expect_identical(art$outcome, "safety_refused")
  expect_length(art$hops, 2L)
})

test_that("a downgrade outranks the redirect cap (safety over resource)", {
  # The downgrade sits on the hop that would ALSO exceed max_redirects = 1;
  # ADR-010 section 3 pins safety above the resource limit.
  httr2::local_mocked_responses(list(
    page_mock_redirect("https://example.com/0", "https://example.com/1"),
    page_mock_redirect("https://example.com/1", "http://example.com/2")
  ))
  art <- page_fetch(
    "https://example.com/0",
    limits = fetch_limits(max_redirects = 1L)
  )
  expect_identical(art$outcome, "safety_refused")
})

test_that("an http->https upgrade and same-scheme hops are not refused", {
  httr2::local_mocked_responses(list(
    page_mock_redirect("http://example.com/0", "https://example.com/1"),
    page_mock_redirect("https://example.com/1", "https://example.com/2"),
    page_mock_ok(url = "https://example.com/2")
  ))
  art <- page_fetch("http://example.com/0")
  expect_identical(art$outcome, "usable_body")
  expect_identical(art$final_url, "https://example.com/2")
})

test_that("an http->http hop is not a downgrade", {
  httr2::local_mocked_responses(list(
    page_mock_redirect("http://example.com/0", "http://example.com/1"),
    page_mock_ok(url = "http://example.com/1")
  ))
  art <- page_fetch("http://example.com/0")
  expect_identical(art$outcome, "usable_body")
})

test_that("page_hop_is_downgrade keys on scheme only, case-insensitively", {
  expect_true(page_hop_is_downgrade(
    "HTTPS://example.com/a",
    "HTTP://example.com/b"
  ))
  expect_false(page_hop_is_downgrade(
    "https://example.com/a",
    "https://example.com/b"
  ))
  expect_false(page_hop_is_downgrade(
    "http://example.com/a",
    "https://example.com/b"
  ))
})

# ---- redirect cap exceeded -> redirect_over_budget ---------------------------

test_that("exceeding the redirect cap classifies as redirect_over_budget", {
  httr2::local_mocked_responses(list(
    page_mock_redirect("https://example.com/0", "https://example.com/1"),
    page_mock_redirect("https://example.com/1", "https://example.com/2"),
    page_mock_redirect("https://example.com/2", "https://example.com/3"),
    page_mock_ok(url = "https://example.com/3")
  ))
  art <- page_fetch(
    "https://example.com/0",
    limits = fetch_limits(max_redirects = 2L)
  )
  expect_identical(art$outcome, "redirect_over_budget")
  expect_true(is.na(art$final_url))
  # All performed hops up to and including the over-budget redirect are kept.
  expect_length(art$hops, 3L)
})

# ---- transport failure with no body -> transport_fail ------------------------

test_that("a transport failure with no body classifies as transport_fail", {
  httr2::local_mocked_responses(function(req) {
    rlang::abort("Could not connect", class = c("httr2_failure", "httr2_error"))
  })
  art <- page_fetch("https://example.com/p")
  expect_identical(art$outcome, "transport_fail")
})

test_that("a transport timeout classifies as transport_fail", {
  httr2::local_mocked_responses(function(req) {
    rlang::abort(
      "Timeout was reached",
      class = c("httr2_timeout", "httr2_failure", "httr2_error")
    )
  })
  art <- page_fetch("https://example.com/p")
  expect_identical(art$outcome, "transport_fail")
})

# ---- not_applicable: nothing to fetch ----------------------------------------

test_that("an empty or NA URL yields not_applicable with no fetch", {
  state <- new.env(parent = emptyenv())
  state$called <- FALSE
  httr2::local_mocked_responses(function(req) {
    state$called <- TRUE
    page_mock_ok()
  })
  expect_identical(page_fetch("")$outcome, "not_applicable")
  expect_identical(page_fetch(NA_character_)$outcome, "not_applicable")
  expect_false(state$called)
})

# ---- request_user_agent is recorded (distinct from any engine token) ---------

test_that("the HTTP request User-Agent actually sent is recorded", {
  state <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(function(req) {
    state$captured <- req
    page_mock_ok()
  })
  ua <- "sitemapr-inspector/9"
  art <- page_fetch("https://example.com/p", user_agent = ua)
  expect_identical(art$request_user_agent, ua)
  expect_identical(state$captured$options$useragent, ua)
})

# ---- input record form (parity with fetch_source) ----------------------------

test_that("page_fetch accepts a one-row source record", {
  rec <- data.frame(
    normalized_url = "https://example.com/p",
    stringsAsFactors = FALSE
  )
  httr2::local_mocked_responses(list(page_mock_ok()))
  art <- page_fetch(rec)
  expect_identical(art$requested_url, "https://example.com/p")
  expect_identical(art$outcome, "usable_body")
})

# ---- FROZEN: fetch_source()'s existing output is unchanged -------------------

test_that("page inspection does not alter fetch_source's 13-column output", {
  body <- charToRaw("<?xml version=\"1.0\"?><urlset></urlset>")
  httr2::local_mocked_responses(list(
    page_mock_ok(url = "https://example.com/sitemap.xml", body = body)
  ))
  meta <- fetch_source("https://example.com/sitemap.xml")

  expect_identical(ncol(meta), 13L)
  expect_named(
    meta,
    c(
      "requested_url",
      "final_url",
      "status",
      "redirect_chain",
      "content_type",
      "charset",
      "bytes",
      "timing",
      "error_class",
      "format",
      "root",
      "namespaces",
      "profile_id"
    )
  )
  expect_identical(meta$status, 200L)
  # fetch_source() carries no page-artifact fields (they are a separate record).
  expect_false(any(
    c("hops", "terminal_headers", "outcome", "truncated") %in% names(meta)
  ))
})
