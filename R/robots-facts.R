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
# 1. The robots axes are carried EXPLICITLY (`robots_context()`), never derived
#    from `sitemap_ruleset`. ADR-009 keeps its axes independent, and
#    `ruleset_context()` carries only the four sitemap-source axes — a robots
#    policy ruleset and a matcher backend are different questions from "which
#    engine's sitemap rules am I validating under".
#
# 2. Evaluation routes through the v1 engine contract
#    (`robots_evaluate_url_v1()`), so `matcher_status` / availability / the
#    policy axes flow through for E.3's per-engine gate. The legacy findings
#    stay byte-identical via the exported `as_legacy_robots_decisions_v1()`
#    shim, which is Google-bounded by construction.

# The robots policy/matcher axes for one evaluation. Kept separate from
# `ruleset_context()` on purpose (see note 1 above). Values are validated
# against the sibling's own published value sets, so an axis this build of
# robotstxtr cannot honour fails here rather than deep inside the engine.
robots_context_reject <- function(message) {
  rlang::abort(message, class = "sitemapr_invalid_robots_context")
}

# A single non-NA, non-empty string, or reject naming the argument.
check_robots_axis <- function(value, arg) {
  if (
    !is.character(value) ||
      length(value) != 1L ||
      is.na(value) ||
      !nzchar(value)
  ) {
    robots_context_reject(
      sprintf("`%s` must be a single non-empty string.", arg)
    )
  }
  value
}

# Reject an axis value the INSTALLED robotstxtr does not publish. Read from the
# public contract, so the accepted sets follow the sibling rather than a stale
# copy pinned here.
check_robots_axis_value <- function(value, arg, allowed) {
  if (!value %in% allowed) {
    robots_context_reject(
      sprintf("`%s` must be one of %s.", arg, toString(allowed))
    )
  }
  value
}

robots_context <- function(
  product_token = "*",
  policy_ruleset = "google",
  matcher_backend = "google"
) {
  check_robots_axis(product_token, "product_token")
  check_robots_axis(policy_ruleset, "policy_ruleset")
  check_robots_axis(matcher_backend, "matcher_backend")
  if (robotstxtr_available()) {
    contract <- robotstxtr_engine_contract()
    check_robots_axis_value(
      policy_ruleset,
      "policy_ruleset",
      contract$robots_policy_rulesets
    )
    check_robots_axis_value(
      matcher_backend,
      "matcher_backend",
      contract$matcher_backends
    )
  }
  structure(
    list(
      product_token = product_token,
      policy_ruleset = policy_ruleset,
      matcher_backend = matcher_backend
    ),
    class = "sitemapr_robots_context"
  )
}

# The engine presets of docs/sitemap-spec.md §13.0 live in
# tests/testthat/helper-robots-context.R, not here: no production call site
# selects a non-default context, so the constructor was package surface only
# for the tests. Promoting it to a documented export needs an exported entry
# point that can ACCEPT a context (SITE-fsawklnl).

# Is this context the Google-bounded one the legacy adapter accepts? The shim
# asserts BOTH axes are "google"; the product token is free (the legacy facade
# always took an arbitrary matcher user-agent).
robots_context_is_legacy <- function(context) {
  identical(context$policy_ruleset, "google") &&
    identical(context$matcher_backend, "google")
}

# A zero-URL facts object: nothing testable was advertised, so no evaluation
# ran. Consulting it always yields "undetermined".
robots_facts_empty <- function(context) {
  structure(
    list(
      context = context,
      urls = character(0),
      decision = character(0),
      decisions = NULL,
      legacy = NULL
    ),
    class = "sitemapr_robots_facts"
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
  idx <- match(results$source_id, evidence$source_id)
  final_status <- evidence$final_http_status[idx]
  evaluated <- !is.na(results$matcher_status) &
    results$matcher_status == "evaluated"
  missing_allow <- !is.na(final_status) & final_status %in% c(404L, 410L)

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
# finding: like the missing-sibling degrade in `resolve_robots_ua()`, an engine
# that errors on a body it should have decoded is a setup fact about the user's
# installed robotstxtr, not a diagnostic about the sitemap. The engine's own
# message is quoted so the cause stays diagnosable, and the install hint names
# the upgrade that fixes it.
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
# v1 engine contract and returns the consultable object. `legacy` is the
# Google-bounded legacy view the findings derive from; it is NULL for a
# non-Google context (the shim refuses those by design).
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
  # already reported (`resolve_robots_ua()`): a classed warning, because an
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
  legacy <- if (robots_context_is_legacy(context)) {
    robotstxtr::as_legacy_robots_decisions_v1(decisions)
  } else {
    NULL
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
      legacy = legacy
    ),
    class = "sitemapr_robots_facts"
  )
}

# Merge the per-source facts a validate call accumulated into ONE consultable
# object (E.3b). Each source evaluates its own advertised locs, so a URL two
# sitemaps both advertise is evaluated twice — under the SAME context, against
# the same robots.txt, so the two decisions agree and the first is kept.
#
# The merged object carries `decisions`/`legacy` as NULL on purpose: it exists
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
      legacy = NULL
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
