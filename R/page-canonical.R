# Page canonical extraction + mismatch/missing finding producer (Layer E,
# Contract B extraction + Contract C interpretation; E.2). Internal only.
#
# A SIBLING producer to R/page-findings.R (transport): it consumes the same
# page_inspection_run() artifacts, but on the usable_body / partial outcomes the
# transport producer leaves alone. It NEVER fetches, never modifies
# page_fetch()/page_inspection_run()/the assembler. It reuses page-findings.R's
# producer shape (page_findings/empty_page_findings), subject_ref anchor
# (page_url_subject_ref), and loc->artifact map (page_loc_artifact_map).
#
# Governing contracts (conform, do not restate):
#   docs/design/layer-e-page-inspection.md
#     §4   Contract B — pure extraction + the observed/absent/unknown/
#          not_applicable extraction-status enum (an absence finding fires ONLY
#          on `absent`, never `unknown`)
#     §5.2 Contract C — canonical interpretation: extract from BOTH channels
#          (<link rel=canonical> and the `Link` header), the shared ADR-005
#          URL-identity rule (fragment dropped), and the softened "consistency
#          diagnostic, not the sitemap is wrong" framing
#     §0.7 per-finding context / baseline excerpt collapse
#   docs/findings-registry.csv  PAGE_CANONICAL_MISMATCH (warning) /
#     PAGE_CANONICAL_MISSING (info) / PAGE_CANONICAL_RELATIVE (info) — the
#     producer emits the CODE; severity conforms to the row.
#
# Emission (§5.2, per advertised loc, on a usable_body / partial artifact):
#   status observed, page canonical key != advertised loc key -> MISMATCH (warn)
#   status observed, page canonical agrees with the loc        -> no finding
#   status absent  (complete HTML body, no canonical at all)   -> MISSING (info)
#   status unknown (partial body, none seen) / not_applicable  -> no finding
#     (softened by the §1 unrendered-snapshot caveat — a truncated head or a
#      non-HTML body is not evidence of absence).
# and INDEPENDENTLY of the consistency verdict above:
#   status observed, any occurrence declared relative       -> RELATIVE (info)
#     — an interpretation of the §4 `relative` fact, so a consistent page can
#     still carry it and an inconsistent one earns both codes.

# Registry-conformant severity for a canonical code (findings-registry.csv). The
# producer emits the CODE and looks the severity up here so it can never diverge
# from the registry; a registry severity change is a coordinated migration.
page_canonical_severity <- function(code) {
  sev <- c(
    PAGE_CANONICAL_MISMATCH = "warning",
    PAGE_CANONICAL_MISSING = "info",
    PAGE_CANONICAL_RELATIVE = "info"
  )
  unname(sev[[code]])
}

# Is a raw canonical target a RELATIVE reference? True when it carries no
# scheme, which is the §4 `relative` fact — recorded, never interpreted, here.
#
# The test is the lexical one RFC 3986 §3.1 defines: a scheme is an ASCII letter
# followed by letters/digits/`+`/`-`/`.`, terminated by `:`. So `/b`, `//host/b`
# and `example.com/b` are all relative (the last has no colon at all), while
# `https://host/b` and `example.com:8080/b` are not — in the second the leading
# token IS a scheme by the grammar, ambiguous as that reads.
#
# Deliberately NOT parse_url_adapter()$scheme: rurl INFERS `http` for a
# scheme-less `example.com/b`, which is the right answer for an advertised loc
# and the wrong one for this fact. The lexical test also matches the sibling
# TypeScript port, where `new URL(raw)` throws for exactly these forms.
page_canonical_is_relative <- function(raw) {
  raw <- trimws(as.character(raw))
  if (length(raw) == 0L || is.na(raw) || !nzchar(raw)) {
    return(NA)
  }
  !grepl("^[A-Za-z][A-Za-z0-9+.-]*:", raw)
}

# The fragment of a raw canonical target, or NA when it carries none (§4 "any
# fragment"). An empty fragment (`/b#`) is recorded as "" — the delimiter was
# present. The fragment is a fact only: ADR-005 drops it from the comparison
# key, so it never changes a consistency verdict.
page_canonical_fragment <- function(raw) {
  raw <- trimws(as.character(raw))
  if (length(raw) == 0L || is.na(raw) || !grepl("#", raw, fixed = TRUE)) {
    return(NA_character_)
  }
  sub("^[^#]*#", "", raw)
}

# Does the terminal response declare an HTML content type? Read from the
# case-insensitive Content-Type header. Only an HTML body can be `absent` of an
# on-page canonical (a non-HTML file legitimately has none -> not_applicable, no
# MISSING). A missing/blank Content-Type is treated as HTML (the fetch reached a
# usable body and we parse it as markup).
page_content_is_html <- function(art) {
  ctype <- page_header_values(art$terminal_headers, "Content-Type")
  if (length(ctype) == 0L) {
    return(TRUE)
  }
  any(grepl("html", tolower(ctype), fixed = TRUE))
}

# Resolve a raw href against the response base (final_url, or a <base href> when
# present). Relative targets resolve to absolute; an already-absolute target is
# returned unchanged. Returns NA for an unresolvable / empty target.
page_canonical_resolve <- function(raw, base) {
  raw <- trimws(as.character(raw))
  if (length(raw) == 0L || is.na(raw) || !nzchar(raw)) {
    return(NA_character_)
  }
  out <- tryCatch(
    xml2::url_absolute(raw, base),
    error = function(e) NA_character_
  )
  if (length(out) == 0L || is.na(out) || !nzchar(out)) {
    return(NA_character_)
  }
  out
}

# Raw canonical targets declared in the `Link` response header(s): the URI of
# every link-value whose `rel` includes the `canonical` relation type. Parsing
# is delegated to the shared RFC 8288 parser (R/page-link-header.R), which reads
# `rel` as the whitespace-separated token LIST it is — so an order-swapped
# `rel="alternate canonical"` counts, and a merely canonical-PREFIXED type
# (`rel="canonical-ish"`) does not invent a target. Repeated headers are all
# consulted.
page_link_header_canonicals <- function(headers) {
  entries <- page_link_header_entries(headers)
  keep <- vapply(entries, page_link_has_rel, logical(1), rel = "canonical")
  vapply(entries[keep], function(e) e$uri, character(1))
}

# Raw canonical targets + the effective base declared in the HTML head:
# every <link rel=canonical> href (rel matched case-insensitively), resolved
# against a <base href> when the head declares one, else the response final_url.
# Malformed / non-HTML bodies parse leniently; a parse failure yields none.
page_html_canonicals <- function(body, final_url) {
  if (length(body) == 0L) {
    return(list(base = final_url, targets = character(0)))
  }
  doc <- tryCatch(
    xml2::read_html(body),
    error = function(e) NULL
  )
  if (is.null(doc)) {
    return(list(base = final_url, targets = character(0)))
  }
  base_href <- xml2::xml_attr(
    xml2::xml_find_first(doc, "//base[@href]"),
    "href"
  )
  base <- if (!is.na(base_href) && nzchar(base_href)) {
    page_canonical_resolve(base_href, final_url)
  } else {
    final_url
  }
  if (is.na(base)) {
    base <- final_url
  }
  links <- xml2::xml_find_all(doc, "//link[@rel and @href]")
  if (length(links) == 0L) {
    return(list(base = base, targets = character(0)))
  }
  rel <- tolower(trimws(xml2::xml_attr(links, "rel")))
  href <- xml2::xml_attr(links[rel == "canonical"], "href")
  list(base = base, targets = as.character(href))
}

# Extract the canonical facts + extraction status for one artifact (§4/§5.2).
# Returns a list: `status` (observed/absent/unknown/not_applicable) and
# `facts` — one record per occurrence, carrying the §4 fact set:
# channel/raw/relative/fragment/resolved. Extraction runs
# only on the usable-body / partial outcomes (a failed/redirect/refused fetch
# has no body to read); any other outcome is not_applicable.
page_canonical_extract <- function(art) {
  na <- list(status = "not_applicable", facts = list())
  if (!art$outcome %in% c("usable_body", "partial")) {
    return(na)
  }
  html <- page_html_canonicals(art$body, art$final_url)
  http_raw <- page_link_header_canonicals(art$terminal_headers)

  facts <- list()
  for (raw in html$targets) {
    facts[[length(facts) + 1L]] <- list(
      channel = "html_link",
      raw = raw,
      relative = page_canonical_is_relative(raw),
      fragment = page_canonical_fragment(raw),
      resolved = page_canonical_resolve(raw, html$base)
    )
  }
  for (raw in http_raw) {
    facts[[length(facts) + 1L]] <- list(
      channel = "http_link",
      raw = raw,
      relative = page_canonical_is_relative(raw),
      fragment = page_canonical_fragment(raw),
      resolved = page_canonical_resolve(raw, art$final_url)
    )
  }

  resolved <- vapply(facts, function(f) f$resolved, character(1))
  resolved <- resolved[!is.na(resolved)]
  if (length(resolved) > 0L) {
    return(list(status = "observed", facts = facts))
  }
  # No usable canonical seen. A complete HTML body genuinely declares none
  # (`absent`); a truncated body or a non-HTML file is `unknown` /
  # `not_applicable` — never manufacture an absence finding from those.
  status <- if (identical(art$outcome, "partial")) {
    "unknown"
  } else if (page_content_is_html(art)) {
    "absent"
  } else {
    "not_applicable"
  }
  list(status = status, facts = facts)
}

# The distinct resolved canonical targets of an extraction (order preserved).
page_canonical_targets <- function(extract) {
  resolved <- vapply(extract$facts, function(f) f$resolved, character(1))
  unique(resolved[!is.na(resolved)])
}

# The structured per-finding context (§0.7): the loc the finding is about, the
# resolved canonical target(s), and the raw/channel facts. Rides the engine
# `context` list-column (merged by the assembler under a ruleset); dropped on
# the baseline ten-column re-impose (the excerpt below carries the fact).
page_canonical_context <- function(loc, targets, extract) {
  list(
    page_canonical_loc = loc,
    page_canonical_targets = targets,
    page_canonical_facts = extract$facts
  )
}

# The consistency finding for one extraction, or NULL when the page's canonical
# agrees with the loc (or is unobservable). The comparison uses the shared
# ADR-005 canonical key (build_loc_key, fragment dropped): consistent iff the
# page declares exactly one canonical target and its key equals the loc's.
page_canonical_consistency_finding <- function(extract, loc, base) {
  if (identical(extract$status, "absent")) {
    return(page_findings(
      code = "PAGE_CANONICAL_MISSING",
      severity = page_canonical_severity("PAGE_CANONICAL_MISSING"),
      subject_ref = page_url_subject_ref(base, loc),
      message = sprintf(
        "Advertised page %s declares no rel=canonical.",
        loc
      ),
      evidence = list(finding_evidence(excerpt = "no rel=canonical")),
      context = list(page_canonical_context(loc, character(0), extract)),
      is_strict_only = FALSE
    ))
  }
  if (!identical(extract$status, "observed")) {
    return(NULL)
  }
  targets <- page_canonical_targets(extract)
  loc_key <- build_loc_key(parse_url_adapter(loc))
  target_keys <- build_loc_key(parse_url_adapter(targets))
  consistent <- length(target_keys) == 1L &&
    identical(target_keys[[1L]], loc_key[[1L]])
  if (consistent) {
    return(NULL)
  }
  preferred <- targets[[which(target_keys != loc_key[[1L]])[[1L]]]]
  page_findings(
    code = "PAGE_CANONICAL_MISMATCH",
    severity = page_canonical_severity("PAGE_CANONICAL_MISMATCH"),
    subject_ref = page_url_subject_ref(base, loc),
    message = sprintf(
      "Advertised page %s prefers a different canonical: %s.",
      loc,
      preferred
    ),
    evidence = list(finding_evidence(
      excerpt = sprintf("canonical -> %s", preferred)
    )),
    context = list(page_canonical_context(loc, targets, extract)),
    is_strict_only = FALSE
  )
}

# The relative-form diagnostic for one extraction, or NULL. Fires when a
# canonical was OBSERVED and at least one occurrence was declared as a relative
# reference (the §4 `relative` fact).
#
# This INTERPRETS a fact §4 already mandates; it is not a new signal. It is also
# independent of the consistency verdict above: a relative canonical resolving
# to exactly the advertised loc is consistent and still worth reporting, and one
# resolving elsewhere earns both codes.
#
# Ruleset framing (ADR-009, SITE-eoqgkcij): canonical is not a sitemaps.org
# concept, so this is a baseline consistency diagnostic carrying NO engine
# verdict. Severity is `info`, matching PAGE_CANONICAL_MISSING — Google resolves
# relative canonicals exactly as a browser does, so the form is advice, not a
# defect. Their canonicalization doc is nonetheless explicit ("Use absolute
# paths rather than relative paths with the rel=canonical link element"), the
# failure it warns about being a crawled staging copy canonicalizing to itself
# instead of to production.
#
# Ported from the sibling TypeScript implementation, where the code originated
# (checkCanonicalAbsolute, src/lib/services/inspection/checks/canonical.ts).
page_canonical_relative_finding <- function(extract, loc, base) {
  if (!identical(extract$status, "observed")) {
    return(NULL)
  }
  rel <- vapply(
    extract$facts,
    function(f) isTRUE(f$relative),
    logical(1)
  )
  if (!any(rel)) {
    return(NULL)
  }
  raw <- extract$facts[[which(rel)[[1L]]]]$raw
  page_findings(
    code = "PAGE_CANONICAL_RELATIVE",
    severity = page_canonical_severity("PAGE_CANONICAL_RELATIVE"),
    subject_ref = page_url_subject_ref(base, loc),
    message = sprintf(
      "Advertised page %s declares its canonical as a relative reference: %s.",
      loc,
      raw
    ),
    evidence = list(finding_evidence(
      excerpt = sprintf("canonical (relative) -> %s", raw)
    )),
    context = list(page_canonical_context(
      loc,
      page_canonical_targets(extract),
      extract
    )),
    is_strict_only = FALSE
  )
}

# The canonical findings for a (artifact, advertised loc, base) tuple: at most
# one consistency finding (MISSING / MISMATCH) plus an optional relative-form
# diagnostic, so up to two rows. NULL when the page is consistent and declared
# nothing relative, or when the canonical is unobservable.
page_canonical_one_finding <- function(art, loc, base) {
  extract <- page_canonical_extract(art)
  rows <- list(
    page_canonical_consistency_finding(extract, loc, base),
    page_canonical_relative_finding(extract, loc, base)
  )
  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (length(rows) == 0L) {
    return(NULL)
  }
  do.call(rbind, rows)
}

# Produce the page-layer canonical findings for a page_inspection_run. Mirrors
# page_transport_findings(): for each advertising subject (a raw advertised loc
# + the sitemap base that advertised it) it finds the shared artifact and emits
# its canonical findings. `subjects` is a list of parallel `loc` / `base`
# vectors; NULL self-anchors each advertised loc. Returns the producer shape
# (8 cols + context; zero rows when nothing maps).
page_canonical_findings <- function(run, subjects = NULL) {
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
    finding <- page_canonical_one_finding(art, loc, subjects$base[[i]])
    if (is.null(finding)) {
      next
    }
    out[[length(out) + 1L]] <- finding
  }
  if (length(out) == 0L) {
    return(empty_page_findings())
  }
  do.call(rbind, out)
}
