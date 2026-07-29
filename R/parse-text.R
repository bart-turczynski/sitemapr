# Text sitemap parser (Layer C input; architecture.md §7).
#
# Internal only. Parses the Sitemap Protocol text format into the tidy row
# schema (R/parse-rows.R): a UTF-8 document with one URL per line and nothing
# else. Pure and offline — it takes already-fetched bytes or text, never touches
# the network, and signals failures as classed conditions (never findings;
# architecture.md §3).
#
# Format rules (sitemaps.org text format):
#   - One URL per line.
#   - Blank and whitespace-only lines are skipped.
#   - Surrounding whitespace on a line is trimmed; the remainder is the loc.
#   - The text format carries no lastmod/changefreq/priority or extension data,
#     so every column other than `loc` (and the entrypoint-supplied
#     `source_sitemap`) is NA / per-row NULL.
#
# Line endings: LF, CRLF, and lone-CR are all accepted as line separators.
#
# Byte-order marks: a leading UTF-8 BOM is stripped from the raw bytes before
# decoding. U+FEFF is not POSIX whitespace, so `trimws()` would not remove it
# and it would ride into the first `<loc>` as a leading character, silently
# corrupting that URL. A UTF-16/UTF-32 BOM is rejected outright rather than
# decoded: the format is defined as UTF-8, and the NUL bytes such a document
# carries would otherwise surface as a bare `rawToChar()` error.

# Byte-order marks recognised on the raw bytes, longest-first so UTF-32LE is
# tested before its UTF-16LE prefix. Only the UTF-8 mark is strippable; the
# rest name an encoding the text format does not permit.
text_boms <- list(
  list(bytes = as.raw(c(0x00, 0x00, 0xFE, 0xFF)), encoding = "UTF-32BE"),
  list(bytes = as.raw(c(0xFF, 0xFE, 0x00, 0x00)), encoding = "UTF-32LE"),
  list(bytes = as.raw(c(0xEF, 0xBB, 0xBF)), encoding = "UTF-8"),
  list(bytes = as.raw(c(0xFE, 0xFF)), encoding = "UTF-16BE"),
  list(bytes = as.raw(c(0xFF, 0xFE)), encoding = "UTF-16LE")
)

# The BOM leading `bytes`, or NULL when none is present.
text_detect_bom <- function(bytes) {
  for (bom in text_boms) {
    n <- length(bom$bytes)
    if (length(bytes) >= n && all(bytes[seq_len(n)] == bom$bytes)) {
      return(bom)
    }
  }
  NULL
}

# Coerce already-fetched bytes or text to a single UTF-8 character string.
# Raw input is decoded as UTF-8 (the format's declared encoding) after any
# leading UTF-8 BOM is stripped; a character vector is collapsed with newlines
# so multi-element inputs split as lines. A non-UTF-8 BOM, or bytes that are
# not decodable as a string at all, raise `sitemapr_text_parse_error`.
text_as_string <- function(x) {
  if (!is.raw(x)) {
    return(paste(as.character(x), collapse = "\n"))
  }

  bom <- text_detect_bom(x)
  if (!is.null(bom)) {
    if (!identical(bom$encoding, "UTF-8")) {
      rlang::abort(
        sprintf(
          paste0(
            "The text sitemap begins with a %s byte-order mark; the text ",
            "format is defined as UTF-8."
          ),
          bom$encoding
        ),
        class = "sitemapr_text_parse_error"
      )
    }
    x <- x[-seq_along(bom$bytes)]
  }

  s <- tryCatch(
    rawToChar(x),
    error = function(cnd) {
      rlang::abort(
        "The text sitemap could not be decoded as UTF-8 text.",
        class = "sitemapr_text_parse_error",
        parent = cnd
      )
    }
  )
  Encoding(s) <- "UTF-8"
  s
}

# Best-effort counterpart to `text_as_string()`: decode fetched bytes as UTF-8
# text, or return NULL when they are not decodable text at all. Same BOM strip
# and same decode rules; only the failure mode differs.
#
# For callers whose contract is best-effort rather than all-or-nothing --
# robots.txt discovery, where a 404, an SSRF block and a transport failure all
# already degrade to "no directives found". A bare `rawToChar()` there raised
# `embedded nul in string` on any binary body and aborted the whole tree walk
# (SITE-udiqjraa); undecodable bytes carry no recoverable `Sitemap:` directive,
# which is a NULL, not an error.
decode_text_or_null <- function(bytes) {
  tryCatch(
    text_as_string(bytes),
    sitemapr_text_parse_error = function(cnd) NULL
  )
}

# Split a document into lines on LF, CRLF, or a lone CR. The one place the
# line-ending rule is spelled out; every caller that needs lines uses this.
#
# Deliberately NOT `perl = TRUE`. PCRE is pathologically slow on this pattern:
# on a 50,000-line document the same split costs ~17s under PCRE and ~0.06s
# under the default TRE engine, a ~290x difference that dominated the whole
# text-validation path (SITE-hwemiqne). The pattern is a plain alternation of
# literals with no PCRE-only syntax, so the two engines agree on it by
# construction -- verified identical over line-ending, whitespace, multibyte
# UTF-8, latin1 and invalid-UTF-8 inputs, not assumed. `useBytes` does not
# recover the cost, which rules out an encoding-conversion explanation.
split_lines <- function(s) {
  strsplit(s, "\r\n|\r|\n")[[1L]]
}

#' Parse a text sitemap document into rows
#'
#' Splits the document into lines, drops blank/whitespace-only lines, trims the
#' rest, and funnels the resulting URLs through `sitemap_rows()` so every
#' non-`loc` column defaults to NA / per-row NULL. An all-blank (or empty)
#' document yields the zero-row schema.
#'
#' @param x Raw bytes or a character string of the text sitemap (already
#'   fetched/decoded).
#' @param source_sitemap Provenance value written to the `source_sitemap`
#'   column of every row. Defaults to `NA`.
#' @return The tidy row tibble (R/parse-rows.R) with one row per URL line.
#' @keywords internal
#' @noRd
parse_sitemap_text <- function(x, source_sitemap = NA_character_) {
  s <- text_as_string(x)
  lines <- split_lines(s)
  lines <- trimws(lines)
  locs <- lines[nzchar(lines)]

  if (length(locs) == 0L) {
    return(empty_sitemap_rows())
  }

  sitemap_rows(loc = locs, source_sitemap = source_sitemap)
}
