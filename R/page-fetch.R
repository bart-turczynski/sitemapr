# Engine-neutral page-fetch artifact + acquisition (Layer E, Contract A; E.1a).
#
# Internal only. This is PURE MECHANICS: fetching, safety, limits. No policy, no
# per-engine interpretation, no findings, no PAGE_* codes live here (those are
# E.1f / E.2-E.4). page_fetch() performs one LOGICAL fetch of an advertised page
# URL (possibly several HTTP hops) and returns a `page_fetch_artifact` capturing
# what an inspector saw: the redirect chain, the terminal headers (repeated
# fields intact), a capped body prefix, and an ADR-009 evidence_status outcome.
#
# Governing contracts (conform, do not restate):
#   docs/design/layer-e-page-inspection.md  §3.1 (artifact), §3.2 (precedence)
#   docs/decisions/ADR-010-page-inspection.md  §2/§3 (partial = truncate-and-
#     retain; safety vs resource split)
#   docs/decisions/ADR-009-*.md  §2 (the evidence_status enum)
#   docs/decisions/ADR-003-*.md  §1/§3 (SSRF guard, 500 MB per-resource ceiling)
#
# Reuses (does NOT reimplement) the ADR-003 machinery in R/fetch.R via the
# additive page_fetch_follow() capture loop: the per-hop SSRF guard, redirect
# revalidation, and the 500 MB per-resource discard ceiling all apply unchanged.
# fetch_source()'s 13-column contract is FROZEN and untouched — page inspection
# is a separate artifact, never a new source_metadata() column.

# The ADR-009 §2 evidence_status enum, as reused for a page-fetch outcome. The
# full value set is versioned and ADR-009-owned; this is the exact membership an
# E.1a outcome may take.
page_evidence_status_values <- function() {
  c(
    "usable_body",
    "partial",
    "incomplete",
    "http_status",
    "http_protocol_error",
    "redirect_over_budget",
    "transport_fail",
    "safety_refused",
    "not_applicable"
  )
}

# The default per-page truncate-and-retain body cap: 1 MB. A safe single-MB
# value far below ADR-003's 500 MB per-resource ceiling — the head region is all
# an inspector needs. Caller-overridable via page_fetch(page_body_cap = ).
page_body_cap_default <- function() {
  1024L * 1024L
}

#' Construct an engine-neutral page-fetch artifact
#'
#' Internal constructor for the Contract A artifact (governing spec §3.1). It
#' only assembles and shape-checks the record; classification lives in
#' page_fetch(). No field carries a policy, a severity, or an engine name.
#'
#' @param requested_url The URL the fetch was asked to retrieve (length-1).
#' @param final_url The terminal response URL, or NA when no terminal response
#'   was reached (safety refusal, redirect over budget, transport failure).
#' @param hops An ordered list, one record per performed HTTP request, each a
#'   `list(url, status, location)` from page_hop_record(); `location` is the
#'   resolved redirect target (NA on a terminal response). Represents the
#'   redirect CHAIN, not a counter.
#' @param terminal_headers The terminal response's headers with REPEATED field
#'   values preserved (multiple X-Robots-Tag / Link lines all survive); an
#'   empty list when no terminal response was reached.
#' @param body The retained body PREFIX (a raw vector), capped at the per-page
#'   body cap; raw(0) when there is no usable body.
#' @param truncated Logical; TRUE when the body was cut at the per-page cap
#'   (truncate-and-retain) and the retained prefix is a usable head region.
#' @param outcome An ADR-009 §2 evidence_status value (see
#'   page_evidence_status_values()).
#' @param request_user_agent The HTTP User-Agent header actually sent (distinct
#'   from any engine product token; ADR-009 §1).
#' @return An object of class `page_fetch_artifact` (a named list).
#' @keywords internal
#' @noRd
page_fetch_artifact <- function(
  requested_url,
  final_url = NA_character_,
  hops = list(),
  terminal_headers = list(),
  body = raw(),
  truncated = FALSE,
  outcome,
  request_user_agent
) {
  outcome <- match.arg(outcome, page_evidence_status_values())
  structure(
    list(
      requested_url = as.character(requested_url)[[1L]],
      final_url = as.character(final_url)[[1L]],
      hops = hops,
      terminal_headers = terminal_headers,
      body = if (is.raw(body)) body else raw(),
      truncated = isTRUE(truncated),
      outcome = outcome,
      request_user_agent = as.character(request_user_agent)[[1L]]
    ),
    class = "page_fetch_artifact"
  )
}

# Map a terminal HTTP status (and whether the body was truncated) to an
# evidence_status. A 2xx yields `partial` when the body was cut at the per-page
# cap (head-region facts usable), else `usable_body`. Any terminal non-2xx —
# including a 3xx with no resolvable Location, which fetch_redirect_target()
# reports as terminal — is `http_status`.
page_outcome_for_status <- function(status, truncated) {
  if (status >= 200L && status < 300L) {
    return(if (isTRUE(truncated)) "partial" else "usable_body")
  }
  "http_status"
}

# Normalize page_fetch()'s `url` input to a single request string, or NA when
# there is nothing fetchable. Mirrors fetch_source_input()'s record handling so
# a one-row source record (normalized_url / url) works here too.
page_fetch_requested_url <- function(url) {
  if (is.data.frame(url) || is.list(url)) {
    field <- if (!is.null(url$normalized_url)) url$normalized_url else url$url
    value <- as.character(field)[[1L]]
  } else {
    value <- as.character(url)[[1L]]
  }
  if (length(value) == 0L || is.na(value) || !nzchar(value)) {
    return(NA_character_)
  }
  value
}

#' Acquire an engine-neutral page-fetch artifact for one advertised URL
#'
#' Performs one logical fetch (possibly several HTTP hops) of a page URL and
#' returns a `page_fetch_artifact` (governing spec §3.1). Reuses the ADR-003
#' SSRF-guarded fetch/redirect machinery unchanged; adds the per-page
#' truncate-and-retain body cap (ADR-010 §2) on top of the 500 MB per-resource
#' ceiling. Classification of the outcome follows §3.2 + ADR-010:
#'   * SSRF block / non-HTTP(S) scheme / a redirect hop stepping https->http
#'     -> `safety_refused` (never a page verdict);
#'   * per-page body cap reached -> `partial`, prefix RETAINED, `truncated`;
#'   * 500 MB ceiling discard OR deadline/transport with no body -> `incomplete`
#'     / `transport_fail` (no usable body);
#'   * 2xx full body -> `usable_body`; terminal 4xx/5xx or unresolvable 3xx ->
#'     `http_status`; redirect cap exceeded -> `redirect_over_budget`.
#' Emits NO findings and adds NO PAGE_* codes — that mapping is E.1f's.
#'
#' @param url The page URL to fetch (length-1 character, or a one-row source
#'   record carrying `normalized_url`/`url`).
#' @param page_body_cap Per-page truncate-and-retain body cap in bytes; default
#'   1 MB (page_body_cap_default()), caller-overridable.
#' @param limits Network limits from fetch_limits() (timeout, max_redirects, and
#'   the 500 MB per-resource ceiling `max_bytes`).
#' @param user_agent The HTTP User-Agent header to send; recorded on the
#'   artifact as `request_user_agent`. Defaults to the sitemapr inspector UA.
#' @param ssrf_guard Logical; when TRUE (default) the structural SSRF guard runs
#'   on every hop, exactly as for fetch_source().
#' @param policy A request_policy() applied to every hop (after the SSRF guard,
#'   before sitemapr's transport controls). Defaults to the no-op policy.
#' @param throttle_state Internal per-host throttle state shared across an
#'   operation's requests; NULL builds a fresh one from `policy$throttle`.
#' @return A `page_fetch_artifact`.
#' @keywords internal
#' @noRd
page_fetch <- function(
  url,
  page_body_cap = page_body_cap_default(),
  limits = fetch_limits(),
  user_agent = default_user_agent(),
  ssrf_guard = TRUE,
  policy = request_policy(),
  throttle_state = NULL
) {
  requested <- page_fetch_requested_url(url)
  if (is.na(requested)) {
    return(page_fetch_artifact(
      requested_url = NA_character_,
      outcome = "not_applicable",
      request_user_agent = user_agent
    ))
  }
  if (is.null(throttle_state)) {
    throttle_state <- throttle_state_new(policy$throttle)
  }
  capture <- new.env(parent = emptyenv())
  capture$hops <- list()

  terminal <- tryCatch(
    page_fetch_follow(
      url = requested,
      limits = limits,
      user_agent = user_agent,
      ssrf_guard = ssrf_guard,
      page_body_cap = page_body_cap,
      capture = capture,
      policy = policy,
      throttle_state = throttle_state
    ),
    sitemapr_ssrf_blocked = function(cnd) list(outcome = "safety_refused"),
    sitemapr_scheme_downgrade = function(cnd) {
      list(outcome = "safety_refused")
    },
    sitemapr_redirect_limit = function(cnd) {
      list(outcome = "redirect_over_budget")
    },
    sitemapr_body_ceiling = function(cnd) list(outcome = "incomplete"),
    sitemapr_timeout = function(cnd) list(outcome = "transport_fail"),
    httr2_failure = function(cnd) list(outcome = "transport_fail")
  )

  page_fetch_assemble(requested, terminal, capture$hops, user_agent)
}

# Assemble the artifact from the loop's terminal facts (or a failure handler's
# bare `outcome`) plus the accumulated hops. On the success path `terminal`
# carries status/final_url/headers/body/truncated and the outcome is derived
# from the status; on a failure path only `outcome` is set and the remaining
# fields fall back to their no-terminal-response defaults.
page_fetch_assemble <- function(requested, terminal, hops, user_agent) {
  if (is.null(terminal$status)) {
    return(page_fetch_artifact(
      requested_url = requested,
      hops = hops,
      outcome = terminal$outcome,
      request_user_agent = user_agent
    ))
  }
  page_fetch_artifact(
    requested_url = requested,
    final_url = terminal$final_url,
    hops = hops,
    terminal_headers = terminal$terminal_headers,
    body = terminal$body,
    truncated = terminal$truncated,
    outcome = page_outcome_for_status(terminal$status, terminal$truncated),
    request_user_agent = user_agent
  )
}

# All values of one terminal-header field, case-insensitively, in order — so a
# repeated field (multiple X-Robots-Tag / Link lines) yields every value, not
# just the first. Returns character(0) when the field is absent. Operates on the
# artifact's `terminal_headers` (or any named header list preserving repeats).
page_header_values <- function(headers, name) {
  if (length(headers) == 0L) {
    return(character(0))
  }
  hit <- tolower(names(headers)) == tolower(name)
  as.character(unlist(headers[hit], use.names = FALSE))
}
