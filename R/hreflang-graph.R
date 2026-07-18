# Whole-sitemap hreflang cluster graph (pure primitive; Layer D).
#
# Internal only. `build_hreflang_graph()` consumes a `read_sitemap()`-style row
# tibble (the faithful form, `R/parse-rows.R`) and builds a deterministic graph
# of the hreflang alternate relationships declared *inside the sitemap corpus
# itself*. It is a PURE data structure: no network access, no finding/severity/
# remediation policy. The findings unit (SITE-qieygvlo) layers policy on top of
# this structure; keeping the two apart means the graph is testable in isolation
# and re-usable.
#
# What the structure captures:
#   * one directed EDGE per declared `<xhtml:link rel="alternate">` that carries
#     an href: source `<loc>` -> target href, tagged with the hreflang token and
#     backed by the raw evidence (which row declared it, the raw href/loc/rel);
#   * duplicate edges (same source/target/token) COLLAPSE to a single edge that
#     retains every raw occurrence as evidence;
#   * NODES for every URL that participates in an edge, each flagged
#     `"internal"` (its canonical key is a submitted `<loc>`) or `"external"`
#     (the alternate points outside the submitted corpus) — external targets are
#     represented explicitly, never dropped;
#   * CLUSTERS: connected components of the undirected alternate relation, with
#     ids relabelled so they are stable across input row order.
#
# Identity: every URL (source `<loc>` and target href alike) is keyed through
# the shared sitemapr URL stack (`parse_url_adapter()` + `build_loc_key()`, see
# `R/url.R` / ADR-005) so a hreflang href collides with a `<loc>` exactly when
# every other sitemapr consumer would treat them as the same URL. The raw bytes
# are preserved alongside the canonical key as evidence (ADR-004 posture).

# Canonical identity key for a vector of URL strings. Reuses the package URL
# stack so keying matches every other consumer (ADR-005). A URL that does not
# canonicalize to an absolute form (e.g. a relative href, which has no
# scheme/host to key on without a base to resolve against) falls back to its
# trimmed raw bytes, so it still forms a stable, distinct node rather than
# collapsing to a garbage `NA://NA` key. Blank/NA input -> NA key.
hreflang_graph_key <- function(urls) {
  urls <- as.character(urls)
  keys <- rep(NA_character_, length(urls))
  keep <- !is.na(urls) & nzchar(trimws(urls))
  if (!any(keep)) {
    return(keys)
  }
  parsed <- parse_url_adapter(urls[keep])
  canon <- build_loc_key(parsed)
  absolute <- parsed$parse_status == "ok" &
    !is.na(parsed$scheme) &
    nzchar(parsed$scheme) &
    !is.na(parsed$host) &
    nzchar(parsed$host)
  absolute[is.na(absolute)] <- FALSE
  canon[!absolute] <- trimws(urls[keep])[!absolute]
  keys[keep] <- canon
  keys
}

# One raw occurrence per `<xhtml:link>` on one `<url>` that carries an href (an
# edge needs a target). `rel`/`hreflang`/`href` are read with the shared
# `hreflang_link_attrs()` reader (R/protocol-validate.R). The hreflang token is
# trimmed; an absent attribute is `NA` (distinct from a present-but-empty ""). A
# link with no usable href yields no occurrence.
hreflang_link_row <- function(link, source_raw, i) {
  a <- hreflang_link_attrs(link)
  href <- a$href
  if (is.null(href) || !nzchar(trimws(as.character(href)))) {
    return(NULL)
  }
  hl <- if (is.null(a$hreflang)) {
    NA_character_
  } else {
    trimws(as.character(a$hreflang))
  }
  rel <- if (is.null(a$rel)) NA_character_ else as.character(a$rel)
  data.frame(
    row = i,
    source_raw = source_raw,
    target_raw = as.character(href),
    hreflang = hl,
    rel = rel,
    stringsAsFactors = FALSE
  )
}

# Occurrences for one row's `alternates` entry (NULL / empty -> none).
hreflang_row_occurrences <- function(alts, source_raw, i) {
  if (is.null(alts) || length(alts) == 0L) {
    return(NULL)
  }
  parts <- lapply(alts, hreflang_link_row, source_raw = source_raw, i = i)
  do.call(rbind, parts)
}

# Empty occurrence frame (the no-edge case), so downstream code always sees the
# full column set.
hreflang_occurrence_frame <- function() {
  data.frame(
    row = integer(0),
    source_raw = character(0),
    target_raw = character(0),
    hreflang = character(0),
    rel = character(0),
    stringsAsFactors = FALSE
  )
}

# Flatten the whole `alternates` list-column into one frame of raw occurrences.
hreflang_graph_occurrences <- function(rows) {
  alts <- rows$alternates
  loc <- as.character(rows$loc)
  acc <- vector("list", length(alts))
  for (i in seq_along(alts)) {
    acc[[i]] <- hreflang_row_occurrences(alts[[i]], loc[[i]], i)
  }
  out <- do.call(rbind, acc)
  if (is.null(out)) {
    return(hreflang_occurrence_frame())
  }
  out
}

# Node frame: one row per canonical key that appears in an edge (as source or
# target), sorted by key. `url_raw` is the lexicographically smallest raw string
# seen for that key (a deterministic representative). `node_kind` is
# `"internal"` when the key is a submitted `<loc>`, else `"external"`.
hreflang_graph_nodes <- function(occ, corpus_keys) {
  raw <- rbind(
    data.frame(
      key = occ$source_key,
      raw = occ$source_raw,
      stringsAsFactors = FALSE
    ),
    data.frame(
      key = occ$target_key,
      raw = occ$target_raw,
      stringsAsFactors = FALSE
    )
  )
  keys <- sort(unique(raw$key))
  rep_raw <- vapply(
    keys,
    function(k) min(raw$raw[raw$key == k]),
    character(1)
  )
  data.frame(
    url_key = keys,
    url_raw = unname(rep_raw),
    node_kind = ifelse(keys %in% corpus_keys, "internal", "external"),
    stringsAsFactors = FALSE
  )
}

# Collapse-group key for an occurrence: (source_key, target_key, hreflang). The
# separators/sentinels keep an absent token distinct from any present token and
# from a present-but-empty one; source/target keys are never NA here.
hreflang_edge_gkey <- function(occ) {
  hl <- ifelse(
    is.na(occ$hreflang),
    "",
    paste0("", occ$hreflang)
  )
  paste0(occ$source_key, "\001", occ$target_key, "\001", hl)
}

# Retained evidence for one collapsed edge: every raw occurrence, in a
# deterministic (row, target_raw) order.
hreflang_edge_evidence <- function(occ, ii) {
  ii <- ii[order(occ$row[ii], occ$target_raw[ii])]
  tibble::tibble(
    row = occ$row[ii],
    source_raw = occ$source_raw[ii],
    target_raw = occ$target_raw[ii],
    hreflang = occ$hreflang[ii],
    rel = occ$rel[ii]
  )
}

# Collapse occurrences into deduplicated edges, ordered deterministically by
# (source_key, target_key, hreflang). Duplicate edges retain their occurrences
# as an `occurrences` list-column of evidence tibbles.
hreflang_graph_edges <- function(occ) {
  idx <- split(seq_len(nrow(occ)), hreflang_edge_gkey(occ))
  reps <- vapply(idx, function(ii) ii[[1L]], integer(1))
  ord <- order(
    occ$source_key[reps],
    occ$target_key[reps],
    is.na(occ$hreflang[reps]),
    occ$hreflang[reps]
  )
  idx <- idx[ord]
  n <- length(idx)
  source_key <- character(n)
  target_key <- character(n)
  hreflang <- character(n)
  n_occ <- integer(n)
  occs <- vector("list", n)
  for (g in seq_len(n)) {
    ii <- idx[[g]]
    first <- ii[[1L]]
    source_key[g] <- occ$source_key[first]
    target_key[g] <- occ$target_key[first]
    hreflang[g] <- occ$hreflang[first]
    n_occ[g] <- length(ii)
    occs[[g]] <- hreflang_edge_evidence(occ, ii)
  }
  tibble::tibble(
    source_key = source_key,
    target_key = target_key,
    hreflang = hreflang,
    n_occurrences = n_occ,
    occurrences = occs
  )
}

# Relabel raw component roots to 1..K, ordered by the smallest url_key in each
# component, so cluster ids are stable across input row order.
hreflang_relabel_components <- function(keys, comp) {
  min_key <- tapply(keys, comp, min)
  ordered_roots <- names(sort(min_key))
  match(as.character(comp), ordered_roots)
}

# Connected components (union-find) of the undirected alternate relation over
# the node keys. Returns a cluster id per key, aligned to `keys`.
hreflang_graph_components <- function(keys, edges) {
  parent <- seq_along(keys)
  root <- function(x) {
    while (parent[x] != x) {
      x <- parent[x]
    }
    x
  }
  for (e in seq_len(nrow(edges))) {
    a <- root(match(edges$source_key[e], keys))
    b <- root(match(edges$target_key[e], keys))
    if (a != b) {
      parent[max(a, b)] <- min(a, b)
    }
  }
  comp <- vapply(seq_along(keys), root, integer(1))
  hreflang_relabel_components(keys, comp)
}

# Per-cluster summary tibble (ordered by cluster id): member count, the
# internal/external split, and the sorted member keys.
hreflang_graph_cluster_summary <- function(nodes) {
  by_keys <- split(nodes$url_key, nodes$cluster)
  by_kind <- split(nodes$node_kind, nodes$cluster)
  ids <- as.integer(names(by_keys))
  ord <- order(ids)
  ids <- ids[ord]
  by_keys <- by_keys[ord]
  by_kind <- by_kind[ord]
  n_int <- vapply(by_kind, function(k) sum(k == "internal"), integer(1))
  n_ext <- vapply(by_kind, function(k) sum(k == "external"), integer(1))
  tibble::tibble(
    cluster = ids,
    size = unname(lengths(by_keys)),
    n_internal = unname(n_int),
    n_external = unname(n_ext),
    members = unname(lapply(by_keys, sort))
  )
}

# The empty graph (no hreflang alternates in the corpus): the full column set
# with zero rows, so consumers can rely on the shape unconditionally.
hreflang_graph_empty <- function() {
  list(
    nodes = tibble::tibble(
      url_key = character(0),
      url_raw = character(0),
      node_kind = character(0),
      cluster = integer(0)
    ),
    edges = tibble::tibble(
      source_key = character(0),
      target_key = character(0),
      hreflang = character(0),
      n_occurrences = integer(0),
      occurrences = list()
    ),
    clusters = tibble::tibble(
      cluster = integer(0),
      size = integer(0),
      n_internal = integer(0),
      n_external = integer(0),
      members = list()
    )
  )
}

#' Build the whole-sitemap hreflang cluster graph
#'
#' Pure primitive (no network, no findings). Consumes a `read_sitemap()`-style
#' faithful row tibble and returns the deterministic hreflang alternate graph
#' described in this file's header.
#'
#' @param rows A tibble with at least a `loc` character column and an
#'   `alternates` list-column (per row: `NULL`, or a list of `xml2::as_list()`-
#'   converted `<xhtml:link>` elements carrying `rel`/`hreflang`/`href`
#'   attributes).
#' @return A list of three tibbles:
#'   * `nodes` — `url_key` (canonical), `url_raw` (representative raw string),
#'     `node_kind` (`"internal"`/`"external"`), `cluster` (integer id).
#'   * `edges` — `source_key`, `target_key`, `hreflang` (`NA` when the token was
#'     absent), `n_occurrences`, and `occurrences` (a list-column of evidence
#'     tibbles: `row`, `source_raw`, `target_raw`, `hreflang`, `rel`).
#'   * `clusters` — `cluster`, `size`, `n_internal`, `n_external`, and `members`
#'     (a list-column of sorted member keys).
#'   The result is invariant to input row order (bar the positional `row`
#'   reference carried in `edges$occurrences`, which tracks the input tibble).
#' @keywords internal
#' @noRd
build_hreflang_graph <- function(rows) {
  stopifnot(
    is.data.frame(rows),
    "loc" %in% names(rows),
    "alternates" %in% names(rows)
  )
  occ <- hreflang_graph_occurrences(rows)
  if (nrow(occ) == 0L) {
    return(hreflang_graph_empty())
  }
  occ$source_key <- hreflang_graph_key(occ$source_raw)
  occ$target_key <- hreflang_graph_key(occ$target_raw)
  occ <- occ[!is.na(occ$source_key) & !is.na(occ$target_key), , drop = FALSE]
  if (nrow(occ) == 0L) {
    return(hreflang_graph_empty())
  }
  corpus_keys <- unique(hreflang_graph_key(rows$loc))
  corpus_keys <- corpus_keys[!is.na(corpus_keys)]
  nodes <- hreflang_graph_nodes(occ, corpus_keys)
  edges <- hreflang_graph_edges(occ)
  nodes$cluster <- hreflang_graph_components(nodes$url_key, edges)
  list(
    nodes = tibble::as_tibble(nodes),
    edges = edges,
    clusters = hreflang_graph_cluster_summary(nodes)
  )
}
