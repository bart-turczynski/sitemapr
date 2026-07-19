# Page-transport finding producer + coverage metadata (Layer E, Contract D /
# E.1f). Internal only.
#
# This is the integration seam that turns the engine-neutral page-inspection
# spine (page_inspection_run() over page_fetch() artifacts, E.1a/E.1s) into
# `page`-layer findings and the batch-wide coverage attribute. It CONSUMES the
# spine; it never fetches, never modifies page_fetch()/page_inspection_run()/the
# assembler. It maps each artifact `outcome` to AT MOST ONE transport finding
# per advertised URL, anchored to each advertising sitemap `subject_ref`.
#
# Governing contracts (conform, do not restate):
#   docs/design/layer-e-page-inspection.md  §0.5 (matrix conforms to the
#     registry — AUTHORITATIVE), §0.7 (per-finding context / excerpt collapse),
#     §0.11 (precedence + coverage shape), §6 (Contract D)
#   docs/decisions/ADR-010-page-inspection.md  §3 (safety vs resource split)
#   docs/findings-registry.csv  (the five active PAGE_* transport rows and their
#     severities — the producer emits the CODE; severity conforms to the row)
#
# Emission (§0.5 + §3.4 matrix, registry severities):
#   usable_body / partial          -> no transport finding (extractors E.2-E.4)
#   http_status                    -> PAGE_STATUS_ERROR   (terminal 4xx/5xx, or
#                                     3xx with no resolvable Location)
#   resolved redirect (2xx, final  -> PAGE_STATUS_REDIRECT (final_url differs
#     != requested under §5.2)        from requested under the identity rule)
#   redirect_over_budget           -> PAGE_REDIRECT_CHAIN
#   transport_fail / incomplete /  -> PAGE_FETCH_FAILED  (incomplete carries
#     http_protocol_error             the 500 MB ceiling discard, sec 0.5)
#   safety_refused                 -> PAGE_SSRF_BLOCKED  (mapped generically
#                                     so a downgrade-reject flows in later)
#   not_applicable                 -> no finding
#
# Precedence (§0.11): safety_refused > terminal http_status > redirect. A
# page_fetch_artifact already carries exactly ONE outcome, so precedence is
# encoded by that single value: a safety refusal or a terminal status is its own
# outcome and never coexists with the (2xx + final_url differs) redirect
# observation, so at most one transport finding is emitted per URL.

# The outcome -> code map for the outcomes that map DIRECTLY (independent of the
# hop trail). The redirect case is NOT here: it is derived from a 2xx outcome
# whose final_url differs from the requested URL (page_is_redirect()).
page_outcome_code_map <- function() {
  c(
    safety_refused = "PAGE_SSRF_BLOCKED",
    http_status = "PAGE_STATUS_ERROR",
    redirect_over_budget = "PAGE_REDIRECT_CHAIN",
    transport_fail = "PAGE_FETCH_FAILED",
    incomplete = "PAGE_FETCH_FAILED",
    http_protocol_error = "PAGE_FETCH_FAILED"
  )
}

# Registry-conformant severity for a transport code (findings-registry.csv rows
# 76-80). The producer emits the CODE and looks the severity up here so it can
# never diverge from the registry; a registry severity change is a coordinated
# migration, not a silent edit to this map.
page_code_severity <- function(code) {
  sev <- c(
    PAGE_FETCH_FAILED = "error",
    PAGE_SSRF_BLOCKED = "error",
    PAGE_STATUS_ERROR = "error",
    PAGE_STATUS_REDIRECT = "warning",
    PAGE_REDIRECT_CHAIN = "info"
  )
  unname(sev[[code]])
}

# Did this fetch resolve a redirect? TRUE when a terminal response was reached
# (final_url present) and the final URL differs from the requested URL under the
# shared §5.2/ADR-005 canonical-identity rule (build_loc_key over the parsed
# form: scheme/host lowercasing, default-port removal, dot-segment and
# percent-encoding normalization). A same-canonical redirect (only case/port
# changed) is NOT a mismatch.
page_is_redirect <- function(art) {
  final <- art$final_url
  requested <- art$requested_url
  if (is.na(final) || is.na(requested)) {
    return(FALSE)
  }
  keys <- build_loc_key(parse_url_adapter(c(requested, final)))
  !identical(keys[[1L]], keys[[2L]])
}

# The single transport code for one artifact, or NA when the outcome emits no
# transport finding (usable_body / partial with no redirect, not_applicable).
page_outcome_code <- function(art) {
  outcome <- art$outcome
  map <- page_outcome_code_map()
  if (outcome %in% names(map)) {
    return(unname(map[[outcome]]))
  }
  if (outcome %in% c("usable_body", "partial") && page_is_redirect(art)) {
    return("PAGE_STATUS_REDIRECT")
  }
  NA_character_
}

# The terminal HTTP status of a fetch: the status of the last hop, or NA when no
# HTTP response was reached (safety refusal, transport failure).
page_terminal_status <- function(art) {
  n <- length(art$hops)
  if (n == 0L) {
    return(NA_integer_)
  }
  as.integer(art$hops[[n]]$status)
}

# Human-readable finding message (may change across patch releases).
page_message <- function(code, art, loc) {
  switch(
    code,
    PAGE_STATUS_ERROR = sprintf(
      "Advertised page %s returned HTTP %s.",
      loc,
      page_terminal_status(art)
    ),
    PAGE_STATUS_REDIRECT = sprintf(
      "Advertised page %s redirects to %s.",
      loc,
      art$final_url
    ),
    PAGE_REDIRECT_CHAIN = sprintf(
      "Advertised page %s exceeded the redirect budget (%d hops).",
      loc,
      length(art$hops)
    ),
    PAGE_FETCH_FAILED = sprintf(
      "Advertised page %s could not be fetched (%s).",
      loc,
      art$outcome
    ),
    PAGE_SSRF_BLOCKED = sprintf(
      "Advertised page %s was refused by the SSRF / safety guard.",
      loc
    )
  )
}

# The `evidence$excerpt` primary fact. On the pure sitemaps.org baseline (no
# engine `context` column) this is the ONLY place the status/target survives, so
# a baseline user still reads e.g. "HTTP 404" (§0.7).
page_excerpt <- function(code, art) {
  switch(
    code,
    PAGE_STATUS_ERROR = sprintf("HTTP %s", page_terminal_status(art)),
    PAGE_STATUS_REDIRECT = sprintf("redirect -> %s", art$final_url),
    PAGE_REDIRECT_CHAIN = sprintf("redirect chain: %d hops", length(art$hops)),
    PAGE_FETCH_FAILED = art$outcome,
    PAGE_SSRF_BLOCKED = art$outcome
  )
}

# The structured per-finding page context (§0.7): status code, final URL, hop
# count, raw outcome. It rides the engine-aware `context` list-column and is
# MERGED by the assembler under an engine ruleset; on the baseline path it is
# dropped at the ten-column re-impose (the excerpt above carries the fact).
page_context <- function(art) {
  list(
    page_outcome = art$outcome,
    page_status = page_terminal_status(art),
    page_final_url = art$final_url,
    page_hop_count = length(art$hops)
  )
}

# The page-url subject_ref for a page finding: the advertising sitemap's base
# with a `#page-url:<loc>` fragment (findings-contract.md "Subject ref format"),
# so the finding stays anchored to the document that advertised the page.
page_subject_ref <- function(base, loc) {
  protocol_ref_fragment(base, paste0("#page-url:", loc))
}

# Construct the page-layer findings tibble: the contract-shaped producer subset
# every producer emits (`code, severity, layer, subject_type, subject_ref,
# message, evidence, is_strict_only`) plus the optional engine-aware `context`
# list-column (findings_producer_optional_cols()). The single place the page
# producer's column shape is defined.
page_findings <- function(
  code = character(0),
  severity = character(0),
  subject_ref = character(0),
  message = character(0),
  evidence = list(),
  context = list(),
  is_strict_only = logical(0)
) {
  n <- length(code)
  tibble::tibble(
    code = as.character(code),
    severity = as.character(severity),
    layer = rep("page", n),
    subject_type = rep("page-url", n),
    subject_ref = as.character(subject_ref),
    message = as.character(message),
    evidence = if (length(evidence) > 0L) evidence else vector("list", n),
    context = if (length(context) > 0L) context else vector("list", n),
    is_strict_only = as.logical(is_strict_only)
  )
}

# A zero-row page-findings tibble (nothing advertised needed a transport
# finding, or nothing was inspected).
empty_page_findings <- function() {
  page_findings()
}

# One transport finding for a (code, artifact, advertised loc, base) tuple.
page_one_finding <- function(code, art, loc, base) {
  page_findings(
    code = code,
    severity = page_code_severity(code),
    subject_ref = page_subject_ref(base, loc),
    message = page_message(code, art, loc),
    evidence = list(finding_evidence(excerpt = page_excerpt(code, art))),
    context = list(page_context(art)),
    is_strict_only = FALSE
  )
}

# Map every advertised raw loc to its fetched artifact. `run$artifacts` is keyed
# by canonical fetch key and each entry retains the raw `advertised` locs that
# resolved to it, so a URL advertised by several sitemaps still finds its one
# shared artifact.
page_loc_artifact_map <- function(artifacts) {
  map <- list()
  for (entry in artifacts) {
    for (loc in entry$advertised) {
      map[[loc]] <- entry$artifact
    }
  }
  map
}

# The default (loc, base) subject set when the caller supplies none: every
# advertised loc anchored to its OWN page URL as the base. Used by direct
# producer tests; the validate integration passes the real advertising bases.
page_default_subjects <- function(run) {
  locs <- unlist(
    lapply(run$artifacts, function(e) e$advertised),
    use.names = FALSE
  )
  list(
    loc = locs,
    base = vapply(locs, sitemap_subject_ref, character(1), USE.NAMES = FALSE)
  )
}

# Produce the page-layer transport findings for a page_inspection_run. For each
# advertising subject (a raw advertised loc + the sitemap base that advertised
# it) it finds the shared artifact, maps its outcome to at most one transport
# code, and emits one finding per advertising subject_ref. `subjects` is a list
# of parallel `loc` / `base` vectors; NULL self-anchors each advertised loc.
# Returns the producer shape (8 cols + context; zero rows when nothing maps).
page_transport_findings <- function(run, subjects = NULL) {
  artifacts <- run$artifacts
  if (length(artifacts) == 0L) {
    return(empty_page_findings())
  }
  if (is.null(subjects)) {
    subjects <- page_default_subjects(run)
  }
  loc_art <- page_loc_artifact_map(artifacts)
  out <- list()
  for (i in seq_along(subjects$loc)) {
    loc <- subjects$loc[[i]]
    art <- loc_art[[loc]]
    if (is.null(art)) {
      next
    }
    code <- page_outcome_code(art)
    if (is.na(code)) {
      next
    }
    out[[length(out) + 1L]] <- page_one_finding(
      code,
      art,
      loc,
      subjects$base[[i]]
    )
  }
  if (length(out) == 0L) {
    return(empty_page_findings())
  }
  do.call(rbind, out)
}

# The schema version stamped on the coverage attribute so a reader can pin the
# shape it consumes (§0.11 "version the attribute").
page_coverage_schema_version <- function() {
  1L
}

# Shape the batch-wide coverage metadata for `attr(x, "page_coverage")` (§6.2).
# Batch-wide: one summary per validate call over the union of the call's deduped
# locs (§0.11). Versioned + scope-tagged, then the run's coverage bookkeeping
# (eligible / deduplicated / selected / attempted / completed / partial /
# caps_hit and the run tallies). Not findings rows: a run's self-coverage is a
# property of the run, not of the sitemap.
page_coverage_attr <- function(coverage) {
  c(
    list(
      schema_version = page_coverage_schema_version(),
      scope = "batch"
    ),
    coverage
  )
}

# Drive one batch-wide page-inspection pass over the advertised locs a validate
# call gathered (`sink`), fold the transport findings into the assembled base
# result, and stamp the coverage attribute. Called only when inspect_pages is
# on; the base result and the page findings are assembled + combined under the
# same `ruleset` so the column set (baseline ten / engine fourteen) matches.
page_inspection_finalize <- function(
  base,
  sink,
  mode,
  ruleset,
  budget,
  sample_size,
  page_mode,
  user_agent,
  limits,
  policy
) {
  run <- page_inspection_run(
    locs = sink$loc,
    budget = budget,
    sample_size = sample_size,
    mode = page_mode,
    user_agent = user_agent,
    limits = limits,
    policy = policy
  )
  subjects <- list(loc = sink$loc, base = sink$base, alt = sink$alt)
  # Sibling producers over the same run: transport (this file) on the failed /
  # redirect outcomes, canonical (R/page-canonical.R) + hreflang
  # (R/page-hreflang.R) on the usable_body / partial outcomes. They join one
  # `parts` list so the assembler stamps one ruleset/mode over each page-layer
  # finding (baseline ten / engine 14). Only hreflang reads `subjects$alt` (the
  # sitemap-declared alternates); transport / canonical ignore it.
  parts <- list(
    page_transport_findings(run, subjects = subjects),
    page_canonical_findings(run, subjects = subjects),
    page_hreflang_findings(run, subjects = subjects)
  )
  page <- assemble_findings(parts, mode, ruleset)
  result <- combine_findings_contracts(list(base, page), ruleset)
  attr(result, "page_coverage") <- page_coverage_attr(run$coverage)
  result
}
