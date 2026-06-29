# Offline tests for the bounded, SSRF-safe fetch engine (R/fetch.R).
#
# All network behavior is exercised through httr2's native mocking
# (httr2::local_mocked_responses / response()); the real network is never hit,
# so the suite is CRAN-safe. The per-resource safety ceiling is exercised
# directly against read_capped_body() with synthetic chunks, because mocked
# responses are not real streams.

# A small helper: a 200 response carrying the given raw body + content type.
mock_ok <- function(
  url = "https://example.com/sitemap.xml",
  body = charToRaw("<?xml version=\"1.0\"?><urlset/>"),
  content_type = "application/xml; charset=UTF-8"
) {
  httr2::response(
    status_code = 200,
    url = url,
    headers = list("Content-Type" = content_type),
    body = body
  )
}

# A 3xx response carrying a Location header (manual-redirect input).
mock_redirect <- function(url, location, status = 301L) {
  httr2::response(
    status_code = status,
    url = url,
    headers = list(Location = location)
  )
}

# ---- SSRF: initial URL -------------------------------------------------------

test_that("a loopback initial URL aborts before any network call", {
  called <- FALSE
  httr2::local_mocked_responses(function(req) {
    called <<- TRUE
    mock_ok()
  })

  expect_error(
    fetch_source("http://127.0.0.1/sitemap.xml"),
    class = "sitemapr_ssrf_blocked"
  )
  expect_false(called)
})

test_that("the SSRF abort carries the reason and rejected url", {
  cnd <- rlang::catch_cnd(
    fetch_source("http://10.0.0.1/sitemap.xml"),
    classes = "sitemapr_ssrf_blocked"
  )
  expect_identical(cnd$reason, "private")
  expect_identical(cnd$url, "http://10.0.0.1/sitemap.xml")
})

test_that("the cloud-metadata endpoint is rejected with its reason", {
  cnd <- rlang::catch_cnd(
    fetch_source("http://169.254.169.254/latest/meta-data/"),
    classes = "sitemapr_ssrf_blocked"
  )
  expect_identical(cnd$reason, "cloud-metadata")
})

# ---- SSRF: per-hop redirect re-check -----------------------------------------

test_that("a redirect to an RFC-1918 target aborts at the redirect hop", {
  httr2::local_mocked_responses(list(
    mock_redirect(
      "https://example.com/sitemap.xml",
      "http://192.168.1.10/internal.xml"
    )
  ))

  cnd <- rlang::catch_cnd(
    fetch_source("https://example.com/sitemap.xml"),
    classes = "sitemapr_ssrf_blocked"
  )
  expect_identical(cnd$reason, "private")
  # The reason identifies the REDIRECT target, not the initial URL.
  expect_identical(cnd$url, "http://192.168.1.10/internal.xml")
})

# ---- SSRF disabled -----------------------------------------------------------

test_that("ssrf_guard = FALSE fetches a normally-blocked URL", {
  httr2::local_mocked_responses(list(
    mock_ok(url = "http://127.0.0.1/sitemap.xml")
  ))

  meta <- fetch_source("http://127.0.0.1/sitemap.xml", ssrf_guard = FALSE)
  expect_identical(meta$status, 200L)
  expect_identical(meta$format, "xml-urlset")
})

# ---- Redirects: within and over the limit ------------------------------------

test_that("4 redirects under a limit of 5 returns the final sitemap", {
  httr2::local_mocked_responses(list(
    mock_redirect("https://example.com/0", "https://example.com/1"),
    mock_redirect("https://example.com/1", "https://example.com/2"),
    mock_redirect("https://example.com/2", "https://example.com/3"),
    mock_redirect("https://example.com/3", "https://example.com/4"),
    mock_ok(url = "https://example.com/4")
  ))

  meta <- fetch_source(
    "https://example.com/0",
    limits = fetch_limits(max_redirects = 5L)
  )
  expect_identical(meta$status, 200L)
  expect_identical(meta$final_url, "https://example.com/4")
  # redirect_chain: 4 intermediate hops + the final URL.
  expect_length(meta$redirect_chain[[1L]], 5L)
})

test_that("6 redirects under a limit of 5 aborts with redirect_limit", {
  httr2::local_mocked_responses(list(
    mock_redirect("https://example.com/0", "https://example.com/1"),
    mock_redirect("https://example.com/1", "https://example.com/2"),
    mock_redirect("https://example.com/2", "https://example.com/3"),
    mock_redirect("https://example.com/3", "https://example.com/4"),
    mock_redirect("https://example.com/4", "https://example.com/5"),
    mock_redirect("https://example.com/5", "https://example.com/6"),
    mock_ok(url = "https://example.com/6")
  ))

  cnd <- rlang::catch_cnd(
    fetch_source(
      "https://example.com/0",
      limits = fetch_limits(max_redirects = 5L)
    ),
    classes = "sitemapr_redirect_limit"
  )
  expect_s3_class(cnd, "sitemapr_redirect_limit")
  expect_identical(cnd$max_redirects, 5L)
})

# ---- Safety ceiling: read_capped_body directly -------------------------------

test_that("read_capped_body raises sitemapr_body_ceiling on oversized input", {
  oversized <- list(as.raw(rep(0x41, 60L)), as.raw(rep(0x42, 60L)))
  expect_error(
    read_capped_body(oversized, max_bytes = 100L),
    class = "sitemapr_body_ceiling"
  )
})

test_that("read_capped_body returns the bytes when under the cap", {
  chunks <- list(as.raw(rep(0x41, 30L)), as.raw(rep(0x42, 20L)))
  out <- read_capped_body(chunks, max_bytes = 100L)
  expect_true(is.raw(out))
  expect_length(out, 50L)
})

test_that("read_capped_body discards the partial body over the ceiling", {
  cnd <- rlang::catch_cnd(
    read_capped_body(list(as.raw(rep(0x41, 200L))), max_bytes = 100L),
    classes = "sitemapr_body_ceiling"
  )
  expect_identical(cnd$max_bytes, 100)
  expect_gt(cnd$bytes_read, 100)
})

test_that("read_capped_body consumes a binary connection under the cap", {
  raw_vec <- as.raw(rep(0x7A, 40L))
  con <- rawConnection(raw_vec, open = "rb")
  on.exit(close(con), add = TRUE)
  out <- read_capped_body(con, max_bytes = 100L, chunk_size = 8L)
  expect_length(out, 40L)
})

test_that("read_capped_body returns an empty raw for empty input", {
  # No chunks at all, and a list whose only chunk is empty (the early-return
  # branch in consume()) both yield a zero-length raw, never NULL.
  expect_identical(read_capped_body(list(), max_bytes = 100L), raw())
  expect_identical(read_capped_body(list(raw(0)), max_bytes = 100L), raw())
})

# ---- timeout classification helper -------------------------------------------

test_that("fetch_is_timeout recognises httr2 timeouts and message probes", {
  httr2_to <- structure(
    list(message = "timed out"),
    class = c("httr2_timeout", "rlang_error", "error", "condition")
  )
  expect_true(fetch_is_timeout(httr2_to))
  # A mocked curl-style failure carries the marker only in its message.
  expect_true(fetch_is_timeout(simpleError("Timeout was reached")))
  # An unrelated transport failure is not a timeout.
  expect_false(fetch_is_timeout(simpleError("connection refused")))
})

# ---- record input (one-row source record instead of a bare URL) --------------

test_that("fetch_source accepts a record with normalized_url", {
  rec <- data.frame(
    normalized_url = "https://example.com/sitemap.xml",
    scheme_inferred = FALSE,
    stringsAsFactors = FALSE
  )
  httr2::local_mocked_responses(list(mock_ok()))
  meta <- fetch_source(rec)
  expect_identical(meta$requested_url, "https://example.com/sitemap.xml")
  expect_identical(meta$status, 200L)
})

test_that("fetch_source falls back to the record's url field", {
  rec <- list(url = "https://example.com/sitemap.xml")
  httr2::local_mocked_responses(list(mock_ok()))
  meta <- fetch_source(rec)
  expect_identical(meta$requested_url, "https://example.com/sitemap.xml")
})

# ---- Safety ceiling: through the fetch path ----------------------------------

test_that("a body over the safety ceiling aborts the fetch with body_ceiling", {
  big <- as.raw(rep(0x41, 50L))
  httr2::local_mocked_responses(list(
    mock_ok(url = "https://example.com/sitemap.xml", body = big)
  ))

  expect_error(
    fetch_source(
      "https://example.com/sitemap.xml",
      limits = fetch_limits(max_bytes = 10L)
    ),
    class = "sitemapr_body_ceiling"
  )
})

test_that("a body within the ceiling is recorded, not aborted", {
  # The 50 MB sitemap-protocol limit is a validation finding, NOT a fetch abort:
  # fetch records the body size and returns normally for any body under the
  # safety ceiling. (PROTOCOL_SIZE_EXCEEDED is emitted downstream, in Layer D.)
  body <- charToRaw("<?xml version=\"1.0\"?><urlset></urlset>")
  httr2::local_mocked_responses(list(
    mock_ok(url = "https://example.com/sitemap.xml", body = body)
  ))

  meta <- fetch_source(
    "https://example.com/sitemap.xml",
    limits = fetch_limits(max_bytes = 500L * 1024L^2)
  )
  expect_identical(meta$status, 200L)
  expect_identical(meta$bytes, length(body))
  expect_true(is.na(meta$error_class))
})

# ---- Timeout -----------------------------------------------------------------

test_that("a transport timeout aborts with sitemapr_timeout", {
  httr2::local_mocked_responses(function(req) {
    rlang::abort(
      "Timeout was reached",
      class = c("httr2_timeout", "httr2_failure", "httr2_error")
    )
  })

  expect_error(
    fetch_source("https://example.com/sitemap.xml"),
    class = "sitemapr_timeout"
  )
})

# ---- 4xx ---------------------------------------------------------------------

test_that("a 404 raises a warning and returns a record with the status", {
  httr2::local_mocked_responses(list(
    httr2::response(status_code = 404L, url = "https://example.com/missing.xml")
  ))

  meta <- NULL
  expect_warning(
    meta <- fetch_source("https://example.com/missing.xml"),
    class = "sitemapr_http_error"
  )
  expect_identical(meta$status, 404L)
  expect_identical(meta$error_class, "sitemapr_http_error")
})

# ---- User-Agent --------------------------------------------------------------

test_that("the request carries the default User-Agent", {
  captured <- NULL
  httr2::local_mocked_responses(function(req) {
    captured <<- req
    mock_ok()
  })

  fetch_source("https://example.com/sitemap.xml")
  expect_identical(captured$options$useragent, default_user_agent())
})

test_that("a custom user_agent overrides the default", {
  captured <- NULL
  httr2::local_mocked_responses(function(req) {
    captured <<- req
    mock_ok()
  })

  fetch_source("https://example.com/sitemap.xml", user_agent = "mybot/1.0")
  expect_identical(captured$options$useragent, "mybot/1.0")
})

# ---- Metadata contract -------------------------------------------------------

test_that("a successful fetch returns the 13-column metadata record", {
  body <- charToRaw("<?xml version=\"1.0\"?><urlset></urlset>")
  httr2::local_mocked_responses(list(
    mock_ok(url = "https://example.com/sitemap.xml", body = body)
  ))

  meta <- fetch_source("https://example.com/sitemap.xml")

  expect_identical(ncol(meta), 13L)
  expect_identical(
    names(meta),
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
  expect_identical(meta$requested_url, "https://example.com/sitemap.xml")
  expect_identical(meta$status, 200L)
  expect_identical(meta$format, sniff_format(body))
  expect_identical(meta$format, "xml-urlset")
  expect_identical(meta$content_type, "application/xml")
  expect_identical(meta$charset, "UTF-8")
  expect_identical(meta$bytes, length(body))
  expect_true(is.na(meta$error_class))
  # Downstream-populated fields keep their NA/empty defaults.
  expect_true(is.na(meta$root))
  expect_true(is.na(meta$profile_id))
})

# ---- https -> http fallback --------------------------------------------------

test_that("scheme_inferred = TRUE falls back to http when https fails", {
  schemes <- character(0)
  httr2::local_mocked_responses(function(req) {
    schemes <<- c(schemes, sub("://.*$", "", req$url))
    if (startsWith(req$url, "https://")) {
      rlang::abort(
        "Could not connect",
        class = c("httr2_failure", "httr2_error")
      )
    }
    mock_ok(url = req$url)
  })

  meta <- fetch_source(
    "https://example.com/sitemap.xml",
    scheme_inferred = TRUE
  )
  expect_identical(meta$status, 200L)
  expect_true(startsWith(meta$final_url, "http://"))
  expect_identical(schemes, c("https", "http"))
})

test_that("scheme_inferred = FALSE does not retry over http", {
  schemes <- character(0)
  httr2::local_mocked_responses(function(req) {
    schemes <<- c(schemes, sub("://.*$", "", req$url))
    rlang::abort("Could not connect", class = c("httr2_failure", "httr2_error"))
  })

  expect_error(
    fetch_source("https://example.com/sitemap.xml", scheme_inferred = FALSE),
    class = "sitemapr_timeout"
  )
  # Only the https attempt; no http downgrade.
  expect_identical(schemes, "https")
})
