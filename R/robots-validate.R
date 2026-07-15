# robots.txt allow/disallow finding-producer, Layer E check #7
# (SITE-ofdqaeju; architecture.md §3; docs/findings-contract.md "robots").
# Internal only.
#
# For each URL a sitemap advertises, this producer asks whether the governing
# robots.txt allows it and emits `layer = "robots"` findings for the URLs that
# are DISALLOWED (a well-known SEO defect: Search Console flags a sitemap that
# advertises a blocked URL) or that CANNOT be decided because robots.txt could
# not be fetched. Like the other producers it emits the 8-column contract subset
# (`code, severity, layer, subject_type, subject_ref, message, evidence,
# is_strict_only`) and leaves the `mode`/dedup/sort to Layer F.
#
# The engine is the sibling package `robotstxtr`, used WHOLESALE via
# `allowed_by_robots_url()`: it owns the faithful Google matcher AND the
# HTTP-status -> policy semantics (a 404/410 is allow-all, a 5xx/timeout/network
# failure or an SSRF block is indeterminate), and it fetches each distinct
# origin's robots.txt exactly once. sitemapr does NOT reimplement fetching or
# matching; it feeds `robotstxtr` the advertised URLs plus a matcher user-agent
# and turns `robots_decisions$results` into findings. The `ssrf_guard = TRUE`
# opt-out is left at its default so the robots.txt fetch honours the same
# SSRF posture as the rest of sitemapr (ADR-003; robotstxtr ROBO-quovenef).
#
# `robotstxtr` is an OPTIONAL dependency (DESCRIPTION Suggests). Availability is
# resolved once by the caller (R/validate-sitemap.R): this producer is only ever
# reached when the package is present, so it may reference `robotstxtr::`
# directly. Absence is surfaced by the caller as a classed condition naming the
# install command, never as a findings row (the findings table describes the
# sitemap, not the user's setup).

# Construct the robots-layer findings tibble (the contract-shaped 8-column
# subset every producer emits, with `layer = "robots"`). The single place the
# robots producer's column shape is defined.
robots_findings <- function(
  code = character(0),
  severity = character(0),
  subject_ref = character(0),
  message = character(0),
  evidence = list(),
  is_strict_only = logical(0)
) {
  n <- length(code)
  tibble::tibble(
    code = as.character(code),
    severity = as.character(severity),
    layer = rep("robots", n),
    subject_type = rep("page-url", n),
    subject_ref = as.character(subject_ref),
    message = as.character(message),
    evidence = if (length(evidence) > 0L) evidence else vector("list", n),
    is_strict_only = as.logical(is_strict_only)
  )
}

# A zero-row robots-findings tibble (every advertised URL is allowed, or there
# is nothing testable to check).
empty_robots_findings <- function() {
  robots_findings()
}

# Is `robotstxtr` installed? Wrapped in a named function so tests can stub the
# optional-dependency guard without touching the real package state.
robotstxtr_available <- function() {
  requireNamespace("robotstxtr", quietly = TRUE)
}

# The install command named in the optional-dependency guard message.
robotstxtr_install_hint <- function() {
  "pak::pak('bart-turczynski/robotstxtr')"
}

# Only absolute http(s) URLs are robots-testable: a relative or non-http `<loc>`
# is not something a crawler fetches, and feeding it to the matcher would only
# echo the malformed-loc problems the protocol layer already reports. The
# absoluteness classifier is shared with the protocol producer.
robots_testable_locs <- function(locs) {
  locs <- as.character(locs)
  locs <- locs[!is.na(locs) & nzchar(locs)]
  unique(locs[loc_absoluteness(locs) == "http(s)"])
}

# The page-url subject_ref for a robots finding: the advertising sitemap's base
# with a `#page-url:<loc>` fragment (findings-contract.md "Subject ref format").
# `base` is the sitemap that listed the URL, so the finding stays anchored to
# the document that advertised the blocked page.
robots_subject_ref <- function(base, loc) {
  protocol_ref_fragment(base, paste0("#page-url:", loc))
}

# One ROBOTS_DISALLOWED finding for a disallowed URL. Evidence carries the
# matcher's matched robots.txt rule: the `type: value` snippet in `excerpt`
# (e.g. `disallow: /private`) and the one-based `matched_line` in `line`.
robots_disallowed_finding <- function(base, loc, res_row) {
  robots_findings(
    code = "ROBOTS_DISALLOWED",
    severity = "warning",
    subject_ref = robots_subject_ref(base, loc),
    message = sprintf(
      "Sitemap-listed URL %s is disallowed by robots.txt (matched %s '%s').",
      loc,
      res_row$matched_rule_type,
      res_row$matched_rule_value
    ),
    evidence = list(finding_evidence(
      excerpt = sprintf(
        "%s: %s",
        res_row$matched_rule_type,
        res_row$matched_rule_value
      ),
      line = res_row$matched_line
    )),
    is_strict_only = FALSE
  )
}

# One ROBOTS_INDETERMINATE finding for a URL whose robots.txt could not be
# evaluated (a 5xx/timeout/network/TLS failure or an SSRF block: `allowed` is
# NA). Evidence records the robotstxtr fetch outcome in `excerpt`.
robots_indeterminate_finding <- function(base, loc, res_row) {
  robots_findings(
    code = "ROBOTS_INDETERMINATE",
    severity = "info",
    subject_ref = robots_subject_ref(base, loc),
    message = sprintf(
      paste0(
        "robots.txt for %s could not be evaluated (fetch outcome: %s); ",
        "allow/disallow is undetermined."
      ),
      loc,
      res_row$fetch_outcome
    ),
    evidence = list(finding_evidence(excerpt = res_row$fetch_outcome)),
    is_strict_only = FALSE
  )
}

#' Robots allow/disallow finding-producer (Layer E check #7)
#'
#' Tests each sitemap-advertised URL against the governing robots.txt via the
#' sibling `robotstxtr` package and returns robots-layer findings for the URLs
#' that are disallowed (`ROBOTS_DISALLOWED`, `warning`) or that could not be
#' decided because robots.txt would not fetch (`ROBOTS_INDETERMINATE`, `info`).
#' An allowed URL (including the allow-all a 404/410 robots.txt implies)
#' produces no row.
#'
#' Only absolute http(s) URLs are tested; other `<loc>` forms are skipped (the
#' protocol layer owns their diagnostics). robotstxtr fetches each distinct
#' origin's robots.txt exactly once under the SSRF-guarded fetch policy;
#' matching is offline, so every testable URL is checked with no sampling.
#'
#' @param locs Character vector of the URLs the sitemap advertises (`<loc>`).
#' @param user_agent The matcher user-agent (the robots.txt group to evaluate),
#'   e.g. `"*"` for the catch-all group or a specific token such as
#'   `"Googlebot"`. This is the group used for MATCHING, not the HTTP request
#'   user-agent.
#' @param base The advertising sitemap's document-level `subject_ref` base; the
#'   robots findings anchor to it with a `#page-url:<loc>` fragment.
#' @return A robots-layer findings tibble in the contract's 8-column producer
#'   shape; zero rows when nothing is disallowed or indeterminate.
#' @keywords internal
#' @noRd
validate_robots <- function(locs, user_agent, base = NA_character_) {
  testable <- robots_testable_locs(locs)
  if (length(testable) == 0L) {
    return(empty_robots_findings())
  }

  decisions <- robotstxtr::allowed_by_robots_url(
    testable,
    user_agent = user_agent,
    ssrf_guard = TRUE
  )
  results <- decisions$results

  out <- list()
  for (i in seq_len(nrow(results))) {
    row <- results[i, , drop = FALSE]
    loc <- row$url
    if (isFALSE(row$allowed)) {
      out[[length(out) + 1L]] <- robots_disallowed_finding(base, loc, row)
    } else if (is.na(row$allowed)) {
      out[[length(out) + 1L]] <- robots_indeterminate_finding(base, loc, row)
    }
  }

  if (length(out) == 0L) {
    return(empty_robots_findings())
  }
  do.call(rbind, out)
}
