# Page hreflang reconciliation finding producer (Layer E, Contract B extraction
# + Contract C interpretation; E.4). Internal only.
#
# A SIBLING producer to R/page-findings.R (transport) and R/page-canonical.R: it
# consumes the same page_inspection_run() artifacts on the usable_body / partial
# outcomes and emits PAGE_HREFLANG_MISMATCH. It reconciles the PAGE-declared
# hreflang alternate set (parsed from the fetched head) against the SITEMAP-
# declared set for the same URL (the `alternates` list-column threaded onto each
# advertising subject as `subjects$alt`). It NEVER fetches, never modifies the
# spine or the assembler, and reuses page-findings.R's producer shape.
#
# This is DELIBERATELY NOT the Layer-D whole-corpus reciprocity graph
# (build_hreflang_graph(), R/hreflang-graph.R): that graph is built over the
# COMPLETE corpus and is unsafe over a page SAMPLE (an incomplete graph would
# manufacture false "no return tag" findings). E.4 is a per-inspected-page
# set-vs-set reconciliation only.
#
# Governing contracts (conform, do not restate):
#   docs/design/layer-e-page-inspection.md
#     §4   Contract B — pure extraction + the observed/absent/unknown/
#          not_applicable extraction-status enum
#     §5.3 Contract C — hreflang reconciliation: a CONSISTENCY check, not a
#          presence check. Emit ONLY when the page status is `observed` AND the
#          two NON-EMPTY sets disagree under ADR-005 identity (case-insensitive
#          BCP-47 tag + canonical-key href). An empty page set against a
#          populated sitemap set is NOT a mismatch (methods are equivalent).
#     §5.2 the shared ADR-005 URL-identity rule (fragment dropped)
#     §0.7 per-finding context / baseline excerpt collapse
#   docs/findings-registry.csv  PAGE_HREFLANG_MISMATCH (warning) — the producer
#     emits the CODE; severity conforms to the row.

# Registry-conformant severity. The producer emits the CODE and looks the
# severity up here so it can never diverge from the registry.
page_hreflang_severity <- function(code) {
  sev <- c(PAGE_HREFLANG_MISMATCH = "warning")
  unname(sev[[code]])
}

# Normalize a list of (tag, href) alternate links to a SET of comparable keys
# under the §5.2/§5.3 identity rule: case-insensitive BCP-47 tag + the ADR-005
# canonical key of the resolved href (fragment dropped). Relatives resolve
# against `base`. A link with a blank tag or an unresolvable href is dropped.
# The tab-joined "tag<TAB>key" strings are compared with setequal().
page_hreflang_norm_set <- function(links, base) {
  keys <- character(0)
  for (link in links) {
    tag <- tolower(trimws(as.character(link$tag)))
    resolved <- page_canonical_resolve(link$href, base)
    if (!nzchar(tag) || is.na(resolved)) {
      next
    }
    key <- build_loc_key(parse_url_adapter(resolved))[[1L]]
    keys <- c(keys, paste(tag, key, sep = "\t"))
  }
  unique(keys)
}

# The page-declared hreflang alternates + the effective base from the fetched
# HTML head: every <link rel=alternate hreflang=.. href=..> (rel matched
# case-insensitively), resolved against a <base href> when present, else the
# response final_url. A parse failure / non-HTML body yields none.
page_hreflang_html_links <- function(body, final_url) {
  if (length(body) == 0L) {
    return(list(base = final_url, links = list()))
  }
  doc <- tryCatch(xml2::read_html(body), error = function(e) NULL)
  if (is.null(doc)) {
    return(list(base = final_url, links = list()))
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
  nodes <- xml2::xml_find_all(doc, "//link[@rel and @href and @hreflang]")
  if (length(nodes) == 0L) {
    return(list(base = base, links = list()))
  }
  rel <- tolower(trimws(xml2::xml_attr(nodes, "rel")))
  keep <- rel == "alternate"
  tags <- xml2::xml_attr(nodes[keep], "hreflang")
  hrefs <- xml2::xml_attr(nodes[keep], "href")
  links <- Map(function(t, h) list(tag = t, href = h), tags, hrefs)
  list(base = base, links = links)
}

# Extract the page hreflang set + extraction status (§4/§5.3). Runs only on the
# usable_body / partial outcomes (any other has no body). `observed` when the
# page declares at least one usable alternate; otherwise `absent` (complete HTML
# body), `unknown` (partial), or `not_applicable` (non-HTML / no body). Also
# records whether the page carries a self-referential alternate (a fact).
page_hreflang_extract <- function(art) {
  none <- list(status = "not_applicable", set = character(0), self_ref = FALSE)
  if (!art$outcome %in% c("usable_body", "partial")) {
    return(none)
  }
  # A `partial` body may be truncated mid-head, so its alternate SET is
  # incomplete for a set-vs-set reconciliation (a locale below the cut would
  # read as a spurious page/sitemap disagreement). Unlike a single canonical
  # value, an incomplete SET is unsafe -> `unknown`, never a verdict (§4).
  if (identical(art$outcome, "partial")) {
    return(list(status = "unknown", set = character(0), self_ref = FALSE))
  }
  html <- page_hreflang_html_links(art$body, art$final_url)
  set <- page_hreflang_norm_set(html$links, html$base)
  if (length(set) > 0L) {
    self_key <- build_loc_key(parse_url_adapter(art$final_url))[[1L]]
    hrefs <- vapply(
      strsplit(set, "\t", fixed = TRUE),
      function(p) p[[2L]],
      character(1)
    )
    return(list(
      status = "observed",
      set = set,
      self_ref = any(hrefs == self_key)
    ))
  }
  status <- if (page_content_is_html(art)) "absent" else "not_applicable"
  list(status = status, set = character(0), self_ref = FALSE)
}

# The sitemap-declared hreflang set for one loc, from its `alternates`
# list-column entry (each an <xhtml:link> carrying rel/hreflang/href attributes,
# read via the shared hreflang_link_attrs()). Links with no href / no hreflang,
# or a rel that is present and not "alternate", are dropped. Relatives resolve
# against the loc. Returns the same normalized "tag<TAB>key" set.
page_hreflang_declared_set <- function(alt, loc) {
  if (is.null(alt) || length(alt) == 0L) {
    return(character(0))
  }
  links <- list()
  for (entry in alt) {
    a <- hreflang_link_attrs(entry)
    if (is.null(a$href) || is.null(a$hreflang)) {
      next
    }
    rel <- if (is.null(a$rel)) NA_character_ else tolower(trimws(a$rel))
    if (!is.na(rel) && rel != "alternate") {
      next
    }
    links[[length(links) + 1L]] <- list(tag = a$hreflang, href = a$href)
  }
  page_hreflang_norm_set(links, loc)
}

# The structured per-finding context (§0.7): the loc, the page-declared set, the
# sitemap-declared set, and the page self-reference flag. Rides the engine
# `context` list-column; dropped on the baseline re-impose (the excerpt carries
# the human fact).
page_hreflang_context <- function(loc, page_set, sitemap_set, self_ref) {
  list(
    page_hreflang_loc = loc,
    page_hreflang_page = page_set,
    page_hreflang_sitemap = sitemap_set,
    page_hreflang_self_ref = self_ref
  )
}

# One hreflang finding for a (artifact, advertised loc, base, declared-alt)
# tuple, or NULL. Emits PAGE_HREFLANG_MISMATCH ONLY when the page status is
# `observed` AND both the page set and the sitemap set are NON-EMPTY AND they
# disagree under the identity rule. An empty page set (unknown/absent) or an
# empty sitemap set is the explicitly-excused equivalent-methods case — never a
# finding (§5.3).
page_hreflang_one_finding <- function(art, loc, base, alt) {
  extract <- page_hreflang_extract(art)
  if (!identical(extract$status, "observed")) {
    return(NULL)
  }
  page_set <- extract$set
  sitemap_set <- page_hreflang_declared_set(alt, loc)
  if (length(sitemap_set) == 0L || setequal(page_set, sitemap_set)) {
    return(NULL)
  }
  page_findings(
    code = "PAGE_HREFLANG_MISMATCH",
    severity = page_hreflang_severity("PAGE_HREFLANG_MISMATCH"),
    subject_ref = page_subject_ref(base, loc),
    message = sprintf(
      "Advertised page %s declares hreflang alternates that differ %s",
      loc,
      "from the sitemap."
    ),
    evidence = list(finding_evidence(
      excerpt = sprintf(
        "page %d vs sitemap %d hreflang alternates",
        length(page_set),
        length(sitemap_set)
      )
    )),
    context = list(page_hreflang_context(
      loc,
      page_set,
      sitemap_set,
      extract$self_ref
    )),
    is_strict_only = FALSE
  )
}

# Produce the page-layer hreflang findings for a page_inspection_run. Mirrors
# page_transport_findings() / page_canonical_findings(): for each advertising
# subject (a raw advertised loc + its sitemap base + the sitemap-declared
# alternates for that occurrence) it finds the shared artifact and emits at most
# one hreflang finding. NULL subjects self-anchor each advertised loc with no
# declared alternates (so the direct-producer path never fires a mismatch).
page_hreflang_findings <- function(run, subjects = NULL) {
  artifacts <- run$artifacts
  if (length(artifacts) == 0L) {
    return(empty_page_findings())
  }
  if (is.null(subjects)) {
    subjects <- page_default_subjects(run)
  }
  alt_list <- subjects$alt
  loc_art <- page_loc_artifact_map(artifacts)
  out <- list()
  for (i in seq_along(subjects$loc)) {
    loc <- subjects$loc[[i]]
    art <- loc_art[[loc]]
    if (is.null(art)) {
      next
    }
    alt <- if (is.null(alt_list)) NULL else alt_list[[i]]
    finding <- page_hreflang_one_finding(art, loc, subjects$base[[i]], alt)
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
