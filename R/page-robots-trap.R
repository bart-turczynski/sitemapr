# The robots.txt Disallow × noindex trap synthesis (E.3b, SITE-zbpfswsz;
# docs/design/layer-e-page-inspection.md §5.4; docs/sitemap-spec.md §13.5).
# Internal only.
#
# A URL can be advertised in the sitemap, Disallow-ed by robots.txt, AND carry a
# `noindex`. That combination is self-defeating: the engine never fetches the
# page, so it never reads the `noindex`, and the URL can still be indexed
# without a description. sitemapr is uniquely able to see it because page
# inspection fetches the body the engine will not.
#
# Emission is option (a): NO new registered code. The synthesis is attached as
# the `remediation_hint` of the PAGE_*_NOINDEX finding that already fired, so
# the registry needs no migration and both component findings (ROBOTS_DISALLOWED
# and the noindex code) still fire independently (D2).
#
# Two gates keep this honest, and both can only ever DECLINE to claim a trap:
#
#  1. The MECHANIC must be documented for the engine. Google and Bing are
#     `documented` with primary quotes (§5.4). Yandex is NOT: the URL-only-
#     indexing-when-robots-blocked case has no primary Yandex source, so it
#     stays a `documentation_gap` and is never encoded, in any form (§13.5).
#     It must not be inferred from the Google/Bing mechanics.
#
#  2. The DECISION must have come from the engine's own matcher. A Bing verdict
#     laundered through the Google matcher is a Google verdict wearing a Bing
#     label — robotstxtr's own anti-laundering rule (§13.1), and today Bing's
#     matcher reports `capability_unavailable`, so in practice only Google
#     stamps. Read exclusively from the PUBLIC contract accessor; the internal
#     `engine_backend_capability_v1()` is not reached into.
#
# Unlike the fold in R/page-noindex.R — which must stay robotstxtr-free because
# interpretation may not gate on a `Suggests` (§0.3 / §13.1) — this synthesis is
# an ACCESS × interpretation join, so it legitimately consults robotstxtr. That
# is why it lives here and not in the fold producer: the fold degrades
# gracefully without the sibling, the synthesis simply does not fire.

# Human-facing engine name and the admin surface the hint points at, for the
# engines whose trap mechanic is documented. NULL for any other engine.
page_trap_engine_labels <- function() {
  list(
    google = list(name = "Google", panel = "Google Search Console"),
    bing = list(name = "Bing", panel = "Bing Webmaster Tools")
  )
}

# Provenance of the TRAP MECHANIC for an engine (§5.4 / §13.5). Distinct from
# the fold provenance R/page-noindex.R stamps on the finding: that one describes
# how the effective-noindex verdict was reached, this one describes the
# robots-blocked-URL claim the hint makes.
page_trap_mechanic_provenance <- function(engine) {
  if (is.null(engine)) {
    return(NA_character_)
  }
  if (!is.null(page_trap_engine_labels()[[engine]])) {
    return("documented")
  }
  # Yandex reaches here: the mechanic is plausible but unsourced, and an
  # unsourced mechanic is a gap, never an inference from a sibling engine.
  "documentation_gap"
}

# Was the robots decision produced by THIS engine's own matcher, under its own
# policy, on a build where that matcher is actually available? All four
# conditions must hold; any of them failing means the decision does not
# describe the engine the fold is speaking for.
page_trap_matcher_attributable <- function(engine, facts) {
  ctx <- facts$context
  if (!identical(ctx$policy_ruleset, engine)) {
    return(FALSE)
  }
  if (!identical(ctx$matcher_backend, engine)) {
    return(FALSE)
  }
  contract <- robotstxtr_engine_contract()
  if (!identical(contract$matcher_availability[[engine]], "available")) {
    return(FALSE)
  }
  capability <- contract$matcher_capability[[engine]]
  identical(capability$matcher_semantics, engine)
}

# The full gate: may the synthesis be stamped for this engine at all? Answered
# once per run, before any per-URL work.
page_trap_stampable <- function(engine, facts) {
  if (is.null(engine) || !robots_facts_consultable(facts)) {
    return(FALSE)
  }
  if (!identical(page_trap_mechanic_provenance(engine), "documented")) {
    return(FALSE)
  }
  if (!robotstxtr_available()) {
    return(FALSE)
  }
  page_trap_matcher_attributable(engine, facts)
}

# Which channel a noindex code speaks for, phrased as the hint reads it.
page_trap_channel_phrase <- function(code) {
  if (identical(code, "PAGE_META_ROBOTS_NOINDEX")) {
    "a <meta name=robots> noindex"
  } else {
    "an X-Robots-Tag noindex"
  }
}

# The intent-neutral hint (§5.4 message discipline). It states the conflict and
# BOTH possible intents and never universally says "remove the block": some
# content should stay access-controlled, robots.txt is not a security
# mechanism, and removal tools are not a permanent substitute. The evaluated
# robots GROUP is named explicitly, because a decision for the `*` group is not
# a claim about a crawler that may have a group of its own.
page_trap_message <- function(engine, code, group) {
  labels <- page_trap_engine_labels()[[engine]]
  paste0(
    sprintf(
      paste0(
        "This URL is advertised in the sitemap, disallowed by robots.txt for ",
        "the '%s' group, and also carries %s. Per %s documentation, ",
        "robots.txt stops the crawler from fetching the page, so it never ",
        "sees the noindex, and the URL can still be indexed (without a ",
        "description) if other pages link to it. "
      ),
      group,
      page_trap_channel_phrase(code),
      labels$name
    ),
    sprintf(
      paste0(
        "If the intent is to keep the page out of the index, allow crawling ",
        "so the noindex can be read (or use the engine's removal tool); if ",
        "the intent is only to block crawling, the noindex has no effect. ",
        "Verify live status in %s."
      ),
      labels$panel
    )
  )
}

# Add the trap context keys to one finding's producer context, so a reader can
# tell a hinted row from an unhinted one structurally and see which engine and
# provenance the claim carries.
page_trap_context <- function(context, engine) {
  context$page_noindex_trap <- TRUE
  context$page_noindex_trap_engine <- engine
  context$page_noindex_trap_provenance <- page_trap_mechanic_provenance(engine)
  context
}

# Attach the §5.4 synthesis to the noindex findings a run produced.
#
# A DECORATOR, deliberately: it takes the already-built PAGE_*_NOINDEX tibble
# and fills `remediation_hint` on the rows whose URL the robots facts report as
# "disallow". The producer stays untouched (and robotstxtr-free), the component
# findings keep firing on their own, and no row is added or removed.
#
# The per-URL join reads `page_noindex_loc` from the producer context, which is
# the raw advertised loc the robots facts were keyed on. `robots_decision_for()`
# is conservative — "disallow" requires an evaluated matcher verdict — so an
# undetermined robots.txt can only suppress a hint, never invent one.
page_noindex_attach_trap <- function(findings, facts, engine) {
  if (nrow(findings) == 0L || !page_trap_stampable(engine, facts)) {
    return(findings)
  }
  group <- facts$context$product_token
  hint <- rep(NA_character_, nrow(findings))
  for (i in seq_len(nrow(findings))) {
    context <- findings$context[[i]]
    loc <- context$page_noindex_loc
    if (is.null(loc)) {
      next
    }
    if (!identical(robots_decision_for(facts, loc), "disallow")) {
      next
    }
    hint[[i]] <- page_trap_message(engine, findings$code[[i]], group)
    findings$context[[i]] <- page_trap_context(context, engine)
  }
  if (all(is.na(hint))) {
    return(findings)
  }
  findings$remediation_hint <- hint
  findings
}
