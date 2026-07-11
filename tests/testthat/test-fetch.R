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
  state <- new.env(parent = emptyenv())
  state$called <- FALSE
  httr2::local_mocked_responses(function(req) {
    state$called <- TRUE
    mock_ok()
  })

  expect_error(
    fetch_source("http://127.0.0.1/sitemap.xml"),
    class = "sitemapr_ssrf_blocked"
  )
  expect_false(state$called)
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

test_that("a 3xx without a Location header is treated as a terminal response", {
  # A redirect status with no Location is not follow-able: it falls through to
  # terminal handling and is recorded as a non-2xx response (with a warning).
  httr2::local_mocked_responses(list(
    httr2::response(status_code = 302L, url = "https://example.com/moved")
  ))

  meta <- NULL
  expect_warning(
    meta <- fetch_source("https://example.com/moved"),
    class = "sitemapr_http_error"
  )
  expect_identical(meta$status, 302L)
  expect_identical(meta$error_class, "sitemapr_http_error")
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
  expect_type(out, "raw")
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
  state <- new.env(parent = emptyenv())
  state$captured <- NULL
  httr2::local_mocked_responses(function(req) {
    state$captured <- req
    mock_ok()
  })

  fetch_source("https://example.com/sitemap.xml")
  expect_identical(state$captured$options$useragent, default_user_agent())
})

test_that("a custom user_agent overrides the default", {
  state <- new.env(parent = emptyenv())
  state$captured <- NULL
  httr2::local_mocked_responses(function(req) {
    state$captured <- req
    mock_ok()
  })

  fetch_source("https://example.com/sitemap.xml", user_agent = "mybot/1.0")
  expect_identical(state$captured$options$useragent, "mybot/1.0")
})

# ---- Metadata contract -------------------------------------------------------

test_that("a successful fetch returns the 13-column metadata record", {
  body <- charToRaw("<?xml version=\"1.0\"?><urlset></urlset>")
  httr2::local_mocked_responses(list(
    mock_ok(url = "https://example.com/sitemap.xml", body = body)
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

# ---- request policy (fetch-boundary extension seam) --------------------------

test_that("the no-op request policy reproduces the default fetch behavior", {
  body <- charToRaw("<?xml version=\"1.0\"?><urlset></urlset>")
  httr2::local_mocked_responses(list(
    mock_ok(url = "https://example.com/sitemap.xml", body = body)
  ))

  meta <- fetch_source(
    "https://example.com/sitemap.xml",
    policy = request_policy()
  )
  expect_identical(meta$status, 200L)
  expect_identical(meta$format, "xml-urlset")
})

test_that("a request policy can add a harmless header to the request", {
  state <- new.env(parent = emptyenv())
  state$captured <- NULL
  httr2::local_mocked_responses(function(req) {
    state$captured <- req
    mock_ok()
  })

  policy <- request_policy(
    prepare = function(req, ctx) httr2::req_headers(req, "X-Test" = "sitemapr")
  )
  fetch_source("https://example.com/sitemap.xml", policy = policy)
  expect_identical(state$captured$headers[["X-Test"]], "sitemapr")
})

test_that("request_policy rejects a non-function prepare hook", {
  expect_error(
    request_policy(prepare = "not a function"),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("a prepare hook returning a non-request is rejected", {
  policy <- request_policy(prepare = function(req, ctx) "not a request")
  httr2::local_mocked_responses(list(mock_ok()))
  expect_error(
    fetch_source("https://example.com/sitemap.xml", policy = policy),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("the policy hook receives each hop's resolved url as context", {
  state <- new.env(parent = emptyenv())
  state$urls <- character(0)
  httr2::local_mocked_responses(list(
    mock_redirect("https://example.com/0", "https://example.com/1"),
    mock_ok(url = "https://example.com/1")
  ))

  policy <- request_policy(prepare = function(req, ctx) {
    state$urls <- c(state$urls, ctx$url)
    req
  })
  fetch_source("https://example.com/0", policy = policy)
  # One prepare per hop, each carrying that hop's resolved URL.
  expect_identical(
    state$urls,
    c("https://example.com/0", "https://example.com/1")
  )
})

test_that("a policy cannot override sitemapr's redirect controls", {
  state <- new.env(parent = emptyenv())
  state$captured <- NULL
  httr2::local_mocked_responses(function(req) {
    state$captured <- req
    mock_ok()
  })

  # A hostile hook tries to re-enable auto-redirect; sitemapr re-asserts its
  # own transport controls AFTER the hook, so these get overwritten.
  policy <- request_policy(prepare = function(req, ctx) {
    httr2::req_options(req, followlocation = 1L, maxredirs = 99L)
  })
  fetch_source("https://example.com/sitemap.xml", policy = policy)
  expect_identical(state$captured$options$followlocation, 0L)
  expect_identical(state$captured$options$maxredirs, 0L)
})

test_that("guard runs before prepare, and prepare before perform", {
  order <- new.env(parent = emptyenv())
  order$events <- character(0)
  httr2::local_mocked_responses(function(req) {
    order$events <- c(order$events, "perform")
    mock_ok()
  })

  policy <- request_policy(prepare = function(req, ctx) {
    order$events <- c(order$events, "prepare")
    req
  })

  # Allowed host: prepare records before perform.
  fetch_source("https://example.com/sitemap.xml", policy = policy)
  expect_identical(order$events, c("prepare", "perform"))

  # Blocked host: the SSRF guard aborts BEFORE prepare or perform can run,
  # proving guard precedes prepare (which precedes perform).
  order$events <- character(0)
  expect_error(
    fetch_source("http://127.0.0.1/sitemap.xml", policy = policy),
    class = "sitemapr_ssrf_blocked"
  )
  expect_identical(order$events, character(0))
})

# ---- request policy: typed customization fields ------------------------------

# Capture the built request handed to req_perform() for one fetch.
capture_request <- function(policy) {
  state <- new.env(parent = emptyenv())
  state$captured <- NULL
  httr2::local_mocked_responses(function(req) {
    state$captured <- req
    mock_ok()
  })
  fetch_source("https://example.com/sitemap.xml", policy = policy)
  state$captured
}

test_that("a typed header field reaches the request", {
  req <- capture_request(
    request_policy(headers = list("X-Env" = "staging"))
  )
  expect_identical(req$headers[["X-Env"]], "staging")
})

test_that("basic auth reaches the request as an Authorization header", {
  req <- capture_request(
    request_policy(auth = request_auth_basic("user", "secret"))
  )
  expect_false(is.null(req$headers[["Authorization"]]))
})

test_that("bearer auth reaches the request as an Authorization header", {
  req <- capture_request(
    request_policy(auth = request_auth_bearer("a-token"))
  )
  expect_false(is.null(req$headers[["Authorization"]]))
})

test_that("a proxy URL string reaches the request options", {
  req <- capture_request(request_policy(proxy = "http://proxy.internal:3128"))
  expect_identical(req$options$proxy, "http://proxy.internal:3128")
})

test_that("a request_proxy() object reaches the request options", {
  req <- capture_request(
    request_policy(proxy = request_proxy("proxy.internal", port = 3128L))
  )
  expect_identical(req$options$proxy, "proxy.internal")
  expect_identical(as.integer(req$options$proxyport), 3128L)
})

test_that("tls options reach the request options", {
  req <- capture_request(request_policy(tls = list(ssl_verifypeer = 0L)))
  expect_identical(as.integer(req$options$ssl_verifypeer), 0L)
})

test_that("the default policy adds no headers, auth, proxy, or tls options", {
  # Byte-identical baseline: a bare request_policy() touches only the fields
  # sitemapr always sets (user-agent + its own transport controls).
  req <- capture_request(request_policy())
  expect_null(req$headers[["Authorization"]])
  expect_null(req$options$proxy)
  expect_null(req$options$ssl_verifypeer)
})

# ---- request policy: safety invariant (caller cannot override) ---------------

test_that("tls options cannot override sitemapr's redirect controls", {
  # A caller smuggling redirect curl options through `tls` is overwritten by
  # sitemapr's controls, which are re-asserted last.
  req <- capture_request(
    request_policy(tls = list(followlocation = 1L, maxredirs = 99L))
  )
  expect_identical(req$options$followlocation, 0L)
  expect_identical(req$options$maxredirs, 0L)
})

test_that("typed fields still run behind the per-hop SSRF guard", {
  # The guard aborts before any request is built, so a header/proxy policy on a
  # blocked host never reaches the network.
  state <- new.env(parent = emptyenv())
  state$called <- FALSE
  httr2::local_mocked_responses(function(req) {
    state$called <- TRUE
    mock_ok()
  })
  policy <- request_policy(
    headers = list("X-Env" = "staging"),
    proxy = "http://proxy.internal:3128"
  )
  expect_error(
    fetch_source("http://127.0.0.1/sitemap.xml", policy = policy),
    class = "sitemapr_ssrf_blocked"
  )
  expect_false(state$called)
})

# ---- request policy: constructor validation ----------------------------------

test_that("request_policy rejects an unnamed headers value", {
  expect_error(
    request_policy(headers = list("no-name-here")),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("request_policy rejects a non-auth object", {
  expect_error(
    request_policy(auth = list(scheme = "basic")),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("request_policy rejects a malformed proxy value", {
  expect_error(
    request_policy(proxy = 3128L),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("request_policy rejects an unnamed tls value", {
  expect_error(
    request_policy(tls = list(0L)),
    class = "sitemapr_invalid_request_policy"
  )
})

# ---- request policy: retry and exponential backoff ---------------------------

# A response with a specific status (retryable-status fixtures).
mock_status <- function(status, url = "https://example.com/sitemap.xml",
                        headers = list()) {
  httr2::response(status_code = status, url = url, headers = headers)
}

test_that("the default policy attaches no retry (single attempt preserved)", {
  req <- capture_request(request_policy())
  expect_null(req$policies$retry_max_tries)
})

test_that("a retry policy reaches the request with its max_tries budget", {
  req <- capture_request(request_policy(retry = request_retry(max_tries = 4L)))
  expect_identical(req$policies$retry_max_tries, 4L)
  expect_false(is.null(req$policies$retry_is_transient))
})

test_that("is_transient marks the retryable status set as transient", {
  req <- capture_request(request_policy(retry = request_retry()))
  is_transient <- req$policies$retry_is_transient
  # The default transient set recovers (drives retry) within budget.
  for (status in c(429L, 500L, 502L, 503L, 504L)) {
    expect_true(is_transient(mock_status(status)))
  }
})

test_that("is_transient does NOT retry success or deterministic 4xx", {
  req <- capture_request(request_policy(retry = request_retry()))
  is_transient <- req$policies$retry_is_transient
  # A 200 is terminal; a 404 (missing) and 400 (bad request) are deterministic
  # HTTP failures and must keep their existing condition/finding behavior.
  expect_false(is_transient(mock_status(200L)))
  expect_false(is_transient(mock_status(404L)))
  expect_false(is_transient(mock_status(400L)))
})

test_that("a custom retryable status set overrides the default", {
  req <- capture_request(
    request_policy(retry = request_retry(statuses = c(503L, 429L)))
  )
  is_transient <- req$policies$retry_is_transient
  expect_true(is_transient(mock_status(503L)))
  expect_false(is_transient(mock_status(500L)))
})

test_that("Retry-After is honored but bounded by the configured max backoff", {
  retry <- request_retry(backoff_max = 30)
  # A giant Retry-After collapses to the ceiling (no unbounded sleep).
  huge <- mock_status(503L, headers = list("Retry-After" = "9999"))
  expect_identical(retry_after_bounded(huge, retry$backoff_max), 30)
  # A small Retry-After is honored verbatim.
  small <- mock_status(503L, headers = list("Retry-After" = "5"))
  expect_identical(retry_after_bounded(small, retry$backoff_max), 5)
  # Absent / non-numeric header => NA, so httr2 falls back to bounded backoff.
  none <- mock_status(503L)
  expect_true(is.na(retry_after_bounded(none, retry$backoff_max)))
  date <- mock_status(503L, headers = list("Retry-After" = "Wed, 21 Oct 2099"))
  expect_true(is.na(retry_after_bounded(date, retry$backoff_max)))
})

test_that("exponential backoff grows then clamps to the max", {
  # Deterministic and instant: never sleeps.
  expect_identical(retry_backoff_seconds(1L, 1, 30), 1)
  expect_identical(retry_backoff_seconds(2L, 1, 30), 2)
  expect_identical(retry_backoff_seconds(3L, 1, 30), 4)
  # Runaway multiplier is clamped to backoff_max.
  expect_identical(retry_backoff_seconds(10L, 1, 30), 30)
})

test_that("both root and index-child requests carry the retry policy", {
  # Children are fetched through the same fetch_source path with the shared
  # policy, so retry reaches every hop. Capture two distinct fetches.
  policy <- request_policy(retry = request_retry(max_tries = 3L))
  root <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(function(req) {
    root$captured <- req
    mock_ok(url = req$url)
  })
  fetch_source("https://example.com/sitemap_index.xml", policy = policy)
  expect_identical(root$captured$policies$retry_max_tries, 3L)

  child <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(function(req) {
    child$captured <- req
    mock_ok(url = req$url)
  })
  fetch_source("https://example.com/child-1.xml", policy = policy)
  expect_identical(child$captured$policies$retry_max_tries, 3L)
})

test_that("retry runs behind the per-hop SSRF guard (never retries SSRF)", {
  # The SSRF guard aborts before the request is built, so retry cannot re-run a
  # blocked host: no request reaches req_perform() at all.
  state <- new.env(parent = emptyenv())
  state$called <- FALSE
  httr2::local_mocked_responses(function(req) {
    state$called <- TRUE
    mock_ok()
  })
  policy <- request_policy(retry = request_retry())
  expect_error(
    fetch_source("http://127.0.0.1/sitemap.xml", policy = policy),
    class = "sitemapr_ssrf_blocked"
  )
  expect_false(state$called)
})

test_that("retry leaves sitemapr's redirect controls intact", {
  req <- capture_request(request_policy(retry = request_retry()))
  # Retry lives in its own policy slot; sitemapr's transport controls remain.
  expect_identical(req$options$followlocation, 0L)
  expect_identical(req$options$maxredirs, 0L)
})

test_that("request_retry rejects an invalid max_tries", {
  expect_error(
    request_retry(max_tries = 0L),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("request_retry rejects an empty status set", {
  expect_error(
    request_retry(statuses = integer(0)),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("request_policy rejects a non-retry object", {
  expect_error(
    request_policy(retry = list(max_tries = 3L)),
    class = "sitemapr_invalid_request_policy"
  )
})

# ---- request policy: host-aware throttling -----------------------------------

# A virtual clock for deterministic pacing: `now()` reads the current virtual
# time; `sleep(seconds)` records the delay and advances the clock. The suite
# therefore NEVER sleeps on the real wall clock (the deterministic-test bar).
fake_clock <- function(start = 1000) {
  cl <- new.env(parent = emptyenv())
  cl$t <- start
  cl$slept <- numeric(0)
  cl$now <- function() cl$t
  cl$sleep <- function(seconds) {
    cl$slept <- c(cl$slept, seconds)
    cl$t <- cl$t + seconds
  }
  cl
}

test_that("request_throttle derives the interval from a request budget", {
  # requests-per-window: 10 requests / 60 s -> one every 6 s, evenly paced.
  expect_identical(request_throttle(requests = 10, window = 60)$min_interval, 6)
  # A direct minimum interval is kept verbatim.
  expect_identical(request_throttle(min_interval = 2.5)$min_interval, 2.5)
})

test_that("request_throttle rejects a non-positive or incomplete config", {
  expect_error(
    request_throttle(min_interval = 0),
    class = "sitemapr_invalid_request_policy"
  )
  expect_error(
    request_throttle(min_interval = -1),
    class = "sitemapr_invalid_request_policy"
  )
  # A budget needs BOTH requests and window.
  expect_error(
    request_throttle(requests = 10),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("request_policy rejects a non-throttle object", {
  expect_error(
    request_policy(throttle = list(min_interval = 1)),
    class = "sitemapr_invalid_request_policy"
  )
})

test_that("the default (throttle = NULL) policy paces nothing", {
  # No throttle configured -> a NULL state -> throttle_before_request no-ops.
  expect_null(request_policy()$throttle)
  expect_null(throttle_state_new(request_policy()$throttle))
  # And a default-policy fetch still completes normally (nothing to pace).
  httr2::local_mocked_responses(list(mock_ok()))
  meta <- fetch_source("https://example.com/sitemap.xml")
  expect_identical(meta$status, 200L)
})

test_that("a policy throttle config builds a live per-host state", {
  policy <- request_policy(throttle = request_throttle(min_interval = 2))
  state <- throttle_state_new(policy$throttle)
  expect_true(is.environment(state))
  expect_identical(state$min_interval, 2)
})

test_that("two requests to the same host are paced by the interval", {
  cl <- fake_clock()
  state <- throttle_state_new(
    request_throttle(min_interval = 10),
    now = cl$now,
    sleep = cl$sleep
  )
  httr2::local_mocked_responses(function(req) mock_ok(url = req$url))

  fetch_source("https://example.com/a.xml", throttle_state = state)
  # First request is free; the second waits one full interval on the same host.
  expect_identical(cl$slept, numeric(0))
  fetch_source("https://example.com/b.xml", throttle_state = state)
  expect_identical(cl$slept, 10)
})

test_that("two different hosts are not paced against each other", {
  cl <- fake_clock()
  state <- throttle_state_new(
    request_throttle(min_interval = 10),
    now = cl$now,
    sleep = cl$sleep
  )
  httr2::local_mocked_responses(function(req) mock_ok(url = req$url))

  fetch_source("https://a.example.com/s.xml", throttle_state = state)
  fetch_source("https://b.example.com/s.xml", throttle_state = state)
  # Independent buckets: distinct origins never wait on each other.
  expect_identical(cl$slept, numeric(0))
})

test_that("a redirect to another host waits on that host's own bucket", {
  cl <- fake_clock()
  state <- throttle_state_new(
    request_throttle(min_interval = 10),
    now = cl$now,
    sleep = cl$sleep
  )

  # Prime ONLY the redirect-target host's bucket with an earlier request.
  httr2::local_mocked_responses(list(
    mock_ok(url = "https://target.example.com/x")
  ))
  fetch_source("https://target.example.com/x", throttle_state = state)
  expect_identical(cl$slept, numeric(0))

  # A fetch on a different origin that redirects onto the target: the origin hop
  # is free (its bucket is empty) but the redirect hop pays the target's pace.
  httr2::local_mocked_responses(list(
    mock_redirect(
      "https://origin.example.com/0",
      "https://target.example.com/1"
    ),
    mock_ok(url = "https://target.example.com/1")
  ))
  fetch_source("https://origin.example.com/0", throttle_state = state)
  expect_identical(cl$slept, 10)
})

# ---- https -> http fallback --------------------------------------------------

test_that("scheme_inferred = TRUE falls back to http when https fails", {
  state <- new.env(parent = emptyenv())
  state$schemes <- character(0)
  httr2::local_mocked_responses(function(req) {
    state$schemes <- c(state$schemes, sub("://.*$", "", req$url))
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
  expect_identical(state$schemes, c("https", "http"))
})

test_that("scheme_inferred = FALSE does not retry over http", {
  state <- new.env(parent = emptyenv())
  state$schemes <- character(0)
  httr2::local_mocked_responses(function(req) {
    state$schemes <- c(state$schemes, sub("://.*$", "", req$url))
    rlang::abort("Could not connect", class = c("httr2_failure", "httr2_error"))
  })

  expect_error(
    fetch_source("https://example.com/sitemap.xml", scheme_inferred = FALSE),
    class = "sitemapr_timeout"
  )
  # Only the https attempt; no http downgrade.
  expect_identical(state$schemes, "https")
})
