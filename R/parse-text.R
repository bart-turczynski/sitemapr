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

# Coerce already-fetched bytes or text to a single UTF-8 character string.
# Raw input is decoded as UTF-8 (the format's declared encoding); a character
# vector is collapsed with newlines so multi-element inputs split as lines.
text_as_string <- function(x) {
  if (is.raw(x)) {
    s <- rawToChar(x)
    Encoding(s) <- "UTF-8"
    return(s)
  }
  paste(as.character(x), collapse = "\n")
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
  lines <- strsplit(s, "\r\n|\r|\n", perl = TRUE)[[1L]]
  lines <- trimws(lines)
  locs <- lines[nzchar(lines)]

  if (length(locs) == 0L) {
    return(empty_sitemap_rows())
  }

  sitemap_rows(loc = locs, source_sitemap = source_sitemap)
}
