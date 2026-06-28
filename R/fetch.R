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
  total <- 0
  acc <- list()

  consume <- function(chunk) {
    if (length(chunk) == 0L) {
      return(invisible())
    }
    total <<- total + length(chunk)
    if (total > max_bytes) {
      # Discard everything read so far; an over-ceiling body is never returned.
      acc <<- list()
      rlang::abort(
        sprintf(
          "Body exceeded the %.0f-byte per-resource safety ceiling; discarded.",
          max_bytes
        ),
        class = "sitemapr_body_ceiling",
        max_bytes = max_bytes,
        bytes_read = total
      )
    }
    acc[[length(acc) + 1L]] <<- chunk
    invisible()
  }

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

  if (length(acc) == 0L) {
    return(raw())
  }
  do.call(c, acc)
}

# ---- condition / error classification helpers --------------------------------

# A connection-level failure (DNS, refused, reset, TLS, timeout) surfaces from
# httr2 as `httr2_failure` (real curl errors) and/or `httr2_timeout`.
fetch_is_transport_failure <- function(cnd) {
  inherits(cnd, "httr2_failure") || inherits(cnd, "httr2_timeout")
}

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

# ---- single bounded request --------------------------------------------------

# Build and perform ONE request (no redirect following) for `url`, returning the
# raw httr2 response. Auto-redirect is disabled so the caller drives the loop
# and re-runs the SSRF guard on each hop. Non-2xx codes are NOT promoted to
# errors
# here; transport failures still throw.
fetch_perform_one <- function(url, limits, user_agent) {
  req <- httr2::request(url)
  req <- httr2::req_user_agent(req, user_agent)
  req <- httr2::req_timeout(req, limits$timeout)
  # Disable httr2's own redirect following: we follow manually, per hop.
  req <- httr2::req_options(req, followlocation = 0L, maxredirs = 0L)
  # Let the caller decide what a non-2xx status means; do not abort on it here.
  req <- httr2::req_error(req, is_error = function(resp) FALSE)
  httr2::req_perform(req)
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
#' @return A one-row data.frame from `source_metadata()`.
#' @keywords internal
#' @noRd
fetch_source <- function(url,
                         scheme_inferred = FALSE,
                         limits = fetch_limits(),
                         user_agent = default_user_agent(),
                         ssrf_guard = TRUE) {
  # Accept either a bare URL string or a one-row source record.
  if (is.data.frame(url) || is.list(url)) {
    rec <- url
    if (!is.null(rec$normalized_url)) {
      url_str <- as.character(rec$normalized_url)[[1L]]
    } else {
      url_str <- as.character(rec$url)[[1L]]
    }
    if (!is.null(rec$scheme_inferred)) {
      scheme_inferred <- isTRUE(as.logical(rec$scheme_inferred)[[1L]])
    }
  } else {
    url_str <- as.character(url)[[1L]]
  }

  requested_url <- url_str

  result <- tryCatch(
    fetch_follow(
      url = url_str,
      limits = limits,
      user_agent = user_agent,
      ssrf_guard = ssrf_guard
    ),
    httr2_failure = function(cnd) {
      # Connection-level failure. https->http fallback only when the scheme was
      # inferred (never downgrade an explicit https). Otherwise re-raise as a
      # timeout/transport abort.
      if (isTRUE(scheme_inferred) && startsWith(tolower(url_str), "https://")) {
        http_url <- sub("^https://", "http://", url_str, ignore.case = TRUE)
        return(fetch_follow(
          url = http_url,
          limits = limits,
          user_agent = user_agent,
          ssrf_guard = ssrf_guard
        ))
      }
      if (fetch_is_timeout(cnd)) {
        rlang::abort(
          sprintf("Request to %s timed out after %s s.", url_str,
                  format(limits$timeout)),
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
  )

  result$requested_url <- requested_url
  result
}

# Manual redirect loop with per-hop SSRF re-check and the safety-ceiling cap.
# Returns a one-row source_metadata() record. SSRF / redirect-limit / ceiling
# all surface as classed aborts; transport failures propagate to the caller
# (`fetch_source`) for the https->http fallback decision.
fetch_follow <- function(url, limits, user_agent, ssrf_guard) {
  start <- Sys.time()
  current_url <- url
  redirect_chain <- character(0)
  hops <- 0L

  repeat {
    # 1. Per-hop SSRF guard BEFORE any network activity for this hop.
    if (isTRUE(ssrf_guard)) {
      parsed <- parse_url_adapter(current_url)
      check <- ssrf_check_parsed(parsed)
      if (!isTRUE(check$allowed)) {
        rlang::abort(
          sprintf(
            "SSRF guard blocked %s (%s).", current_url, check$reason
          ),
          class = "sitemapr_ssrf_blocked",
          reason = check$reason,
          url = current_url
        )
      }
    }

    # 2. Perform one request (no auto-redirect).
    resp <- fetch_perform_one(current_url, limits, user_agent)
    status <- httr2::resp_status(resp)

    # 3. Redirect? Resolve Location, bound the hop count, loop.
    if (status >= 300L && status < 400L &&
          httr2::resp_header_exists(resp, "Location")) {
      location <- httr2::resp_header(resp, "Location")
      next_url <- httr2::url_modify_relative(current_url, location)
      hops <- hops + 1L
      if (hops > limits$max_redirects) {
        rlang::abort(
          sprintf(
            "Exceeded the redirect limit of %d while fetching %s.",
            limits$max_redirects, url
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

    # 4. Terminal response. Read the buffered body under the safety ceiling.
    final_url <- httr2::resp_url(resp)
    body <- if (httr2::resp_has_body(resp)) {
      read_capped_body(httr2::resp_body_raw(resp), limits$max_bytes)
    } else {
      raw()
    }
    elapsed <- as.numeric(difftime(Sys.time(), start, units = "secs"))

    content_type <- tryCatch(
      httr2::resp_content_type(resp),
      error = function(e) NA_character_
    )
    charset <- tryCatch(
      httr2::resp_encoding(resp),
      error = function(e) NA_character_
    )

    # 5. Non-2xx terminal status -> warning condition, record carries the error.
    if (status < 200L || status >= 300L) {
      error_class <- "sitemapr_http_error"
      rlang::warn(
        sprintf("HTTP %d while fetching %s.", status, final_url),
        class = "sitemapr_http_error",
        status = status,
        url = final_url,
        error_class = error_class
      )
      return(source_metadata(
        requested_url = url,
        final_url = final_url,
        status = status,
        redirect_chain = c(redirect_chain, final_url),
        content_type = content_type,
        charset = charset,
        bytes = length(body),
        timing = elapsed,
        error_class = error_class,
        format = if (length(body) > 0L) sniff_format(body) else NA_character_
      ))
    }

    # 6. Success.
    return(source_metadata(
      requested_url = url,
      final_url = final_url,
      status = status,
      redirect_chain = c(redirect_chain, final_url),
      content_type = content_type,
      charset = charset,
      bytes = length(body),
      timing = elapsed,
      error_class = NA_character_,
      format = sniff_format(body)
    ))
  }
}
