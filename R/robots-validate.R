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
# The engine is the sibling package `robotstxtr`, used WHOLESALE: it owns the
# faithful matcher AND the HTTP-status -> policy semantics (a 404/410 is
# allow-all, a 5xx/timeout/network failure or an SSRF block is indeterminate),
# and it fetches each distinct origin's robots.txt exactly once. sitemapr does
# NOT reimplement fetching or matching. The `ssrf_guard = TRUE` opt-out is left
# at its default so the robots.txt fetch honours the same SSRF posture as the
# rest of sitemapr (ADR-003; robotstxtr ROBO-quovenef).
#
# Since E.1b (SITE-kwkggijf) evaluation itself lives in R/robots-facts.R and
# routes through the v1 engine contract, so the robots axes and `matcher_status`
# flow through for E.3's per-engine synthesis gate. THIS file only derives
# findings from that already-evaluated facts object. The derivation reads the
# facts' Google-bounded legacy view so E.5's output stayed byte-identical
# across the refactor.
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

# The `robotstxtr` engine-aware contract sitemapr is built against
# (docs/design/layer-e-page-inspection.md §0.9; robotstxtr v0.2.0). Pinned as a
# literal so a sibling that moved to an incompatible contract is caught at the
# seam instead of silently producing robots findings under different matcher
# semantics.
robotstxtr_contract_id <- function() {
  "robotstxtr.engine-aware/v1"
}

# The engine schema revision sitemapr was developed against. Reported in the
# gate's error message for diagnosis; it is deliberately NOT an equality gate,
# since robotstxtr may ship additive revisions that stay compatible.
#
# It is recorded because `contract_id` alone does NOT discriminate builds: a
# pre-#43 robotstxtr reports the SAME `robotstxtr.engine-aware/v1` id while
# carrying schema 2026-07-17.1 and no `matcher_capability` at all. The gate
# below therefore checks for the capability field sitemapr consumes rather than
# trusting the contract id by itself.
robotstxtr_contract_schema <- function() {
  "2026-07-18.2"
}

# The public v1 contract object of the INSTALLED `robotstxtr`, gated before it
# is handed out. Only ever called once availability is established.
#
# Three failure shapes, all loud (a classed error, never a silent skip): an
# install that does not expose the accessor at all, one whose `contract_id` has
# moved on, and one carrying the right id but no `matcher_capability` (the
# pre-#43 build). Absence of the package stays a warning + graceful skip in
# resolve_robots_ua() — that is a setup fact about the user's machine — but a
# version that is present and INCOMPATIBLE would otherwise yield wrong robots
# findings, so it aborts instead.
#
# Only the exported accessor is touched: `engine_backend_capability_v1()` and
# the other `*_v1()` helpers are robotstxtr internals and are deliberately not
# reached into (SITE-ykagmqdd step 4).

# The raw contract object straight from the sibling, with no gating. Split out
# as a named binding so tests can stand in an older/foreign contract shape
# without needing that build installed.
robotstxtr_engine_contract_raw <- function() {
  ns <- asNamespace("robotstxtr")
  if (!exists("robots_engine_contract_v1", envir = ns, inherits = FALSE)) {
    rlang::abort(
      sprintf(
        paste0(
          "the installed 'robotstxtr' does not expose ",
          "robots_engine_contract_v1(); sitemapr requires robotstxtr ",
          "(>= 0.2.0) carrying engine contract '%s'. Update it with %s."
        ),
        robotstxtr_contract_id(),
        robotstxtr_install_hint()
      ),
      class = "sitemapr_robotstxtr_contract"
    )
  }
  robotstxtr::robots_engine_contract_v1()
}

robotstxtr_engine_contract <- function() {
  contract <- robotstxtr_engine_contract_raw()
  if (!identical(contract$contract_id, robotstxtr_contract_id())) {
    rlang::abort(
      sprintf(
        paste0(
          "incompatible 'robotstxtr' engine contract: sitemapr is built ",
          "against '%s' but the installed package reports '%s'. Update it ",
          "with %s."
        ),
        robotstxtr_contract_id(),
        as.character(contract$contract_id)[[1L]],
        robotstxtr_install_hint()
      ),
      class = "sitemapr_robotstxtr_contract"
    )
  }
  # The capability check that the contract id cannot make: a stale build
  # advertises the same id but omits `matcher_capability`, so consuming it
  # would silently yield NULL capability rather than failing.
  if (is.null(contract$matcher_capability)) {
    schema <- contract$schema_revision
    if (is.null(schema)) {
      schema <- "unknown"
    }
    rlang::abort(
      sprintf(
        paste0(
          "the installed 'robotstxtr' reports engine contract '%s' but ",
          "carries no matcher_capability (schema '%s'); sitemapr needs the ",
          "capability-bearing schema '%s' or newer. Update it with %s."
        ),
        robotstxtr_contract_id(),
        as.character(schema)[[1L]],
        robotstxtr_contract_schema(),
        robotstxtr_install_hint()
      ),
      class = "sitemapr_robotstxtr_contract"
    )
  }
  contract
}

# The matcher capability table, read through the PUBLIC contract accessor. The
# consulted-robots refactor (E.1b) reads capability from here rather than from
# robotstxtr's internal `engine_backend_capability_v1()`.
robotstxtr_matcher_capability <- function() {
  robotstxtr_engine_contract()$matcher_capability
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
  facts <- robots_evaluate_facts(
    locs,
    context = robots_context(product_token = user_agent)
  )
  robots_findings_from_facts(facts, base)
}

# Derive the ROBOTS_* findings from an already-evaluated facts object (E.1b).
# Split from evaluation so the same single evaluation feeds BOTH these findings
# and the §5.4 synthesis.
#
# The rows are read from the facts' LEGACY view, not from the v1 results: the
# messages and evidence quote legacy vocabulary (`fetch_outcome`) and the
# legacy `allowed` trichotomy, so reading it keeps E.5's output byte-identical
# across this refactor (ADR-009 §5 back-compat). That view is Google-bounded by
# the shim, so a non-Google context has no legacy rows to derive from and is
# rejected rather than silently emitting nothing.
robots_findings_from_facts <- function(facts, base = NA_character_) {
  if (!robots_facts_consultable(facts)) {
    return(empty_robots_findings())
  }
  if (is.null(facts$legacy)) {
    rlang::abort(
      sprintf(
        paste0(
          "ROBOTS_* findings are derived through the Google-bounded legacy ",
          "adapter, but the robots context selects policy '%s' / matcher ",
          "'%s'. Consult the decision object instead."
        ),
        facts$context$policy_ruleset,
        facts$context$matcher_backend
      ),
      class = "sitemapr_robots_findings_unsupported"
    )
  }
  results <- facts$legacy$results

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
