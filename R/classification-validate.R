# Classification-layer diagnostics (D.6; docs/sitemap-spec.md §1, §3;
# docs/findings-contract.md). Internal only.
#
# These finding-producers cover the unsupported-input and encoding-conflict
# diagnostics that are decided from the SOURCE bytes and its classification, not
# from the parsed rows: a document whose root is neither <urlset> nor
# <sitemapindex> (`UNSUPPORTED_ROOT`), HTML served where a sitemap was expected
# (`UNSUPPORTED_HTML_MASQUERADE`), a sitemap-index child that points at an
# RSS/Atom feed (`UNSUPPORTED_FEED`, out of scope for v1), and the
# encoding-signal conflicts between the BOM, the XML declaration, and the HTTP
# charset (`ENCODING_CONFLICT`, `ENCODING_BOM_DECLARATION_CONFLICT`).
#
# They are grouped under the classification code-family and so carry
# `layer = "classification"` (findings-contract.md layer vocabulary: byte-level
# format sniffing), NOT `layer = "protocol"`. Like every other producer they
# emit contract-shaped rows only and never assemble: no `mode`, no
# strict-severity adjustment, no dedup/sort. In particular
# `ENCODING_BOM_DECLARATION_CONFLICT` is emitted at its non-strict `info`
# severity with `is_strict_only = FALSE`; Layer F elevates it to `warning` in
# strict mode (mirroring `PROTOCOL_LASTMOD_LOOKS_GENERATED`).
#
# The producers do not re-sniff or re-parse: they read a `source_meta` object
# (see `source_meta()`) that the caller — Layer B classification today, Layer F
# `validate_sitemap()` once it exists — fills from the already-computed
# classification. Until Layer F lands, `validate_protocol()` is the interim
# assembler that surfaces these diagnostics alongside its protocol findings
# (its `source_meta` argument); the cucumber feature wiring is deferred to
# Layer F (SITE-ymzvnlpr) per the slice convention.

# Construct the classification-layer findings tibble. Same column contract as
# `protocol_findings()` / `schema_findings()`, but `layer = "classification"`.
classification_findings <- function(code = character(0),
                                    severity = character(0),
                                    subject_type = character(0),
                                    subject_ref = character(0),
                                    message = character(0),
                                    evidence = list(),
                                    is_strict_only = logical(0)) {
  n <- length(code)
  tibble::tibble(
    code = as.character(code),
    severity = as.character(severity),
    layer = rep("classification", n),
    subject_type = as.character(subject_type),
    subject_ref = as.character(subject_ref),
    message = as.character(message),
    evidence = if (length(evidence) > 0L) evidence else vector("list", n),
    is_strict_only = as.logical(is_strict_only)
  )
}

# A zero-row classification-findings tibble (no diagnostic).
empty_classification_findings <- function() {
  classification_findings()
}

#' Bundle a source's classification + encoding signals for Layer D diagnostics
#'
#' The structured input the D.6 classification producers read instead of
#' re-sniffing the bytes. Every field defaults to "no signal", so an all-default
#' call (or a `NULL` `source_meta`) yields no diagnostics. The caller (Layer B
#' classification / Layer F) fills the fields it has determined.
#'
#' @param unsupported_root The root element's local name when it is neither
#'   `urlset` nor `sitemapindex`; `NA` when the root is supported or the source
#'   is not XML. Drives `UNSUPPORTED_ROOT`.
#' @param html_masquerade `TRUE` when the source is HTML served at a URL
#'   expected to serve a sitemap. Drives `UNSUPPORTED_HTML_MASQUERADE`.
#' @param feed_children Character vector of sitemap-index child `<loc>` URLs
#'   that point at an RSS/Atom feed (out of scope for v1). One
#'   `UNSUPPORTED_FEED` is emitted per element, in order.
#' @param bom_encoding,declared_encoding,http_charset The encoding names implied
#'   by the byte-order mark, the XML declaration's `encoding=`, and the HTTP
#'   `Content-Type` charset respectively; `NA` when that signal is absent. Drive
#'   the `ENCODING_*` conflict checks.
#' @return A named list with the fields above.
#' @keywords internal
#' @noRd
source_meta <- function(unsupported_root = NA_character_,
                        html_masquerade = FALSE,
                        feed_children = character(0),
                        bom_encoding = NA_character_,
                        declared_encoding = NA_character_,
                        http_charset = NA_character_) {
  list(
    unsupported_root = as.character(unsupported_root),
    html_masquerade = isTRUE(html_masquerade),
    feed_children = as.character(feed_children),
    bom_encoding = as.character(bom_encoding),
    declared_encoding = as.character(declared_encoding),
    http_charset = as.character(http_charset)
  )
}

# Normalise an encoding name for comparison: lower-case and strip every
# non-alphanumeric character, so `UTF-8`, `utf8`, and `utf_8` compare equal and
# `UTF-16BE` stays distinct from `UTF-8`. Absent/empty -> NA.
norm_encoding <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(NA_character_)
  }
  x <- trimws(as.character(x[1]))
  if (is.na(x) || !nzchar(x)) {
    return(NA_character_)
  }
  gsub("[^a-z0-9]", "", tolower(x))
}

# One source-level classification finding (`subject_type = "source"`, the
# unfragmented `sitemap://…` base).
classification_source_finding <- function(code, base, message,
                                          excerpt = NA_character_,
                                          severity = "error",
                                          is_strict_only = FALSE) {
  classification_findings(
    code = code,
    severity = severity,
    subject_type = "source",
    subject_ref = if (is.null(base)) NA_character_ else base,
    message = message,
    evidence = list(protocol_evidence(excerpt = excerpt)),
    is_strict_only = is_strict_only
  )
}

# One index-child classification finding, scoped to a child `<loc>` via the
# `#index-child:<url>` subject_ref fragment (findings-contract.md).
classification_child_finding <- function(code, base, child_url, message) {
  classification_findings(
    code = code,
    severity = "error",
    subject_type = "index-child",
    subject_ref = protocol_ref_fragment(
      base, paste0("#index-child:", child_url)
    ),
    message = message,
    evidence = list(protocol_evidence(excerpt = child_url)),
    is_strict_only = FALSE
  )
}

# Unsupported-input diagnostics from `source_meta`: HTML masquerade, an
# unsupported root element, and RSS/Atom feed children of a sitemap index.
# `NULL` meta (or all-default fields) yields no findings. Returns a (possibly
# empty) classification-findings tibble.
validate_classification <- function(meta, base) {
  if (is.null(meta)) {
    return(empty_classification_findings())
  }
  out <- list()

  if (isTRUE(meta$html_masquerade)) {
    out[[length(out) + 1L]] <- classification_source_finding(
      "UNSUPPORTED_HTML_MASQUERADE", base,
      paste0(
        "The document looks like HTML, not a sitemap, at the URL expected to ",
        "serve a sitemap."
      )
    )
  }

  root <- meta$unsupported_root
  if (length(root) == 1L && !is.na(root) && nzchar(root)) {
    out[[length(out) + 1L]] <- classification_source_finding(
      "UNSUPPORTED_ROOT", base,
      sprintf(
        "Root element <%s> is neither <urlset> nor <sitemapindex>.", root
      ),
      excerpt = root
    )
  }

  for (child in meta$feed_children) {
    if (is.na(child) || !nzchar(child)) {
      next
    }
    out[[length(out) + 1L]] <- classification_child_finding(
      "UNSUPPORTED_FEED", base, child,
      sprintf(
        paste0(
          "Sitemap-index child '%s' is an RSS/Atom feed; feeds are out of ",
          "scope for v1 and are not parsed."
        ),
        child
      )
    )
  }

  if (length(out) == 0L) {
    return(empty_classification_findings())
  }
  do.call(rbind, out)
}

# Encoding-conflict diagnostics from `source_meta`. Resolution priority is
# BOM > XML declaration > HTTP charset > UTF-8 (sitemap-spec.md §3). A
# BOM-vs-XML-declaration disagreement is the specialised
# `ENCODING_BOM_DECLARATION_CONFLICT`; a disagreement involving the HTTP charset
# is the general `ENCODING_CONFLICT`. Both are `info` here; Layer F elevates the
# BOM/declaration one to `warning` in strict mode. Returns a (possibly empty)
# classification-findings tibble.
validate_encoding <- function(meta, base) {
  if (is.null(meta)) {
    return(empty_classification_findings())
  }
  bom <- norm_encoding(meta$bom_encoding)
  decl <- norm_encoding(meta$declared_encoding)
  http <- norm_encoding(meta$http_charset)
  out <- list()

  resolution <- if (!is.na(bom)) {
    meta$bom_encoding
  } else if (!is.na(decl)) {
    meta$declared_encoding
  } else if (!is.na(http)) {
    meta$http_charset
  } else {
    "UTF-8"
  }

  bom_decl_conflict <- !is.na(bom) && !is.na(decl) && bom != decl
  if (bom_decl_conflict) {
    out[[length(out) + 1L]] <- classification_source_finding(
      "ENCODING_BOM_DECLARATION_CONFLICT", base,
      sprintf(
        paste0(
          "Byte-order mark indicates %s but the XML declaration says ",
          "encoding=\"%s\"; resolved to %s (BOM wins)."
        ),
        meta$bom_encoding, meta$declared_encoding, resolution
      ),
      severity = "info"
    )
  }

  bom_http_conflict <- !is.na(bom) && !is.na(http) && bom != http
  decl_http_conflict <- !is.na(decl) && !is.na(http) && decl != http
  if (bom_http_conflict || decl_http_conflict) {
    out[[length(out) + 1L]] <- classification_source_finding(
      "ENCODING_CONFLICT", base,
      sprintf(
        paste0(
          "Encoding signals disagree (BOM=%s, XML declaration=%s, HTTP ",
          "charset=%s); resolved to %s by priority (BOM > XML declaration > ",
          "HTTP charset)."
        ),
        encoding_signal_label(meta$bom_encoding),
        encoding_signal_label(meta$declared_encoding),
        encoding_signal_label(meta$http_charset),
        resolution
      ),
      severity = "info"
    )
  }

  if (length(out) == 0L) {
    return(empty_classification_findings())
  }
  do.call(rbind, out)
}

# Render one encoding signal for a message: the value, or "absent" when missing.
encoding_signal_label <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return("absent")
  }
  x <- trimws(as.character(x[1]))
  if (is.na(x) || !nzchar(x)) {
    return("absent")
  }
  x
}
