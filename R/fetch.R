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

# Construct and validate a request-policy: a small object carrying an optional
# request-preparation hook applied to each hop's httr2 request. This is the one
# safe extension seam at the fetch boundary (headers/auth/proxies later); the
# DEFAULT is a no-op (identity) policy, so existing callers behave identically.
#
# `prepare`, when supplied, is a `function(req, ctx)` that receives the built
# httr2 request plus a hop-context list (currently the resolved hop `url`) and
# returns the possibly-modified request. It runs AFTER the per-hop SSRF guard
# and BEFORE sitemapr's own transport controls (timeout, redirect ownership,
# error policy) are asserted, so it can add headers but cannot weaken those
# safety semantics.
#
# Raises `sitemapr_invalid_request_policy` (abort) when `prepare` is neither
# NULL nor a function.
#
# @keywords internal
# @noRd
request_policy <- function(prepare = NULL) {
  if (!is.null(prepare) && !is.function(prepare)) {
    rlang::abort(
      "`prepare` must be NULL or a function(req, ctx) returning a request.",
      class = "sitemapr_invalid_request_policy"
    )
  }
  structure(list(prepare = prepare), class = "sitemapr_request_policy")
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
                              policy = request_policy()) {
  req <- httr2::request(url)
  req <- httr2::req_user_agent(req, user_agent)
  # Caller-supplied preparation hook (after the SSRF guard, before our own
  # transport controls). A no-op for the default policy.
  req <- request_policy_prepare(policy, req, url)
  req <- httr2::req_timeout(req, limits$timeout)
  # Disable httr2's own redirect following: we follow manually, per hop.
  req <- httr2::req_options(req, followlocation = 0L, maxredirs = 0L)
  # Let the caller decide what a non-2xx status means; do not abort on it here.
  req <- httr2::req_error(req, is_error = function(resp) FALSE)
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
  policy = request_policy()
) {
  if (isTRUE(scheme_inferred) && startsWith(tolower(url_str), "https://")) {
    http_url <- sub("^https://", "http://", url_str, ignore.case = TRUE)
    return(fetch_follow(
      url = http_url,
      limits = limits,
      user_agent = user_agent,
      ssrf_guard = ssrf_guard,
      policy = policy
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
  policy = request_policy()
) {
  input <- fetch_source_input(url, scheme_inferred)
  url_str <- input$url
  scheme_inferred <- input$scheme_inferred
  requested_url <- url_str

  result <- tryCatch(
    fetch_follow(
      url = url_str,
      limits = limits,
      user_agent = user_agent,
      ssrf_guard = ssrf_guard,
      policy = policy
    ),
    httr2_failure = function(cnd) {
      fetch_connection_failure(
        cnd, url_str, scheme_inferred, limits, user_agent, ssrf_guard, policy
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
  policy = request_policy()
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
    resp <- fetch_perform_one(current_url, limits, user_agent, policy)

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
