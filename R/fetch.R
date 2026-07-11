# Bounded, SSRF-safe HTTP fetch engine (Layer A; ADR-003).
#
# Internal only. `fetch_source()` performs a single bounded HTTP request for one
# source, following redirects MANUALLY (httr2 auto-redirect disabled) so the
# structural SSRF guard (R/ssrf.R) can re-evaluate every hop before any network
# call. The per-resource safety-ceiling check is factored into
# `read_capped_body()`, a connection/chunk consumer that is unit-tested directly
# with synthetic oversized input (httr2 mocked responses are not real streams).
# Fetch is BUFFERED for v1 (ADR-003): req_perform() downloads the body, then the
# ceiling is applied to the buffered bytes. The 50 MB sitemap-protocol limit is
# NOT a fetch abort — it is a downstream validation finding; fetch only records
# the body size (`bytes`).
#
# Reused internals (do NOT reimplement here):
#   parse_url_adapter()  R/url.R         rurl parse -> components data.frame
#   ssrf_check_parsed()  R/ssrf.R        per-hop structural SSRF check
#   sniff_format()       R/sniff.R       raw bytes -> format string
#   fetch_limits(), default_user_agent(), source_metadata()  R/fetch-config.R
#
# Classed conditions raised (all carry structured data fields):
#   sitemapr_ssrf_blocked   abort  reason, url
#   sitemapr_redirect_limit abort  url, max_redirects, redirect_chain
#   sitemapr_body_ceiling   abort  max_bytes, bytes_read
#   sitemapr_timeout        abort  url, timeout
#   sitemapr_http_error     warn   status, url, error_class (non-abort)

# ---- per-resource safety ceiling ---------------------------------------------

# Consume a body source and enforce the per-resource safety ceiling, discarding
# the body the moment the running count EXCEEDS `max_bytes`. Factored out of the
# network path so the cap is testable offline with synthetic input. This is the
# memory backstop (ADR-003 §3), NOT the 50 MB protocol limit (a downstream
# validation finding).
#
# `source` is either:
#   * a `connection` opened in binary mode (read in fixed-size chunks), or
#   * a list of raw vectors (synthetic "chunks", used by unit tests), or
#   * a single raw vector (treated as one chunk).
#
# Returns the assembled raw vector when the total stays within the ceiling.
# Raises a `sitemapr_body_ceiling` abort (NEVER returning the partial bytes)
# once the running total exceeds the ceiling.
read_capped_body <- function(source, max_bytes, chunk_size = 65536L) {
  max_bytes <- as.numeric(max_bytes)
  state <- new.env(parent = emptyenv())
  state$total <- 0
  state$acc <- list()

  consume <- function(chunk) {
    if (length(chunk) == 0L) {
      return(invisible())
    }
    state$total <- state$total + length(chunk)
    if (state$total > max_bytes) {
      # Discard everything read so far; an over-ceiling body is never returned.
      state$acc <- list()
      rlang::abort(
        sprintf(
          "Body exceeded the %.0f-byte per-resource safety ceiling; discarded.",
          max_bytes
        ),
        class = "sitemapr_body_ceiling",
        max_bytes = max_bytes,
        bytes_read = state$total
      )
    }
    state$acc[[length(state$acc) + 1L]] <- chunk
    invisible()
  }

  read_capped_drain(source, chunk_size, consume)

  if (length(state$acc) == 0L) {
    return(raw())
  }
  do.call(c, state$acc)
}

# Drive one body source through `consume`, one chunk at a time. The source is a
# binary connection (read in fixed-size chunks), a list of raw vectors, or a
# single raw vector. `consume` (supplied by read_capped_body) enforces the
# ceiling and accumulates; this helper only handles the source-shape dispatch.
read_capped_drain <- function(source, chunk_size, consume) {
  if (inherits(source, "connection")) {
    repeat {
      chunk <- readBin(source, what = "raw", n = chunk_size)
      if (length(chunk) == 0L) {
        break
      }
      consume(chunk)
    }
  } else if (is.list(source)) {
    for (chunk in source) {
      consume(if (is.raw(chunk)) chunk else as.raw(chunk))
    }
  } else {
    consume(if (is.raw(source)) source else as.raw(source))
  }
  invisible()
}

# ---- condition / error classification helpers --------------------------------

# Distinguish a timeout from a generic transport failure. httr2's real timeout
# carries class `httr2_timeout`; otherwise fall back to a message probe so a
# mocked curl-style failure ("Timeout was reached") is also recognised.
fetch_is_timeout <- function(cnd) {
  if (inherits(cnd, "httr2_timeout")) {
    return(TRUE)
  }
  msg <- tryCatch(conditionMessage(cnd), error = function(e) "")
  grepl("tim\\s*e?d?\\s*out|timeout", msg, ignore.case = TRUE)
}

# ---- request policy (fetch-boundary extension seam) --------------------------

#' Construct a request-policy for the fetch boundary
#'
#' A request-policy is the single, constrained extension seam for customizing
#' the httr2 requests sitemapr issues for every hop (root, redirect, discovery,
#' robots, and index-child requests). It carries typed fields for custom HTTP
#' headers, authentication, a proxy, and TLS/curl options, plus a generic
#' `prepare` hook for anything not covered by the typed fields. Every field
#' defaults to `NULL`, so the default policy is a byte-identical no-op and
#' existing callers behave exactly as before.
#'
#' **What callers may set.** `headers`, `auth`, `proxy`, `tls`, and `prepare`
#' are all applied to each hop's request AFTER the per-hop SSRF guard and
#' BEFORE sitemapr asserts its own transport controls.
#'
#' **What sitemapr always owns (callers cannot override).** Redirect control
#' (`followlocation = 0`, `maxredirs = 0`) and the non-2xx error policy are
#' re-applied by [fetch_perform_one()] *after* all caller customization, and the
#' structural SSRF guard re-runs on every redirect hop before any network call.
#' A policy therefore cannot re-enable automatic redirect following, defeat the
#' per-hop SSRF re-check, or turn a non-2xx status into a transport error — even
#' via `tls`/`prepare` — because sitemapr's controls win last.
#'
#' @param prepare Optional `function(req, ctx)` receiving the built httr2
#'   request plus a hop-context list (currently the resolved hop `url`) and
#'   returning the possibly-modified request. Applied last of the caller-facing
#'   steps, so it composes on top of the typed fields.
#' @param headers Optional named list or named character vector of HTTP headers
#'   to add via `httr2::req_headers()`.
#' @param auth Optional authentication object from [request_auth_basic()] or
#'   [request_auth_bearer()], applied via `httr2::req_auth_basic()` /
#'   `httr2::req_auth_bearer_token()`.
#' @param proxy Optional proxy: either a proxy URL string or a
#'   [request_proxy()] object, applied via `httr2::req_proxy()`.
#' @param tls Optional named list of curl/TLS options (e.g.
#'   `list(ssl_verifypeer = 0L)`) passed through `httr2::req_options()`. Cannot
#'   override sitemapr's redirect controls, which are re-asserted afterwards.
#' @param throttle Optional [request_throttle()] object enabling host-aware
#'   request pacing. `NULL` (the default) means no pacing, byte-identical to
#'   the pre-throttle behavior. When set, requests are keyed by canonical
#'   host:port, so different origins pace independently and a redirect onto
#'   another host pays that host's pace, not the origin's. Pacing runs around
#'   each request (after the per-hop SSRF guard and sitemapr's re-asserted
#'   transport controls), so it never weakens those safety semantics.
#' @param retry Optional [request_retry()] object enabling bounded retry with
#'   exponential backoff. `NULL` (the default) means a single attempt per hop —
#'   byte-identical to the pre-retry behavior. When set, only TRANSIENT failures
#'   retry: the retryable HTTP status set (default `429, 500, 502, 503, 504`)
#'   and, when `retry_on_failure = TRUE`, transient transport errors. Retries
#'   happen inside a single hop's `req_perform()`, so they never inflate the
#'   redirect/hop count or consume the redirect budget. Deterministic failures
#'   are NEVER retried: SSRF rejections (raised before the request), malformed
#'   input (classified downstream), and resource-ceiling aborts (raised after
#'   the response is buffered) all sit outside the retried code path. Any
#'   `Retry-After` header is honored but BOUNDED by the configured max backoff.
#' @return An object of class `sitemapr_request_policy`.
#' @examples
#' # (1) A custom header (e.g. to satisfy a staging gateway).
#' request_policy(headers = list("X-Env" = "staging"))
#'
#' # (2) Basic and bearer authentication.
#' request_policy(auth = request_auth_basic("user", "secret"))
#' request_policy(auth = request_auth_bearer("a-token"))
#'
#' # (3) A corporate proxy.
#' request_policy(proxy = "http://proxy.internal:3128")
#' request_policy(proxy = request_proxy("proxy.internal", port = 3128))
#' @keywords internal
#' @noRd
request_policy <- function(prepare = NULL, headers = NULL, auth = NULL,
                           proxy = NULL, tls = NULL, retry = NULL,
                           throttle = NULL) {
  request_policy_check_prepare(prepare)
  request_policy_check_auth(auth)
  structure(
    list(
      prepare = prepare,
      headers = request_policy_check_headers(headers),
      auth = auth,
      proxy = request_policy_check_proxy(proxy),
      tls = request_policy_check_tls(tls),
      retry = request_policy_check_retry(retry),
      throttle = request_policy_check_throttle(throttle)
    ),
    class = "sitemapr_request_policy"
  )
}

# Raise the shared invalid-policy abort. Factored out so each field validator
# stays a single small guarded block (keeps the constructor's complexity low).
request_policy_reject <- function(message) {
  rlang::abort(message, class = "sitemapr_invalid_request_policy")
}

request_policy_check_prepare <- function(prepare) {
  if (!is.null(prepare) && !is.function(prepare)) {
    request_policy_reject(
      "`prepare` must be NULL or a function(req, ctx) returning a request."
    )
  }
  invisible(prepare)
}

request_policy_check_headers <- function(headers) {
  if (is.null(headers)) {
    return(NULL)
  }
  headers <- as.list(headers)
  if (length(headers) == 0L) {
    return(NULL)
  }
  nms <- names(headers)
  if (is.null(nms) || any(!nzchar(nms))) {
    request_policy_reject(
      "`headers` must be a named list or character vector of header values."
    )
  }
  headers
}

request_policy_check_auth <- function(auth) {
  if (!is.null(auth) && !inherits(auth, "sitemapr_request_auth")) {
    request_policy_reject(
      "`auth` must be NULL, request_auth_basic(), or request_auth_bearer()."
    )
  }
  invisible(auth)
}

request_policy_check_proxy <- function(proxy) {
  if (is.null(proxy)) {
    return(NULL)
  }
  if (is.character(proxy) && length(proxy) == 1L) {
    return(request_proxy(url = proxy))
  }
  if (!inherits(proxy, "sitemapr_request_proxy")) {
    request_policy_reject(
      "`proxy` must be NULL, a proxy URL string, or request_proxy()."
    )
  }
  proxy
}

request_policy_check_tls <- function(tls) {
  if (is.null(tls)) {
    return(NULL)
  }
  tls <- as.list(tls)
  if (length(tls) == 0L) {
    return(NULL)
  }
  nms <- names(tls)
  if (is.null(nms) || any(!nzchar(nms))) {
    request_policy_reject(
      "`tls` must be a named list of curl/TLS options for req_options()."
    )
  }
  tls
}

request_policy_check_retry <- function(retry) {
  if (is.null(retry)) {
    return(NULL)
  }
  if (!inherits(retry, "sitemapr_request_retry")) {
    request_policy_reject("`retry` must be NULL or a request_retry() object.")
  }
  retry
}

request_policy_check_throttle <- function(throttle) {
  if (is.null(throttle)) {
    return(NULL)
  }
  if (!inherits(throttle, "sitemapr_request_throttle")) {
    request_policy_reject(
      "`throttle` must be NULL or a request_throttle() object."
    )
  }
  throttle
}

#' Basic-authentication credentials for a request-policy
#'
#' @param username,password Credential strings, applied via
#'   `httr2::req_auth_basic()`.
#' @return A `sitemapr_request_auth` object for `request_policy(auth = )`.
#' @keywords internal
#' @noRd
request_auth_basic <- function(username, password) {
  structure(
    list(scheme = "basic", username = username, password = password),
    class = "sitemapr_request_auth"
  )
}

#' Bearer-token authentication for a request-policy
#'
#' @param token Bearer token string, applied via
#'   `httr2::req_auth_bearer_token()`.
#' @return A `sitemapr_request_auth` object for `request_policy(auth = )`.
#' @keywords internal
#' @noRd
request_auth_bearer <- function(token) {
  structure(
    list(scheme = "bearer", token = token),
    class = "sitemapr_request_auth"
  )
}

#' Proxy settings for a request-policy
#'
#' @param url Proxy host or URL.
#' @param port Optional proxy port.
#' @param username,password Optional proxy credentials.
#' @param auth Proxy authentication scheme (`httr2::req_proxy()` default
#'   `"basic"`).
#' @return A `sitemapr_request_proxy` object for `request_policy(proxy = )`.
#' @keywords internal
#' @noRd
request_proxy <- function(url, port = NULL, username = NULL,
                          password = NULL, auth = "basic") {
  structure(
    list(
      url = url,
      port = port,
      username = username,
      password = password,
      auth = auth
    ),
    class = "sitemapr_request_proxy"
  )
}

#' Retry-and-backoff settings for a request-policy
#'
#' Configures bounded retry with exponential backoff for a request-policy. Pass
#' the result as `request_policy(retry = )`. Only TRANSIENT failures retry: the
#' retryable HTTP `statuses` set, plus transient transport errors when
#' `retry_on_failure = TRUE`. Deterministic failures (SSRF, malformed input,
#' resource-ceiling aborts) are never retried because they surface outside the
#' single-hop `req_perform()` that retry wraps.
#'
#' @param max_tries Total attempts per hop (>= 1). `1` means no retry.
#' @param statuses Integer vector of retryable HTTP statuses. Defaults to the
#'   transient set `429, 500, 502, 503, 504`.
#' @param backoff_min,backoff_max Lower/upper bounds (seconds) for the
#'   exponential backoff between attempts. The delay for attempt `i` is
#'   `backoff_min * 2^(i - 1)`, clamped to `backoff_max`. A `Retry-After` header
#'   is honored but likewise bounded by `backoff_max`, so no unbounded sleep.
#' @param retry_on_failure When `TRUE`, transient transport errors (curl
#'   failures) are also retried. Defaults to `FALSE` (status-driven retry only).
#' @return A `sitemapr_request_retry` object for `request_policy(retry = )`.
#' @keywords internal
#' @noRd
request_retry <- function(max_tries = 3L,
                          statuses = c(429L, 500L, 502L, 503L, 504L),
                          backoff_min = 1, backoff_max = 30,
                          retry_on_failure = FALSE) {
  request_retry_check_tries(max_tries)
  request_retry_check_statuses(statuses)
  structure(
    list(
      max_tries = as.integer(max_tries)[[1L]],
      statuses = as.integer(statuses),
      backoff_min = max(0, as.numeric(backoff_min)[[1L]]),
      backoff_max = max(0, as.numeric(backoff_max)[[1L]]),
      retry_on_failure = isTRUE(retry_on_failure)
    ),
    class = "sitemapr_request_retry"
  )
}

request_retry_check_tries <- function(max_tries) {
  ok <- is.numeric(max_tries) && length(max_tries) == 1L && max_tries >= 1
  if (!ok) {
    request_policy_reject("`max_tries` must be a single number >= 1.")
  }
  invisible(max_tries)
}

request_retry_check_statuses <- function(statuses) {
  if (!is.numeric(statuses) || length(statuses) == 0L) {
    request_policy_reject("`statuses` must be a non-empty integer status set.")
  }
  invisible(statuses)
}

#' Host-aware request-throttle settings for a request-policy
#'
#' Configures per-host request pacing for a request-policy. Pass the result as
#' `request_policy(throttle = )`. Requests are keyed by canonical host:port, so
#' different origins pace independently and a redirect onto another host pays
#' that host's pace, not the origin's. Supply EITHER a minimum interval between
#' consecutive requests to one host (`min_interval`, seconds) OR a request
#' budget per time window (`requests` per `window` seconds, evenly paced at
#' `window / requests`). Pacing is shared across every hop of one logical
#' operation (roots, redirects, robots, discovery candidates, and index
#' children), so an index traversal's many children pace against one set of host
#' buckets. `NULL` (the default policy field) means no pacing.
#'
#' @param min_interval Minimum seconds between consecutive requests to one host.
#' @param requests,window A request budget: at most `requests` requests per
#'   `window` seconds to one host, evenly paced (interval `window / requests`).
#'   Both must be supplied together and take precedence over `min_interval`.
#' @return A `sitemapr_request_throttle` for `request_policy(throttle = )`.
#' @examples
#' # At most one request per host every 2 seconds.
#' request_throttle(min_interval = 2)
#'
#' # A budget of 10 requests per 60 seconds per host (evenly paced).
#' request_throttle(requests = 10, window = 60)
#' @keywords internal
#' @noRd
request_throttle <- function(min_interval = NULL, requests = NULL,
                             window = NULL) {
  interval <- request_throttle_interval(min_interval, requests, window)
  structure(
    list(min_interval = interval),
    class = "sitemapr_request_throttle"
  )
}

# Resolve the effective per-host minimum interval (seconds). A request budget
# (`requests` per `window`) wins when supplied; else `min_interval` is used.
# Exactly one form must be given, each value a single positive number.
request_throttle_interval <- function(min_interval, requests, window) {
  if (!is.null(requests) || !is.null(window)) {
    req <- request_throttle_positive(requests, "requests")
    win <- request_throttle_positive(window, "window")
    return(win / req)
  }
  request_throttle_positive(min_interval, "min_interval")
}

request_throttle_positive <- function(value, name) {
  ok <- is.numeric(value) && length(value) == 1L && isTRUE(value > 0)
  if (!ok) {
    request_policy_reject(
      sprintf("`%s` must be a single positive number.", name)
    )
  }
  as.numeric(value)
}

# Exponential backoff for retry attempt `i` (1-based), clamped to the policy's
# [backoff_min, backoff_max] window so a runaway multiplier can never sleep past
# the configured ceiling. Deterministic given `i`, so it is unit-testable.
retry_backoff_seconds <- function(i, backoff_min, backoff_max) {
  base <- backoff_min * 2^max(0L, as.integer(i) - 1L)
  min(backoff_max, max(backoff_min, base))
}

# Honor a response's `Retry-After`, but BOUND it by `backoff_max` so a hostile
# or misconfigured server cannot force an unbounded sleep. Returns `NA_real_`
# when the header is absent or non-numeric (e.g. an HTTP-date form), which tells
# httr2 to fall back to `retry_backoff_seconds()` — itself bounded.
retry_after_bounded <- function(resp, backoff_max) {
  if (!httr2::resp_header_exists(resp, "Retry-After")) {
    return(NA_real_)
  }
  after <- suppressWarnings(as.numeric(httr2::resp_header(resp, "Retry-After")))
  if (is.na(after)) {
    return(NA_real_)
  }
  min(after, backoff_max)
}

# ---- host-aware request throttling -------------------------------------------

# Build the mutable per-host throttle state for one logical operation, or NULL
# when the policy configures no throttle (the byte-identical default). The state
# is an environment holding the effective per-host `min_interval`, a
# host:port -> next-allowed-epoch map, and the injectable clock (`now`) and
# `sleep` seams. Production defaults are Sys.time / Sys.sleep; tests supply a
# virtual clock so the suite paces deterministically and never sleeps on the
# real wall clock (httr2::req_throttle is deliberately NOT used, since it does).
throttle_state_new <- function(throttle, now = Sys.time, sleep = Sys.sleep) {
  if (is.null(throttle)) {
    return(NULL)
  }
  state <- new.env(parent = emptyenv())
  state$min_interval <- throttle$min_interval
  state$next_allowed <- list()
  state$now <- now
  state$sleep <- sleep
  state
}

# The number of un-paced ("free") requests a single per-operation throttle
# store grants before pacing engages: exactly one -- the operation's very first
# request to a host. ADR-008 §6 unifies the per-host throttle into ONE store
# threaded through discovery and every index expansion of one operation, so an
# operation gets ONE free request, not one per phase. Surfaces that store-level
# invariant for the bounded-concurrency contract. A NULL (throttle-off) state
# grants none.
operation_free_requests <- function(state) {
  if (is.null(state)) {
    return(0L)
  }
  1L
}

# The throttle bucket key for a URL: its canonical host with an explicit,
# non-default port. Reuses the shared URL parse so the key matches the identity
# key's host/port canonicalization; the scheme's default port (`:80`/`:443`)
# collapses to no port, so `https://h:443/` and `https://h/` share one bucket.
throttle_host_key <- function(url) {
  parsed <- parse_url_adapter(url)
  host <- tolower(as.character(parsed$host)[[1L]])
  scheme <- as.character(parsed$scheme)[[1L]]
  port <- parsed$port[[1L]]
  defaults <- c(http = 80L, https = 443L)
  if (is.na(port) || isTRUE(port == defaults[scheme])) {
    return(host)
  }
  paste0(host, ":", port)
}

# Pace one request to `url`'s host bucket. If that host's next-allowed time is
# ahead of now, sleep until then (via the injected `sleep`), then reserve the
# slot `min_interval` seconds out. Buckets are independent per host, so distinct
# origins never pace against each other and a redirect to another host waits on
# its OWN bucket. A NULL state is a no-op (throttle unset -> byte-identical).
throttle_before_request <- function(state, url) {
  if (is.null(state)) {
    return(invisible())
  }
  key <- throttle_host_key(url)
  cur <- as.numeric(state$now())
  earliest <- state$next_allowed[[key]]
  if (!is.null(earliest) && earliest > cur) {
    state$sleep(earliest - cur)
    cur <- earliest
  }
  state$next_allowed[[key]] <- cur + state$min_interval
  invisible()
}

# Apply a policy's TYPED fields (headers, auth, proxy, tls) to one hop's
# request. Runs before the generic `prepare` hook and before sitemapr's own
# transport controls, so callers shape the request without weakening safety.
# A field left NULL is a no-op, so the default policy touches nothing.
request_policy_apply <- function(policy, req) {
  if (!is.null(policy$headers)) {
    req <- do.call(httr2::req_headers, c(list(req), policy$headers))
  }
  if (!is.null(policy$auth)) {
    req <- request_apply_auth(req, policy$auth)
  }
  if (!is.null(policy$proxy)) {
    req <- request_apply_proxy(req, policy$proxy)
  }
  if (!is.null(policy$tls)) {
    req <- do.call(httr2::req_options, c(list(req), policy$tls))
  }
  if (!is.null(policy$retry)) {
    req <- request_apply_retry(req, policy$retry)
  }
  req
}

# Attach the retry-and-backoff policy to one hop's request via httr2::req_retry.
# `is_transient` inspects the RESPONSE STATUS, which works even though the
# fetcher sets req_error(is_error = FALSE): httr2's retry loop evaluates
# is_transient on the raw response before the error policy runs, so a retryable
# non-2xx status still drives a retry. Retries live inside this single hop's
# req_perform(), so they never touch fetch_follow()'s redirect/hop accounting.
request_apply_retry <- function(req, retry) {
  statuses <- retry$statuses
  backoff_min <- retry$backoff_min
  backoff_max <- retry$backoff_max
  httr2::req_retry(
    req,
    max_tries = retry$max_tries,
    retry_on_failure = retry$retry_on_failure,
    is_transient = function(resp) httr2::resp_status(resp) %in% statuses,
    backoff = function(i) retry_backoff_seconds(i, backoff_min, backoff_max),
    after = function(resp) retry_after_bounded(resp, backoff_max)
  )
}

request_apply_auth <- function(req, auth) {
  if (identical(auth$scheme, "bearer")) {
    return(httr2::req_auth_bearer_token(req, auth$token))
  }
  httr2::req_auth_basic(req, auth$username, auth$password)
}

request_apply_proxy <- function(req, proxy) {
  httr2::req_proxy(
    req,
    url = proxy$url,
    port = proxy$port,
    username = proxy$username,
    password = proxy$password,
    auth = proxy$auth
  )
}

# Apply a request-policy's preparation hook to one hop's request. A NULL hook is
# the no-op identity. The hook MUST return an httr2 request; any other return is
# rejected with `sitemapr_invalid_request_policy` so a misbehaving hook cannot
# smuggle an arbitrary object into req_perform().
#
# @keywords internal
# @noRd
request_policy_prepare <- function(policy, req, url) {
  if (!inherits(policy, "sitemapr_request_policy")) {
    rlang::abort(
      "`policy` must be a sitemapr_request_policy (see request_policy()).",
      class = "sitemapr_invalid_request_policy"
    )
  }
  if (is.null(policy$prepare)) {
    return(req)
  }
  out <- policy$prepare(req, list(url = url))
  if (!inherits(out, "httr2_request")) {
    rlang::abort(
      "The request-policy `prepare` hook must return an httr2 request.",
      class = "sitemapr_invalid_request_policy"
    )
  }
  out
}

# ---- single bounded request --------------------------------------------------

# Build and perform ONE request (no redirect following) for `url`, returning the
# raw httr2 response. Auto-redirect is disabled so the caller drives the loop
# and re-runs the SSRF guard on each hop. Non-2xx codes are NOT promoted to
# errors
# here; transport failures still throw. The `policy` preparation hook runs
# between the base request and sitemapr's own transport controls: the timeout,
# redirect ownership, and error policy are (re-)asserted AFTER the hook, so a
# policy can add headers but cannot override those safety semantics.
fetch_perform_one <- function(url, limits, user_agent,
                              policy = request_policy(),
                              throttle_state = NULL) {
  req <- httr2::request(url)
  req <- httr2::req_user_agent(req, user_agent)
  # Caller-supplied customization (after the SSRF guard, before our own
  # transport controls): typed fields first, then the generic prepare hook.
  # No-ops for the default policy.
  req <- request_policy_apply(policy, req)
  req <- request_policy_prepare(policy, req, url)
  req <- httr2::req_timeout(req, limits$timeout)
  # sitemapr always owns redirect control: re-assert AFTER all caller
  # customization so headers/auth/proxy/tls/prepare cannot re-enable httr2's
  # own redirect following. We follow manually, per hop, re-running the SSRF
  # guard on each Location.
  req <- httr2::req_options(req, followlocation = 0L, maxredirs = 0L)
  # Let the caller decide what a non-2xx status means; do not abort on it here.
  req <- httr2::req_error(req, is_error = function(resp) FALSE)
  # Pace this hop against its host bucket (after the SSRF guard ran in the
  # caller and after our transport controls above); a NULL state is a no-op.
  throttle_before_request(throttle_state, url)
  httr2::req_perform(req)
}

fetch_source_input <- function(url, scheme_inferred) {
  if (!(is.data.frame(url) || is.list(url))) {
    return(list(
      url = as.character(url)[[1L]],
      scheme_inferred = scheme_inferred
    ))
  }

  rec <- url
  if (!is.null(rec$normalized_url)) {
    url_str <- as.character(rec$normalized_url)[[1L]]
  } else {
    url_str <- as.character(rec$url)[[1L]]
  }
  if (!is.null(rec$scheme_inferred)) {
    scheme_inferred <- isTRUE(as.logical(rec$scheme_inferred)[[1L]])
  }
  list(url = url_str, scheme_inferred = scheme_inferred)
}

fetch_connection_failure <- function(
  cnd,
  url_str,
  scheme_inferred,
  limits,
  user_agent,
  ssrf_guard,
  policy = request_policy(),
  throttle_state = NULL
) {
  if (isTRUE(scheme_inferred) && startsWith(tolower(url_str), "https://")) {
    http_url <- sub("^https://", "http://", url_str, ignore.case = TRUE)
    return(fetch_follow(
      url = http_url,
      limits = limits,
      user_agent = user_agent,
      ssrf_guard = ssrf_guard,
      policy = policy,
      throttle_state = throttle_state
    ))
  }
  if (fetch_is_timeout(cnd)) {
    rlang::abort(
      sprintf(
        "Request to %s timed out after %s s.",
        url_str,
        format(limits$timeout)
      ),
      class = "sitemapr_timeout",
      url = url_str,
      timeout = limits$timeout,
      parent = cnd
    )
  }
  rlang::abort(
    sprintf("Request to %s failed at the connection level.", url_str),
    class = "sitemapr_timeout",
    url = url_str,
    timeout = limits$timeout,
    parent = cnd
  )
}

#' Fetch one source with bounded, SSRF-safe HTTP
#'
#' Performs a single bounded HTTP fetch for one source and returns a one-row
#' fetch-metadata record (the 13-column contract from `source_metadata()`).
#' Redirects are followed manually up to `limits$max_redirects`, with the
#' structural SSRF guard re-run on every hop before any network call. The body
#' is capped at the per-resource safety ceiling (`limits$max_bytes`); an
#' over-ceiling body is discarded unparsed and raises `sitemapr_body_ceiling`.
#' The 50 MB sitemap-protocol limit is not enforced here — it is a downstream
#' validation finding; this record only carries the body size in `bytes`.
#'
#' @param url The source URL to fetch (length-1 character). May also be supplied
#'   as a one-row source record carrying `normalized_url`/`url` plus a
#'   `scheme_inferred` logical column; the record form is detected
#'   automatically.
#' @param scheme_inferred Logical; `TRUE` when the scheme was inferred (a bare
#'   host upgraded to `https://`). Only an inferred-https request may fall back
#'   to http on a connection failure. Ignored when `url` is a record carrying
#'   its own `scheme_inferred`.
#' @param limits Network limits, as from `fetch_limits()`.
#' @param user_agent User-Agent header string; defaults to
#'   `default_user_agent()`.
#' @param ssrf_guard Logical; when `TRUE` (default) the structural SSRF guard
#'   runs on every hop. When `FALSE` the guard is skipped entirely.
#' @param policy A `request_policy()` object whose preparation hook is applied
#'   to every hop's request, after the SSRF guard and before sitemapr's own
#'   transport controls. Defaults to the no-op policy.
#' @param throttle_state Internal per-host throttle state (an environment from
#'   `throttle_state_new()`) shared across the requests of one operation.
#'   `NULL` (the default) builds a fresh state from `policy$throttle`, so a
#'   single fetch and its redirect hops share one set of host buckets. Callers
#'   pacing many fetches together (index traversal, discovery) build the state
#'   once and pass it in so every fetch shares it.
#' @return A one-row data.frame from `source_metadata()`. The raw response body
#'   is attached as a `"body"` attribute (a raw vector; off the 13-column
#'   contract) so the parse entry point can dispatch on it without re-fetching.
#' @keywords internal
#' @noRd
fetch_source <- function(
  url,
  scheme_inferred = FALSE,
  limits = fetch_limits(),
  user_agent = default_user_agent(),
  ssrf_guard = TRUE,
  policy = request_policy(),
  throttle_state = NULL
) {
  input <- fetch_source_input(url, scheme_inferred)
  url_str <- input$url
  scheme_inferred <- input$scheme_inferred
  requested_url <- url_str
  # A fresh state (from policy$throttle) when none is threaded in, so a single
  # fetch and its redirect hops share one set of host buckets. NULL throttle
  # yields a NULL state, so the default path paces nothing (byte-identical).
  if (is.null(throttle_state)) {
    throttle_state <- throttle_state_new(policy$throttle)
  }

  result <- tryCatch(
    fetch_follow(
      url = url_str,
      limits = limits,
      user_agent = user_agent,
      ssrf_guard = ssrf_guard,
      policy = policy,
      throttle_state = throttle_state
    ),
    httr2_failure = function(cnd) {
      fetch_connection_failure(
        cnd, url_str, scheme_inferred, limits, user_agent, ssrf_guard, policy,
        throttle_state
      )
    }
  )

  body <- attr(result, "body")
  result$requested_url <- requested_url
  attr(result, "body") <- body
  result
}

# Run the per-hop structural SSRF guard for `url` before any network call.
# Aborts with `sitemapr_ssrf_blocked` when the guard rejects the host; returns
# invisibly when the host is allowed or when guarding is disabled. ADR-003: this
# MUST run before every hop's request, so a redirect cannot bypass the guard.
fetch_hop_ssrf_guard <- function(url, ssrf_guard) {
  if (!isTRUE(ssrf_guard)) {
    return(invisible())
  }
  check <- ssrf_check_parsed(parse_url_adapter(url))
  if (isTRUE(check$allowed)) {
    return(invisible())
  }
  rlang::abort(
    sprintf("SSRF guard blocked %s (%s).", url, check$reason),
    class = "sitemapr_ssrf_blocked",
    reason = check$reason,
    url = url
  )
}

# The redirect target for a response, or NA_character_ when `resp` is not a
# follow-able redirect (status outside 3xx, or no Location header). A Location
# is resolved relative to `base`. A 3xx without Location therefore reads as
# terminal (handled as a non-2xx response), exactly as before.
fetch_redirect_target <- function(resp, base) {
  status <- httr2::resp_status(resp)
  if (status < 300L || status >= 400L) {
    return(NA_character_)
  }
  if (!httr2::resp_header_exists(resp, "Location")) {
    return(NA_character_)
  }
  location <- httr2::resp_header(resp, "Location")
  httr2::url_modify_relative(base, location)
}

# Build the terminal one-row source_metadata() record from a final response. A
# non-2xx status additionally raises a `sitemapr_http_error` warning (the record
# still carries the status and error_class). The ceiling-capped raw `body` rides
# along as a "body" attribute (off the 13-column contract) so the parse entry
# point (R/read-sitemap.R) can dispatch without a second fetch. An empty body on
# a 2xx response still sniffs (to "empty"); on a non-2xx it stays NA.
fetch_terminal_record <- function(resp, url, redirect_chain, body, elapsed) {
  status <- httr2::resp_status(resp)
  final_url <- httr2::resp_url(resp)
  content_type <- tryCatch(
    httr2::resp_content_type(resp),
    error = function(e) NA_character_
  )
  charset <- tryCatch(
    httr2::resp_encoding(resp),
    error = function(e) NA_character_
  )
  is_2xx <- status >= 200L && status < 300L
  error_class <- if (is_2xx) NA_character_ else "sitemapr_http_error"
  if (!is_2xx) {
    rlang::warn(
      sprintf("HTTP %d while fetching %s.", status, final_url),
      class = "sitemapr_http_error",
      status = status,
      url = final_url,
      error_class = error_class
    )
  }
  rec <- source_metadata(
    requested_url = url,
    final_url = final_url,
    status = status,
    redirect_chain = c(redirect_chain, final_url),
    content_type = content_type,
    charset = charset,
    bytes = length(body),
    timing = elapsed,
    error_class = error_class,
    format = if (is_2xx || length(body) > 0L) {
      sniff_format(body)
    } else {
      NA_character_
    }
  )
  attr(rec, "body") <- body
  rec
}

# Manual redirect loop with per-hop SSRF re-check and the safety-ceiling cap.
# Returns a one-row source_metadata() record. SSRF / redirect-limit / ceiling
# all surface as classed aborts; transport failures propagate to the caller
# (`fetch_source`) for the https->http fallback decision. Ordering is load-
# bearing (ADR-003): guard -> perform -> follow, on every hop.
fetch_follow <- function(
  url,
  limits,
  user_agent,
  ssrf_guard,
  policy = request_policy(),
  throttle_state = NULL
) {
  start <- Sys.time()
  current_url <- url
  redirect_chain <- character(0)
  hops <- 0L

  repeat {
    # 1. Per-hop SSRF guard BEFORE any network activity for this hop.
    fetch_hop_ssrf_guard(current_url, ssrf_guard)

    # 2. Perform one request (no auto-redirect); the policy hook prepares it
    #    AFTER the guard above and BEFORE req_perform() inside the helper.
    resp <- fetch_perform_one(
      current_url, limits, user_agent, policy, throttle_state
    )

    # 3. Redirect? Resolve Location, bound the hop count, loop.
    next_url <- fetch_redirect_target(resp, current_url)
    if (!is.na(next_url)) {
      hops <- hops + 1L
      if (hops > limits$max_redirects) {
        rlang::abort(
          sprintf(
            "Exceeded the redirect limit of %d while fetching %s.",
            limits$max_redirects,
            url
          ),
          class = "sitemapr_redirect_limit",
          url = url,
          max_redirects = limits$max_redirects,
          redirect_chain = c(redirect_chain, next_url)
        )
      }
      redirect_chain <- c(redirect_chain, current_url)
      current_url <- next_url
      next
    }

    # 4. Terminal response. Read the buffered body under the safety ceiling,
    #    then assemble the record (a non-2xx status warns inside the helper).
    body <- if (httr2::resp_has_body(resp)) {
      read_capped_body(httr2::resp_body_raw(resp), limits$max_bytes)
    } else {
      raw()
    }
    elapsed <- as.numeric(difftime(Sys.time(), start, units = "secs"))
    return(fetch_terminal_record(resp, url, redirect_chain, body, elapsed))
  }
}
