# Tidy-tibble row schema for read_sitemap() (Layer C; architecture.md §7).
#
# Internal only. `sitemap_rows()` is the single constructor for the parsed-URL
# tibble every format parser (XML, text, gzip, tar.gz) emits, so the column
# set, order, and types are defined in exactly one place. This is the FAITHFUL
# row tibble (ADR-004): `lastmod` and `priority` are kept as the raw, trimmed
# `<lastmod>`/`<priority>` strings (NA_character_ when absent or empty), so
# validation can read the original text. `read_sitemap()` projects this to the
# typed public tibble late via `project_typed_rows()`. The contract is 9
# columns (architecture.md §7 / PRD §8):
#
#   loc            character    the URL
#   lastmod        character    raw <lastmod> text (projected to POSIXct/UTC by
#                               read_sitemap()), NA when absent
#   changefreq     character    advisory crawl frequency, NA when absent
#   priority       character    raw <priority> text (projected to numeric by
#                               read_sitemap()), NA when absent
#   images         list         <image:image> extension data, one entry per row
#   video          list         <video:video> extension data
#   news           list         <news:news> extension data
#   alternates     list         <xhtml:link rel="alternate"> hreflang data
#   source_sitemap character    provenance/URL of the sitemap contributing the
#                               row (populated by the read_sitemap() entrypoint)
#
# The list-columns hold per-row structured extension data; a row with no
# extension data of that kind carries NULL. Coercion of `lastmod` (ISO 8601 ->
# POSIXct) and `priority` (text -> numeric) is the read_sitemap() projection's
# job, not the constructor's.

# Recycle a length-1 vector up to `n`, pass through a length-`n` vector, and
# expand NULL to an n-length vector of `fill`. Anything else is a length error.
parse_recycle <- function(x, n, fill) {
  if (is.null(x)) {
    return(rep(fill, n))
  }
  if (length(x) == 1L && n != 1L) {
    return(rep(x, n))
  }
  if (length(x) != n) {
    rlang::abort(
      sprintf(
        "Expected a length-%d or length-1 vector, got length %d.",
        n,
        length(x)
      ),
      class = "sitemapr_row_length_error"
    )
  }
  x
}

# As parse_recycle(), but for the list-columns: NULL becomes a list of `n` NULL
# entries (the "no extension data" representation).
parse_recycle_list <- function(x, n) {
  if (is.null(x)) {
    return(vector("list", n))
  }
  if (!is.list(x)) {
    rlang::abort(
      "A list-column must be supplied as a list.",
      class = "sitemapr_row_length_error"
    )
  }
  if (length(x) == 1L && n != 1L) {
    return(rep(x, n))
  }
  if (length(x) != n) {
    rlang::abort(
      sprintf(
        "Expected a length-%d or length-1 list, got length %d.",
        n,
        length(x)
      ),
      class = "sitemapr_row_length_error"
    )
  }
  x
}

#' Construct the read_sitemap() faithful row tibble
#'
#' The single source of truth for the parsed-URL tibble contract: 9 columns in
#' a fixed order (see file header). Every format parser funnels its output
#' through here so the schema is defined once. This is the FAITHFUL form
#' (ADR-004): `lastmod` and `priority` are stored as raw character strings, not
#' coerced. Scalars are recycled to the row count implied by `loc`; the
#' list-columns default to a per-row `NULL` ("no extension data").
#'
#' @param loc Character vector of URLs; its length sets the row count.
#' @param lastmod Character; raw `<lastmod>` text. Defaults to `NA_character_`.
#' @param changefreq,source_sitemap Character; default `NA` / empty.
#' @param priority Character; raw `<priority>` text. Default `NA_character_`.
#' @param images,video,news,alternates List-columns of per-row extension data;
#'   default to per-row `NULL`.
#' @return A tibble with the 9 contract columns (faithful form).
#' @keywords internal
#' @noRd
sitemap_rows <- function(
  loc = character(0),
  lastmod = NULL,
  changefreq = NULL,
  priority = NULL,
  images = NULL,
  video = NULL,
  news = NULL,
  alternates = NULL,
  source_sitemap = NULL
) {
  loc <- as.character(loc)
  n <- length(loc)

  tibble::tibble(
    loc = loc,
    lastmod = as.character(parse_recycle(lastmod, n, NA_character_)),
    changefreq = as.character(parse_recycle(changefreq, n, NA_character_)),
    priority = as.character(parse_recycle(priority, n, NA_character_)),
    images = parse_recycle_list(images, n),
    video = parse_recycle_list(video, n),
    news = parse_recycle_list(news, n),
    alternates = parse_recycle_list(alternates, n),
    source_sitemap = as.character(
      parse_recycle(source_sitemap, n, NA_character_)
    )
  )
}

# Project the faithful row tibble to the typed public read_sitemap() contract:
# `lastmod` raw text -> POSIXct (UTC) via parse_lastmod(), `priority` raw text
# -> numeric via parse_priority(). All other columns pass through unchanged.
# Handles the zero-row case (the parsers still emit empty character columns).
project_typed_rows <- function(rows) {
  rows$lastmod <- parse_lastmod(rows$lastmod)
  rows$priority <- parse_priority(rows$priority)
  rows
}

# A zero-row tibble with the full schema, for parsers that produce no rows.
empty_sitemap_rows <- function() {
  sitemap_rows()
}
