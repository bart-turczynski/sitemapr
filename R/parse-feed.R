# RSS / Atom feed parser (Layer C input; architecture.md §7).
#
# Internal only. Parses the three feed dialects the Sitemap Protocol accepts as
# a sitemap substitute — RSS 2.0, Atom 0.3, and Atom 1.0 — into the same tidy
# faithful row schema every other format parser emits (R/parse-rows.R). Pure and
# offline: it takes already-fetched bytes or text, never touches the network,
# and signals failures as classed conditions (never findings; architecture.md
# §3). This is the parser PRIMITIVE only; wiring feeds into the classification /
# validation / index pipeline is a separate slice.
#
# XXE safety (architecture.md §6): parsing reuses `read_sitemap_xml()`, the same
# `xml2::read_xml()` path `parse_urlset()` uses, with libxml2's default options.
# `NOENT`/`DTDLOAD` are never set, so an external `file://` SYSTEM entity yields
# empty text rather than file contents.
#
# Faithful dates (ADR-004): the publication/updated date is kept as the raw,
# trimmed string in the `lastmod` column (RFC-822 for RSS `<pubDate>`, ISO 8601
# for Atom `<updated>`/`<modified>`). Normalisation to POSIXct is deferred; the
# feed parser never coerces dates, mirroring the XML parser's faithful form.
#
# Element matching is namespace-aware and prefix-agnostic: core elements are
# located by local name so an unusual (or absent) feed prefix still resolves.
#
# Feeds carry no changefreq/priority and none of the sitemap extension
# elements, so every column other than `loc`, `lastmod`, and the
# entrypoint-supplied `source_sitemap` is NA / per-row NULL.

# Namespace URIs that identify the two supported Atom dialects. RSS 2.0 carries
# no namespace on its `<rss>` root, so it is matched by root name alone.
feed_xml_ns <- c(
  "atom1.0" = "http://www.w3.org/2005/Atom",
  "atom0.3" = "http://purl.org/atom/ns#"
)

# Classify the feed variant from the root element's local name plus (for Atom)
# its namespace URI: `<rss>` -> "rss2.0"; `<feed>` in the 2005 namespace ->
# "atom1.0"; in the purl.org/atom/ns# namespace -> "atom0.3". Any other root or
# an `<feed>` in an unknown namespace (e.g. RSS 1.0/RDF) is an unsupported
# dialect and raises a classed condition rather than being silently mis-parsed.
feed_variant <- function(root) {
  name <- xml2::xml_name(root)
  if (identical(name, "rss")) {
    return("rss2.0")
  }
  if (identical(name, "feed")) {
    uri <- xml2::xml_find_chr(root, "namespace-uri(.)")
    hit <- names(feed_xml_ns)[match(uri, feed_xml_ns)]
    if (!is.na(hit)) {
      return(hit)
    }
  }
  rlang::abort(
    sprintf(
      paste0(
        "Unsupported feed dialect <%s>; expected RSS 2.0 or Atom 0.3/1.0."
      ),
      name
    ),
    class = "sitemapr_unsupported_feed",
    root = name
  )
}

# Parse an RSS 2.0 `<rss>` root into faithful rows: one row per `<item>`. The
# link is the item's namespace-less `<link>` text (the `not(@href)` guard skips
# an `<atom:link rel="self">` self-reference some feeds embed); the date is the
# RFC-822 `<pubDate>`, kept raw. A missing link/date yields NA (no silent drop).
parse_feed_rss <- function(root, source_sitemap) {
  items <- xml2::xml_find_all(root, ".//*[local-name()='item']")
  if (length(items) == 0L) {
    return(empty_sitemap_rows())
  }
  loc <- trimws(xml2::xml_text(
    xml2::xml_find_first(items, "./*[local-name()='link' and not(@href)]")
  ))
  lastmod <- trimws(xml2::xml_text(
    xml2::xml_find_first(items, "./*[local-name()='pubDate']")
  ))
  lastmod[!nzchar(lastmod)] <- NA_character_
  sitemap_rows(loc = loc, lastmod = lastmod, source_sitemap = source_sitemap)
}

# Parse an Atom `<feed>` root (0.3 or 1.0) into faithful rows: one row per
# `<entry>`. The link is the `href` of the entry's alternate `<link>` (no `rel`
# or `rel="alternate"`, so a `rel="self"`/`"enclosure"` link is ignored); the
# date element differs by dialect (`date_local`), kept raw. A missing link/date
# yields NA (no silent drop).
parse_feed_atom <- function(root, source_sitemap, date_local) {
  entries <- xml2::xml_find_all(root, ".//*[local-name()='entry']")
  if (length(entries) == 0L) {
    return(empty_sitemap_rows())
  }
  links <- xml2::xml_find_first(
    entries,
    "./*[local-name()='link' and (not(@rel) or @rel='alternate')]"
  )
  loc <- trimws(xml2::xml_attr(links, "href"))
  lastmod <- trimws(xml2::xml_text(
    xml2::xml_find_first(entries, sprintf("./*[local-name()='%s']", date_local))
  ))
  lastmod[!nzchar(lastmod)] <- NA_character_
  sitemap_rows(loc = loc, lastmod = lastmod, source_sitemap = source_sitemap)
}

#' Parse an RSS 2.0 or Atom feed document into rows
#'
#' Reuses the XXE-safe `read_sitemap_xml()` parse, classifies the feed variant
#' (`rss2.0` / `atom0.3` / `atom1.0`) from the root element and namespace, and
#' extracts each item/entry's link URL and publication/updated date into the
#' faithful row tibble (dates kept raw, per ADR-004). An unrecognised feed
#' dialect or not-well-formed XML raises a classed condition. This primitive is
#' not yet wired into the classification/validation pipeline.
#'
#' @param x Raw bytes or a character string of the feed (already fetched).
#' @param source_sitemap Provenance value written to the `source_sitemap`
#'   column of every row. Defaults to `NA`.
#' @return A list with `kind` (`"feed"`), `variant` (the classified dialect),
#'   `rows` (the faithful row tibble; one row per item/entry), and `children`
#'   (`NULL`; feeds never nest like a sitemap index).
#' @keywords internal
#' @noRd
parse_feed <- function(x, source_sitemap = NA_character_) {
  doc <- read_sitemap_xml(x)
  root <- xml2::xml_root(doc)
  variant <- feed_variant(root)
  rows <- switch(
    variant,
    "rss2.0" = parse_feed_rss(root, source_sitemap),
    "atom1.0" = parse_feed_atom(root, source_sitemap, "updated"),
    "atom0.3" = parse_feed_atom(root, source_sitemap, "modified")
  )
  list(
    kind = "feed",
    variant = variant,
    rows = rows,
    children = NULL
  )
}
