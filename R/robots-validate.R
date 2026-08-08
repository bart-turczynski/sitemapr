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
# facts' legacy-SHAPED row view (`robots_findings_view()`) so E.5's output
# stayed byte-identical across the refactor — and, since SITE-fsawklnl derives
# that view here rather than through the sibling's Google-bounded legacy shim,
# every ROBOTS_* finding is now available under any robots context.
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
  is_strict_only = logical(0),
  subject_type = "page-url"
) {
  n <- length(code)
  tibble::tibble(
    code = as.character(code),
    severity = as.character(severity),
    layer = rep("robots", n),
    subject_type = rep(subject_type, n),
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
# resolve_robots_context() — a setup fact about the user's machine — but a
# version that is present and INCOMPATIBLE would otherwise yield wrong robots
# findings, so it aborts instead.
#
# Only the exported accessor is touched: `engine_backend_capability_v1()` and
# the other `*_v1()` helpers are robotstxtr internals and are deliberately not
# reached into (SITE-ykagmqdd step 4).

# The raw contract object straight from the sibling, with no gating. Split out
# as a named binding so tests can stand in an older/foreign contract shape
# without needing that build installed.
# The installed sibling's namespace, read through a named seam. Split out for
# the same reason as the raw contract below: a test can stand in a namespace
# that predates `robots_engine_contract_v1()` without needing that build
# installed, and `asNamespace()` itself is a base binding tests cannot shadow.
robotstxtr_namespace <- function() {
  asNamespace("robotstxtr")
}

robotstxtr_engine_contract_raw <- function() {
  ns <- robotstxtr_namespace()
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

# Only absolute http(s) URLs are robots-testable: a relative or non-http `<loc>`
# is not something a crawler fetches, and feeding it to the matcher would only
# echo the malformed-loc problems the protocol layer already reports. The
# absoluteness classifier is shared with the protocol producer.
robots_testable_locs <- function(locs) {
  locs <- as.character(locs)
  locs <- locs[!is.na(locs) & nzchar(locs)]
  unique(locs[loc_absoluteness(locs) == "http(s)"])
}

# One column of the legacy results table, recycled to `nrow` when the column is
# absent. The per-row builders this replaced only ever touched a column inside
# the branch that needed it, so a results table carrying just one branch's
# columns stayed valid; reading every column in one vectorized pass would break
# that unless a missing column reads as NA.
robots_result_col <- function(rows, name, default = NA_character_) {
  col <- rows[[name]]
  if (is.null(col)) {
    return(rep(default, nrow(rows)))
  }
  col
}

# The ROBOTS_DISALLOWED message for a vector of disallowed URLs. Evidence
# carries the matcher's matched robots.txt rule: the `type: value` snippet in
# `excerpt` (e.g. `disallow: /private`) and the one-based `matched_line` in
# `line`. Vectorized over rows — see `robots_findings_from_facts()`.
robots_disallowed_messages <- function(loc, rows) {
  sprintf(
    "Sitemap-listed URL %s is disallowed by robots.txt (matched %s '%s').",
    loc,
    robots_result_col(rows, "matched_rule_type"),
    robots_result_col(rows, "matched_rule_value")
  )
}

# The ROBOTS_INDETERMINATE message for a vector of URLs whose robots.txt could
# not be evaluated (a 5xx/timeout/network/TLS failure or an SSRF block:
# `allowed` is NA). Evidence records the robotstxtr fetch outcome in `excerpt`.
robots_indeterminate_messages <- function(loc, rows) {
  sprintf(
    paste0(
      "robots.txt for %s could not be evaluated (fetch outcome: %s); ",
      "allow/disallow is undetermined."
    ),
    loc,
    robots_result_col(rows, "fetch_outcome")
  )
}

# Reject a facts object that carries no row view. A MERGED facts object
# (`robots_facts_merge()`) is the one such shape: it drops the view on purpose,
# because it exists to be CONSULTED per URL and every finding has to anchor to
# its own advertising sitemap base. Deriving findings from one would silently
# emit zero rows, so it fails loudly instead.
robots_view_required <- function() {
  rlang::abort(
    paste0(
      "ROBOTS_* findings must be derived from a per-source facts object ",
      "carrying a row view, not from a merged one."
    ),
    class = "sitemapr_robots_findings_unsupported"
  )
}

# --- Document-level check: is the sitemap itself disallowed? (§0.6) ----------
#
# The checks above test the URLs a sitemap ADVERTISES. This one tests the
# sitemap DOCUMENT's own URL: a sitemap published at a path its own robots.txt
# `Disallow`-es is a self-contradiction — the site both advertises the document
# and forbids crawlers from fetching it. Webmaster tools warn on it; the exact
# fetch mechanics vary by engine (a submitted sitemap may still be read), so it
# is framed as a consistency diagnostic (`warning`), never a hard failure.
#
# Scope: the sitemap URL as REQUESTED (the advertised/submitted address), not
# the post-redirect final URL — the requested address is what a crawler matches
# against robots.txt, and it is the address the site owner would have to change.
# Only the top-level source documents of a call are tested; index children are
# fetched during expansion and are out of scope for this slice.
#
# Indeterminacy (robots.txt would not fetch) deliberately produces NO row here:
# `ROBOTS_INDETERMINATE` is a `page-url`-scoped code, and a document-level
# analog would be a second coordinated registry addition for a strictly weaker
# signal — the listed-URL check already reports the same unfetchable robots.txt
# whenever the sitemap advertises anything on that origin.

# The source-scoped subject_ref for a document-level robots finding: the
# sitemap's own document base, with no fragment (findings-contract.md "Subject
# ref format" — a `source` subject is the document itself).
robots_sitemap_subject_ref <- function(base) {
  if (is.null(base)) NA_character_ else base
}

# One ROBOTS_SITEMAP_DISALLOWED finding. Evidence mirrors ROBOTS_DISALLOWED:
# the matched `type: value` snippet in `excerpt` and its one-based robots.txt
# line in `line`.
robots_sitemap_disallowed_finding <- function(base, url, res_row) {
  robots_findings(
    code = "ROBOTS_SITEMAP_DISALLOWED",
    severity = "warning",
    subject_type = "source",
    subject_ref = robots_sitemap_subject_ref(base),
    message = sprintf(
      paste0(
        "Sitemap document %s is disallowed by its own robots.txt (matched ",
        "%s '%s'); crawlers are told not to fetch a sitemap the site ",
        "advertises."
      ),
      url,
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

#' Sitemap-document robots finding-producer (§0.6, E.5 sibling)
#'
#' Tests the sitemap document's own URL against the governing robots.txt and
#' returns a `ROBOTS_SITEMAP_DISALLOWED` (`warning`) row when the document is
#' disallowed for the matcher user-agent. An allowed or undecidable document
#' produces no row, as does a non-http(s) source (a local file has no robots.txt
#' to contradict).
#'
#' @param sitemap_url The sitemap's requested URL.
#' @param context The [robots_context()] to evaluate under: the matcher
#'   product token (the robots.txt group), the policy ruleset, and the matcher
#'   backend, as in `validate_robots()`.
#' @param base The sitemap's document-level `subject_ref`; the finding anchors
#'   to it unfragmented (`subject_type = "source"`).
#' @return A robots-layer findings tibble in the contract's 8-column producer
#'   shape; zero rows when the document is not disallowed.
#' @keywords internal
#' @noRd
validate_robots_sitemap <- function(
  sitemap_url,
  context,
  base = NA_character_
) {
  url <- robots_testable_locs(sitemap_url)
  if (length(url) == 0L) {
    return(empty_robots_findings())
  }
  robots_sitemap_findings_from_facts(
    robots_evaluate_facts(url, context = context),
    base
  )
}

# Derive the document-level finding from an already-evaluated facts object. The
# facts here describe exactly ONE url (the sitemap's own), so the view carries
# at most one row. Like robots_findings_from_facts() it reads the facts' derived
# row view, which exists for every robots context.
robots_sitemap_findings_from_facts <- function(facts, base = NA_character_) {
  if (!robots_facts_consultable(facts)) {
    return(empty_robots_findings())
  }
  if (is.null(facts$view)) {
    robots_view_required()
  }
  results <- facts$view
  out <- list()
  for (i in seq_len(nrow(results))) {
    row <- results[i, , drop = FALSE]
    if (isFALSE(row$allowed)) {
      out[[length(out) + 1L]] <- robots_sitemap_disallowed_finding(
        base,
        row$url,
        row
      )
    }
  }
  if (length(out) == 0L) {
    return(empty_robots_findings())
  }
  do.call(rbind, out)
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
#' @param context The [robots_context()] to evaluate under. Its
#'   `product_token` is the robots.txt group used for MATCHING — `"*"` for the
#'   catch-all group or a specific token such as `"Googlebot"` — not the HTTP
#'   request user-agent; its other two axes select the policy ruleset and the
#'   matcher backend.
#' @param base The advertising sitemap's document-level `subject_ref` base; the
#'   robots findings anchor to it with a `#page-url:<loc>` fragment.
#' @return A robots-layer findings tibble in the contract's 8-column producer
#'   shape; zero rows when nothing is disallowed or indeterminate.
#' @keywords internal
#' @noRd
validate_robots <- function(locs, context, base = NA_character_) {
  robots_part(locs, context, base)$findings
}

# Evaluate one source's advertised locs and return BOTH halves: the ROBOTS_*
# findings and the facts object they were derived from. `validate_robots()` is
# the findings-only composition; the validate pipeline calls this instead
# because the §5.4 trap synthesis (E.3b) has to retain the facts — the whole
# point of the E.1b split is that ONE evaluation feeds both consumers.
robots_part <- function(locs, context, base = NA_character_) {
  facts <- robots_evaluate_facts(locs, context = context)
  list(facts = facts, findings = robots_findings_from_facts(facts, base))
}

# Derive the ROBOTS_* findings from an already-evaluated facts object (E.1b).
# Split from evaluation so the same single evaluation feeds BOTH these findings
# and the §5.4 synthesis.
#
# The rows are read from the facts' derived row view, not from the raw v1
# results: the messages and evidence quote legacy vocabulary (`fetch_outcome`)
# and the `allowed` trichotomy, so reading that view keeps E.5's output
# byte-identical across the refactors (ADR-009 §5 back-compat). Unlike the
# sibling's Google-bounded legacy shim the view is built for EVERY context, so
# selecting another engine yields findings rather than an error (SITE-fsawklnl).
robots_findings_from_facts <- function(facts, base = NA_character_) {
  if (!robots_facts_consultable(facts)) {
    return(empty_robots_findings())
  }
  if (is.null(facts$view)) {
    robots_view_required()
  }
  results <- facts$view

  # Built in ONE vectorized pass rather than one tibble per row. Under a blanket
  # `Disallow: /` over a 50 000-URL sitemap the per-row form spent ~32s, 95% of
  # it constructing 50 000 single-row tibbles (the trailing rbind was only 5%),
  # so the fix is vectorizing the build, not the accumulator (SITE-wlmodqza).
  # Row order is preserved, so the disallowed/indeterminate interleave matches
  # the results table exactly.
  allowed <- results$allowed
  emit <- which(is.na(allowed) | !allowed)
  if (length(emit) == 0L) {
    return(empty_robots_findings())
  }
  rows <- results[emit, , drop = FALSE]
  loc <- rows$url
  is_dis <- !is.na(rows$allowed)

  robots_findings(
    code = ifelse(is_dis, "ROBOTS_DISALLOWED", "ROBOTS_INDETERMINATE"),
    severity = ifelse(is_dis, "warning", "info"),
    subject_ref = page_url_subject_ref(base, loc),
    message = ifelse(
      is_dis,
      robots_disallowed_messages(loc, rows),
      robots_indeterminate_messages(loc, rows)
    ),
    evidence = unname(Map(
      function(excerpt, line) finding_evidence(excerpt = excerpt, line = line),
      ifelse(
        is_dis,
        sprintf(
          "%s: %s",
          robots_result_col(rows, "matched_rule_type"),
          robots_result_col(rows, "matched_rule_value")
        ),
        robots_result_col(rows, "fetch_outcome")
      ),
      ifelse(
        is_dis,
        robots_result_col(rows, "matched_line", NA_integer_),
        NA_integer_
      )
    )),
    is_strict_only = rep(FALSE, length(emit))
  )
}
