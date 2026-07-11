# Deterministic comparison of two `sitemap_audit` objects (SITE-cprripyn).
#
# `compare_sitemap_audits()` diffs two audits component-by-component and reports
# added / removed / changed rows per component. It is built for CI drift
# monitoring: re-running the same audit twice MUST yield an empty diff, so the
# comparison is (a) order-independent (rows are matched by a stable identity
# key, never by position) and (b) insensitive to run-varying metadata.
#
# Volatile columns excluded from change detection. The only clearly run-varying
# column in any component contract is `sources$timing` (elapsed fetch seconds;
# see `source_metadata()` in R/fetch-config.R). It is keyed out of the "changed"
# comparison so that two runs of the same audit do not diff on wall-clock. There
# is no `fetched_at`/timestamp column in the current source-metadata contract;
# `profile_id`, `bytes`, `status`, and the redirect/namespace list-columns are
# deterministic content and ARE compared. Every other component (urls, findings,
# problems, tree) carries only content columns and no volatile fields.

# Per-component comparison spec: how to identify a row (`key`) and which columns
# to ignore when deciding whether a matched row "changed" (`ignore`). A `key` of
# "*" means the row's whole content is its identity (set semantics: a row is
# either present or absent, never "changed") — used for findings and problems,
# where a finding present in one audit and not the other is added/removed.
audit_diff_specs <- function() {
  list(
    urls = list(key = "loc", ignore = character(0)),
    findings = list(key = "*", ignore = character(0)),
    sources = list(key = "requested_url", ignore = "timing"),
    problems = list(key = "*", ignore = character(0)),
    tree = list(
      key = c("sitemap_url", "parent_sitemap", "depth"),
      ignore = character(0)
    )
  )
}

# Serialize one cell value (atomic scalar, atomic vector, or nested list) to a
# stable string, so list-columns (images/evidence/redirect_chain/...) compare
# structurally and reproducibly. Element order is preserved (producers emit it
# deterministically); names are kept for record-style list cells.
audit_diff_serialize_value <- function(x) {
  if (is.list(x)) {
    if (length(x) == 0L) {
      return("{}")
    }
    nms <- names(x)
    parts <- vapply(
      seq_along(x),
      function(i) {
        v <- audit_diff_serialize_value(x[[i]])
        if (!is.null(nms) && nzchar(nms[[i]])) paste0(nms[[i]], "=", v) else v
      },
      character(1L)
    )
    return(paste0("{", paste(parts, collapse = ","), "}"))
  }
  if (length(x) == 0L) {
    return("")
  }
  if (length(x) > 1L) {
    return(paste(
      vapply(x, audit_diff_serialize_value, character(1L)),
      collapse = ";"
    ))
  }
  if (is.na(x)) {
    return("<NA>")
  }
  as.character(x)
}

# A per-row signature over `cols`, joined with the unit separator so distinct
# column layouts cannot collide. Returns a length-`nrow(df)` character vector
# (all-empty strings when `cols` is empty), independent of row order.
audit_diff_row_keys <- function(df, cols) {
  n <- nrow(df)
  if (length(cols) == 0L || n == 0L) {
    return(character(n))
  }
  parts <- lapply(cols, function(cn) {
    col <- df[[cn]]
    if (is.list(col)) {
      vapply(col, audit_diff_serialize_value, character(1L))
    } else {
      out <- as.character(col)
      out[is.na(col)] <- "<NA>"
      out
    }
  })
  do.call(paste, c(parts, list(sep = "")))
}

# Deterministically order and slice the diff rows for one change class. A
# locale-independent radix sort on the key makes CI output reproducible.
audit_diff_slice <- function(df, idx, keyvec) {
  idx <- idx[order(keyvec[idx], method = "radix")]
  out <- df[idx, , drop = FALSE]
  rownames(out) <- NULL
  out
}

# Resolve a spec `key` ("*" means "every column") against the actual frames.
audit_diff_key_cols <- function(spec_key, old_df, new_df) {
  if (identical(spec_key, "*")) {
    return(union(names(old_df), names(new_df)))
  }
  spec_key
}

# Diff one component: match rows by identity key, then classify. `added` and
# `removed` are set differences on the identity key; `changed` are keys present
# in both whose content signature (all columns except key and ignored) differs.
audit_diff_component <- function(old_df, new_df, spec) {
  key_cols <- audit_diff_key_cols(spec$key, old_df, new_df)
  content_cols <- setdiff(names(new_df), c(key_cols, spec$ignore))

  old_key <- audit_diff_row_keys(old_df, key_cols)
  new_key <- audit_diff_row_keys(new_df, key_cols)

  added <- which(!(new_key %in% old_key))
  removed <- which(!(old_key %in% new_key))

  changed <- integer(0)
  common <- intersect(new_key, old_key)
  if (length(common) > 0L && length(content_cols) > 0L) {
    old_sig <- audit_diff_row_keys(old_df, content_cols)[match(common, old_key)]
    new_sig <- audit_diff_row_keys(new_df, content_cols)[match(common, new_key)]
    drifted <- common[old_sig != new_sig]
    changed <- which(new_key %in% drifted)
  }

  list(
    added = audit_diff_slice(new_df, added, new_key),
    removed = audit_diff_slice(old_df, removed, old_key),
    changed = audit_diff_slice(new_df, changed, new_key)
  )
}

# Bare constructor for the classed diff object.
new_sitemap_audit_diff <- function(components) {
  structure(list(components = components), class = "sitemap_audit_diff")
}

audit_diff_check_class <- function(x) {
  if (!inherits(x, "sitemap_audit_diff")) {
    rlang::abort(
      "`x` must be a `sitemap_audit_diff` object.",
      class = "sitemapr_bad_input"
    )
  }
  invisible(x)
}

# One row per component with its added / removed / changed row counts, in the
# canonical component order.
audit_diff_counts <- function(x) {
  names_v <- names(x$components)
  count_class <- function(cls) {
    unname(vapply(
      names_v,
      function(n) nrow(x$components[[n]][[cls]]),
      integer(1L)
    ))
  }
  tibble::tibble(
    component = names_v,
    added = count_class("added"),
    removed = count_class("removed"),
    changed = count_class("changed")
  )
}

#' Compare two sitemap audits
#'
#' Deterministically diffs two [sitemap_audit()] objects component-by-component
#' and reports which rows were added, removed, or changed. Built for CI drift
#' monitoring (e.g. a scheduled job that flags when a site's sitemap audit
#' changes): comparing an audit to an identically-recomputed copy of itself
#' always yields an empty diff.
#'
#' Rows are matched by a stable identity key, never by position, so shuffling a
#' component's rows never produces a diff. Keys are: `loc` for `urls`;
#' `requested_url` for `sources`; `sitemap_url` + `parent_sitemap` + `depth` for
#' `tree`; and the whole row for `findings` and `problems` (a finding present in
#' one audit and not the other is added/removed).
#'
#' Change detection ignores run-varying metadata so re-running the same audit
#' does not show spurious diffs: the elapsed-fetch column `sources$timing` is
#' excluded from the comparison. All other columns are deterministic content and
#' are compared.
#'
#' @param old,new `sitemap_audit` objects (the baseline and the new capture).
#' @return A `sitemap_audit_diff`: a classed list whose `components` element
#'   holds, for each of `urls`, `findings`, `sources`, `problems`, and `tree`, a
#'   list of `added`, `removed`, and `changed` tibbles (each carrying the
#'   component's columns, deterministically ordered by key). Use
#'   [audit_unchanged()] to test whether anything changed, and `summary()` for a
#'   per-component count table.
#' @seealso [sitemap_audit()] for the compared container, and
#'   [audit_unchanged()] for the "did anything change?" predicate.
#' @export
#' @examples
#' base <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   "<url><loc>https://example.com/</loc></url>",
#'   "<url><loc>https://example.com/a</loc></url></urlset>"
#' )
#' moved <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   "<url><loc>https://example.com/</loc></url>",
#'   "<url><loc>https://example.com/b</loc></url></urlset>"
#' )
#' p1 <- tempfile(fileext = ".xml")
#' p2 <- tempfile(fileext = ".xml")
#' writeLines(base, p1)
#' writeLines(moved, p2)
#'
#' old <- sitemap_audit(urls = read_sitemap(p1))
#' new <- sitemap_audit(urls = read_sitemap(p2))
#' d <- compare_sitemap_audits(old, new)
#' d
#' summary(d)
#'
#' # An audit compared with itself has an empty diff.
#' audit_unchanged(compare_sitemap_audits(old, old))
compare_sitemap_audits <- function(old, new) {
  audit_diff_require_audit(old, "old")
  audit_diff_require_audit(new, "new")

  specs <- audit_diff_specs()
  names_v <- audit_component_names()
  components <- lapply(names_v, function(nm) {
    audit_diff_component(old[[nm]], new[[nm]], specs[[nm]])
  })
  names(components) <- names_v
  new_sitemap_audit_diff(components)
}

audit_diff_require_audit <- function(x, arg) {
  if (!inherits(x, "sitemap_audit")) {
    rlang::abort(
      sprintf("`%s` must be a `sitemap_audit` object.", arg),
      class = "sitemapr_bad_input"
    )
  }
  invisible(x)
}

#' Did a sitemap-audit comparison find any change?
#'
#' The "did anything change?" predicate for a [compare_sitemap_audits()] result:
#' `TRUE` when the two audits are identical (an empty diff), `FALSE` otherwise.
#'
#' @param x A `sitemap_audit_diff`, as returned by [compare_sitemap_audits()].
#' @return A length-one logical: `TRUE` if no rows were added, removed, or
#'   changed in any component, else `FALSE`.
#' @seealso [compare_sitemap_audits()].
#' @export
#' @examples
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   "<url><loc>https://example.com/</loc></url></urlset>"
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#' audit <- sitemap_audit(urls = read_sitemap(path))
#'
#' audit_unchanged(compare_sitemap_audits(audit, audit))
audit_unchanged <- function(x) {
  audit_diff_check_class(x)
  counts <- audit_diff_counts(x)
  sum(counts$added, counts$removed, counts$changed) == 0L
}

#' @param x,object,... A `sitemap_audit_diff` object and ignored extra
#'   arguments, for the `print()`/`summary()` methods.
#' @rdname compare_sitemap_audits
#' @export
print.sitemap_audit_diff <- function(x, ...) {
  counts <- audit_diff_counts(x)
  total <- sum(counts$added, counts$removed, counts$changed)
  cat("<sitemap_audit_diff>\n")
  if (total == 0L) {
    cat("  no changes\n")
    return(invisible(x))
  }
  for (i in seq_len(nrow(counts))) {
    cat(sprintf(
      "  %-9s +%d  -%d  ~%d\n",
      counts$component[[i]],
      counts$added[[i]],
      counts$removed[[i]],
      counts$changed[[i]]
    ))
  }
  invisible(x)
}

#' @rdname compare_sitemap_audits
#' @export
summary.sitemap_audit_diff <- function(object, ...) {
  audit_diff_counts(object)
}
