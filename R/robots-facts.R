# Robots facts/decisions producer — the consultable robots layer (E.1b,
# SITE-kwkggijf; docs/design/layer-e-page-inspection.md §7, §5.4, §0.3).
# Internal only.
#
# E.5 (R/robots-validate.R) originally called the legacy Google-only facade
# `robotstxtr::allowed_by_robots_url()` and returned FINDINGS ONLY: an allowed
# URL produced no row and the decisions object was discarded. The §5.4
# synthesis (robots.txt Disallow × noindex) has to ask "is THIS url disallowed?"
# for URLs that produce no finding, so that shape is not consultable.
#
# This file owns the refactor: one producer evaluates robots once and returns a
# per-URL decision object; BOTH the ROBOTS_* findings (R/robots-validate.R) and
# the E.3 synthesis read from it.
#
# Two deliberate design points:
#
# 1. The robots axes are carried EXPLICITLY, never derived from
#    `sitemap_ruleset`. ADR-009 keeps its axes independent, and
#    `ruleset_context()` carries only the four sitemap-source axes — a robots
#    policy ruleset and a matcher backend are different questions from "which
#    engine's sitemap rules am I validating under". The carrier itself
#    (`robots_context()`) and its per-engine presets live in R/robots-context.R.
#
# 2. Evaluation routes through the v1 engine contract
#    (`robots_evaluate_url_v1()`), so `matcher_status` / availability / the
#    policy axes flow through for E.3's per-engine gate. The ROBOTS_* findings
#    read a legacy-SHAPED view derived here from the published v1 fields
#    (`robots_findings_view()`), which works for any context; a test pins it
#    against the sibling's Google-bounded `as_legacy_robots_decisions_v1()`.

# A zero-URL facts object: nothing testable was advertised, so no evaluation
# ran. Consulting it always yields "undetermined".
robots_facts_empty <- function(context) {
  structure(
    list(
      context = context,
      urls = character(0),
      decision = character(0),
      decisions = NULL,
      view = NULL
    ),
    class = "sitemapr_robots_facts"
  )
}

# The two per-row predicates every derivation below shares, joined to the
# per-source evidence once. `evaluated` is "the matcher actually returned a
# verdict"; `missing_allow` is "robots.txt was absent (404/410), which IS a
# policy allow-all". They are separated because the v1 fields alone cannot tell
# an absent robots.txt from a forbidden one — see the note on the trichotomy
# below.
robots_row_flags <- function(results, evidence) {
  idx <- match(results$source_id, evidence$source_id)
  final_status <- evidence$final_http_status[idx]
  list(
    idx = idx,
    evaluated = !is.na(results$matcher_status) &
      results$matcher_status == "evaluated",
    missing_allow = !is.na(final_status) & final_status %in% c(404L, 410L)
  )
}

# The row view the ROBOTS_* finding producers read (R/robots-validate.R):
# `allowed` plus the four columns the messages and evidence quote. Derived HERE
# from the PUBLISHED v1 fields, so it exists for ANY robots context — that is
# what lets a non-Google context produce findings at all (SITE-fsawklnl).
#
# It reproduces `as_legacy_robots_decisions_v1()`'s arithmetic deliberately, for
# the same reason `robots_decision_trichotomy()` does: the sibling's shim is
# engine-agnostic in how it DERIVES these columns and Google-bounded only in the
# guard it opens with, so reproducing the derivation is the whole of what a
# non-Google path needs. A test asserts this view agrees with the shim's own
# `results` column-for-column under a Google context, so E.5's output stays
# byte-identical (ADR-009 §5) and the two cannot drift.
#
# Only the six columns with a reader are built. The rest of the legacy schema
# (`input_id`, `decision_source`, `robots_url`, `http_status`, `error_*`) is
# consumed nowhere in sitemapr, and deriving it would be an unread copy of the
# sibling's shim rather than the minimum a finding needs.
robots_findings_view <- function(results, evidence) {
  n <- nrow(results)
  flags <- robots_row_flags(results, evidence)
  matched <- flags$evaluated
  has_source <- !is.na(flags$idx)

  allowed <- rep(NA, n)
  allowed[matched] <- results$url_decision[matched] == "allow"
  allowed[flags$missing_allow] <- TRUE

  # No matching evidence row means the input never reached the fetcher at all.
  fetch_outcome <- rep("input_invalid", n)
  fetch_outcome[has_source] <- evidence$legacy_fetch_outcome[
    flags$idx[has_source]
  ]

  # An unevaluated row carries no matched rule: the matcher never ran, so the
  # rule columns describe nothing and must not leak a stale value into a
  # finding's evidence.
  matched_rule_type <- results$matched_rule_type
  matched_rule_type[!matched] <- "unknown"
  matched_rule_value <- results$matched_rule_value
  matched_rule_value[!matched] <- NA_character_
  matched_line <- results$matched_line
  matched_line[!matched] <- NA_integer_

  data.frame(
    url = results$url,
    allowed = allowed,
    fetch_outcome = fetch_outcome,
    matched_line = matched_line,
    matched_rule_type = matched_rule_type,
    matched_rule_value = matched_rule_value,
    stringsAsFactors = FALSE
  )
}

# Reduce the v1 per-row result to the trichotomy the finding producers and the
# §5.4 synthesis actually consult.
#
# This mirrors `as_legacy_robots_decisions_v1()`'s rule deliberately, because
# the v1 fields ALONE cannot separate two cases that must not be conflated: a
# 404/410 robots.txt (a real policy allow-all) and a 403 (unknown) both surface
# as `matcher_status = "not_needed"`, `url_decision = "allow"`,
# `reason = "policy_allow_all"`. The only discriminator is the HTTP status,
# exactly as the shim uses it. A test asserts this trichotomy agrees with the
# legacy `allowed` column row-for-row, so the two cannot drift.
#
# Deliberately CONSERVATIVE: "disallow" is reported only on an evaluated
# matcher verdict, and "allow" only on a confident allow. Anything else is
# "undetermined". The synthesis fires only on "disallow", so conservatism can
# never manufacture a false trap warning — it can only decline to claim one.
robots_decision_trichotomy <- function(results, evidence) {
  n <- nrow(results)
  if (n == 0L) {
    return(character(0))
  }
  flags <- robots_row_flags(results, evidence)
  evaluated <- flags$evaluated
  missing_allow <- flags$missing_allow

  out <- rep("undetermined", n)
  out[
    evaluated & !is.na(results$url_decision) & results$url_decision == "allow"
  ] <- "allow"
  out[missing_allow] <- "allow"
  out[
    evaluated &
      !is.na(results$url_decision) &
      results$url_decision == "disallow"
  ] <- "disallow"
  out
}

# Signal that the robots engine failed outright, so the robots layer is skipped
# while every other layer proceeds. Deliberately a classed WARNING rather than a
# finding: like the missing-sibling degrade in `resolve_robots_context()`, an
# engine that errors on a body it should have decoded is a setup fact about the
# user's installed robotstxtr, not a diagnostic about the sitemap. The engine's
# own message is quoted so the cause stays diagnosable, and the install hint
# names the upgrade that fixes it.
robots_engine_failed_warn <- function(cnd) {
  rlang::warn(
    sprintf(
      paste0(
        "robots allow/disallow check skipped: the 'robotstxtr' engine failed ",
        "to evaluate robots.txt (%s). Upgrade it with %s."
      ),
      conditionMessage(cnd),
      robotstxtr_install_hint()
    ),
    class = "sitemapr_robots_engine_failed",
    parent = cnd
  )
}

# The facts producer. Evaluates every testable advertised loc ONCE through the
# v1 engine contract and returns the consultable object. `view` is the row view
# the ROBOTS_* findings derive from; unlike the sibling's legacy shim it is
# built for every context, so an engine other than Google produces findings
# rather than an error.
robots_evaluate_facts <- function(locs, context = robots_context()) {
  testable <- robots_testable_locs(locs)
  if (length(testable) == 0L) {
    return(robots_facts_empty(context))
  }
  # Gate the sibling's contract before touching the v1 API, so an incompatible
  # robotstxtr fails loudly here rather than erroring on a missing field.
  robotstxtr_engine_contract()

  # The engine reports every EXPECTED robots failure as data — a `fetch_outcome`
  # of missing/timeout/ssrf_blocked, with `allowed` NA — so a bare R error out
  # of the v1 call is by definition unforeseen. An old wholesale-installed
  # sibling aborts here on a robots.txt carrying a NUL byte ("embedded nul in
  # string", a plain `simpleError` from `rawToChar()`); one malformed robots.txt
  # on a crawled origin would otherwise abort the whole validation run.
  #
  # Degrade rather than propagate, and report it the way a missing sibling is
  # already reported (`resolve_robots_context()`): a classed warning, because an
  # engine that cannot decode a body is a fact about the INSTALLED ENGINE, not a
  # finding about the sitemap. Fixed upstream, so a current robotstxtr never
  # trips this — but robotstxtr is Suggests and installed wholesale, so a
  # version pin cannot repair an already-installed build (SITE-wgifofwc).
  decisions <- tryCatch(
    robotstxtr::robots_evaluate_url_v1(
      testable,
      robots_product_token = context$product_token,
      robots_policy_ruleset = context$policy_ruleset,
      matcher_backend = context$matcher_backend,
      ssrf_guard = TRUE
    ),
    error = function(cnd) {
      robots_engine_failed_warn(cnd)
      NULL
    }
  )
  if (is.null(decisions)) {
    return(robots_facts_empty(context))
  }
  structure(
    list(
      context = context,
      urls = decisions$results$url,
      decision = robots_decision_trichotomy(
        decisions$results,
        decisions$evidence
      ),
      decisions = decisions,
      view = robots_findings_view(decisions$results, decisions$evidence)
    ),
    class = "sitemapr_robots_facts"
  )
}

# Merge the per-source facts a validate call accumulated into ONE consultable
# object (E.3b). Each source evaluates its own advertised locs, so a URL two
# sitemaps both advertise is evaluated twice — under the SAME context, against
# the same robots.txt, so the two decisions agree and the first is kept.
#
# The merged object carries `decisions`/`view` as NULL on purpose: it exists
# to be CONSULTED (`robots_decision_for()` / `robots_facts_consultable()`), not
# to derive findings from. `robots_findings_from_facts()` stays per-source,
# where each finding still anchors to its own advertising sitemap base.
robots_facts_merge <- function(parts) {
  parts <- parts[!vapply(parts, is.null, logical(1L))]
  if (length(parts) == 0L) {
    return(NULL)
  }
  urls <- unlist(lapply(parts, function(p) p$urls), use.names = FALSE)
  decision <- unlist(lapply(parts, function(p) p$decision), use.names = FALSE)
  keep <- !duplicated(urls)
  structure(
    list(
      context = parts[[1L]]$context,
      urls = urls[keep],
      decision = decision[keep],
      decisions = NULL,
      view = NULL
    ),
    class = "sitemapr_robots_facts"
  )
}

# Consult the facts for one URL (the §5.4 synthesis entry point). Returns
# "allow", "disallow", or "undetermined"; a URL that was never evaluated (not
# advertised, not testable, or robots evaluation disabled) is "undetermined".
robots_decision_for <- function(facts, url) {
  if (is.null(facts) || length(facts$urls) == 0L) {
    return(rep("undetermined", length(url)))
  }
  idx <- match(as.character(url), facts$urls)
  out <- rep("undetermined", length(url))
  out[!is.na(idx)] <- facts$decision[idx[!is.na(idx)]]
  out
}

# Is a consultable robots decision available at all? The §7 gate: the synthesis
# may only run when robots evaluation was both ENABLED (check_robots = TRUE, so
# a facts object exists) and AVAILABLE (robotstxtr present, so it holds rows).
robots_facts_consultable <- function(facts) {
  !is.null(facts) && length(facts$urls) > 0L
}
