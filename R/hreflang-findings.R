# Whole-sitemap hreflang reciprocity / self-reference findings (Layer D
# semantic). Internal only.
#
# Layers finding POLICY on top of the pure hreflang cluster graph
# (`build_hreflang_graph()`, R/hreflang-graph.R), which this consumes
# READ-ONLY. It emits three whole-sitemap (cross-URL) findings over the
# alternate relationships the sitemap *declares* — derived offline from the
# sitemap bytes alone, never fetching the target pages. The live cross-page
# hreflang check (does the fetched page actually carry the return link?) is the
# separate, deferred Layer E `PAGE_HREFLANG_MISMATCH`; this producer stays
# strictly on the sitemap-declared graph so the two never overlap.
#
# All three are `layer = "protocol"`, `subject_type = "document"` (whole-sitemap
# / cross-URL) warnings: every individual link may be syntactically valid yet a
# search engine can still ignore an incomplete cluster.
#
#   * HREFLANG_MISSING_SELF_REFERENCE — a URL declares alternate-language links
#     but none of them points back at its own URL. Google requires every page
#     in an hreflang set to include a self-referencing link; without it the
#     whole set may be disregarded.
#   * HREFLANG_NON_RECIPROCAL — A links to B as an alternate but B does not link
#     back to A. Return links are mandatory; a one-way annotation is ignored.
#   * HREFLANG_INCONSISTENT_LANGUAGE — the same target URL is annotated with two
#     or more conflicting language tokens across the corpus (case-insensitively,
#     so a pure casing difference is left to HREFLANG_NONSTANDARD_CASE).
#
# CORPUS-BOUNDARY POLICY. Reciprocity can only be judged for a target the
# sitemap also submits (an `internal` graph node). When the target lies OUTSIDE
# the audited corpus (an `external` node) the sitemap cannot state B's return
# links, so reciprocity is UNKNOWN — never a violation. Such edges are EXCLUDED
# from the non-reciprocity check rather than flagged, so an alternate pointing
# at another host or another sitemap is not a false positive. Self-reference and
# language-consistency read only the corpus's own declarations, so they apply to
# external targets too.
#
# DETERMINISM. The graph is invariant to input row order; every emission here is
# keyed on canonical URL keys (never the positional input row), sorted before
# emission, so the finding set is identical across input permutations.

# The lexicographically-smallest raw string the graph retained for a node key
# (its deterministic representative), falling back to the key itself.
hreflang_node_raw <- function(nodes, key) {
  i <- match(key, nodes$url_key)
  if (is.na(i)) key else nodes$url_raw[[i]]
}

# HREFLANG_MISSING_SELF_REFERENCE: a source URL that declares href-bearing
# alternates but has no self-edge (an alternate resolving to its own key).
hreflang_missing_self_findings <- function(graph, base) {
  edges <- graph$edges
  sources <- unique(edges$source_key)
  self <- unique(edges$source_key[edges$source_key == edges$target_key])
  missing <- sort(setdiff(sources, self))
  lapply(missing, function(key) {
    raw <- hreflang_node_raw(graph$nodes, key)
    protocol_document_finding(
      "HREFLANG_MISSING_SELF_REFERENCE",
      "warning",
      base,
      sprintf(
        paste0(
          "URL %s declares hreflang alternates but none is a ",
          "self-referencing link back to its own URL."
        ),
        raw
      ),
      excerpt = raw
    )
  })
}

# Distinct (source, target) pairs eligible for the reciprocity check: not a
# self-edge, and the target is an internal (submitted) node. Sorted for
# determinism. Returns a two-column data frame (`s`, `t`).
hreflang_reciprocity_pairs <- function(edges, internal_keys) {
  keep <- edges$source_key != edges$target_key &
    edges$target_key %in% internal_keys
  s <- edges$source_key[keep]
  t <- edges$target_key[keep]
  pk <- paste(s, t, sep = "\x1f")
  first <- !duplicated(pk)
  s <- s[first]
  t <- t[first]
  ord <- order(s, t)
  data.frame(s = s[ord], t = t[ord], stringsAsFactors = FALSE)
}

# HREFLANG_NON_RECIPROCAL: an internal-target edge A->B with no matching return
# edge B->A. External targets are excluded upstream (corpus-boundary policy).
hreflang_reciprocity_findings <- function(graph, base) {
  nodes <- graph$nodes
  edges <- graph$edges
  internal <- nodes$url_key[nodes$node_kind == "internal"]
  pairs <- hreflang_reciprocity_pairs(edges, internal)
  present <- paste(edges$source_key, edges$target_key, sep = "\x1f")
  out <- list()
  for (r in seq_len(nrow(pairs))) {
    if (paste(pairs$t[r], pairs$s[r], sep = "\x1f") %in% present) {
      next
    }
    a <- hreflang_node_raw(nodes, pairs$s[r])
    b <- hreflang_node_raw(nodes, pairs$t[r])
    out[[length(out) + 1L]] <- protocol_document_finding(
      "HREFLANG_NON_RECIPROCAL",
      "warning",
      base,
      sprintf(
        paste0(
          "URL %s links to %s as a hreflang alternate, but %s does not ",
          "declare a reciprocal alternate back to %s."
        ),
        a,
        b,
        b,
        a
      ),
      excerpt = sprintf("%s -> %s", a, b)
    )
  }
  out
}

# One inconsistent-language finding for a target carrying conflicting tokens.
hreflang_inconsistent_finding <- function(graph, base, key, tokens) {
  raw <- hreflang_node_raw(graph$nodes, key)
  labelled <- paste0("'", sort(unique(tokens)), "'", collapse = ", ")
  protocol_document_finding(
    "HREFLANG_INCONSISTENT_LANGUAGE",
    "warning",
    base,
    sprintf(
      paste0(
        "Target URL %s is annotated with conflicting hreflang tokens across ",
        "the sitemap: %s."
      ),
      raw,
      labelled
    ),
    excerpt = raw
  )
}

# HREFLANG_INCONSISTENT_LANGUAGE: a target key referenced with two or more
# distinct language tokens. Blank/absent tokens are ignored (those are per-link
# concerns); comparison is case-insensitive so pure casing variance does not
# count as a language conflict.
hreflang_inconsistent_findings <- function(graph, base) {
  edges <- graph$edges
  tok <- trimws(edges$hreflang)
  have <- !is.na(tok) & nzchar(tok)
  if (!any(have)) {
    return(list())
  }
  by_target <- split(tok[have], edges$target_key[have])
  targets <- sort(names(by_target))
  out <- list()
  for (key in targets) {
    tokens <- by_target[[key]]
    if (length(unique(tolower(tokens))) < 2L) {
      next
    }
    out[[length(out) + 1L]] <-
      hreflang_inconsistent_finding(graph, base, key, tokens)
  }
  out
}

# Emit the whole-sitemap hreflang findings for a faithful row tibble.
#
# Consumes `build_hreflang_graph(rows)` read-only and returns a protocol-layer
# findings tibble (the same shape the other Layer D producers emit; `mode` and
# `remediation_hint` are added by Layer F). Zero rows when the corpus declares
# no hreflang alternates or every cluster is complete.
#
# @param rows A faithful row tibble with `loc` and an `alternates` list-column
#   (as consumed by `build_hreflang_graph()`).
# @param base The document-level `sitemap://...` subject_ref for each finding.
#   `NA` yields fragment-less document refs.
# @return A findings tibble (`layer = "protocol"`, `subject_type = "document"`).
# @keywords internal
# @noRd
validate_hreflang_graph <- function(rows, base = NA_character_) {
  graph <- build_hreflang_graph(rows)
  if (nrow(graph$edges) == 0L) {
    return(empty_protocol_findings())
  }
  out <- c(
    hreflang_missing_self_findings(graph, base),
    hreflang_reciprocity_findings(graph, base),
    hreflang_inconsistent_findings(graph, base)
  )
  if (length(out) == 0L) {
    return(empty_protocol_findings())
  }
  do.call(rbind, out)
}
