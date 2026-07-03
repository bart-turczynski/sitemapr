# XML sitemap parser (Layer C input; architecture.md §7).
#
# Internal only. Parses Sitemap Protocol 0.9 `urlset` and `sitemapindex`
# documents into the tidy row schema (R/parse-rows.R). Pure and offline: it
# takes already-fetched bytes or text, never touches the network, and signals
# failures as classed conditions (never findings; architecture.md §3).
#
# XXE safety (architecture.md §6): parsing uses `xml2::read_xml()` with its
# default libxml2 options. `NOENT` and `DTDLOAD` are never set, so external
# entities are not resolved (a `file://` SYSTEM entity yields empty text rather
# than file contents). Internal entities expand as normal, well-formed XML.
#
# Element matching is namespace-aware and prefix-agnostic. Core elements are
# located by local name (robust to an unusual or absent core-namespace prefix);
# extension elements are located by their namespace URI plus local name, so a
# document may bind any prefix to the image/video/news/xhtml namespaces.
#
# Extension list-columns. Each of `images`, `video`, `news`, and `alternates`
# holds, per row, either `NULL` (no extension element of that kind) or a list
# with one entry per extension element, each entry the faithful nested
# `xml2::as_list()` conversion of that element. Element attributes (e.g. the
# `hreflang`/`href` of an `<xhtml:link>`) are preserved as R attributes on the
# converted entry, and child elements as nested named lists. This keeps the
# parser lossless and free of per-field maintenance; downstream Layer D
# validators read the fields they need from these structures.

# Namespace URIs for the v1 extension set. The core namespace is matched by
# local name rather than via this map (see header).
sitemap_xml_ns <- c(
  image = "http://www.google.com/schemas/sitemap-image/1.1",
  video = "http://www.google.com/schemas/sitemap-video/1.1",
  news = "http://www.google.com/schemas/sitemap-news/0.9",
  xhtml = "http://www.w3.org/1999/xhtml"
)

# XPath for a direct child matched by local name, regardless of namespace
# prefix (used for the core loc/lastmod/changefreq/priority/sitemap elements).
xpath_child_local <- function(name) {
  sprintf("./*[local-name()='%s']", name)
}

# Parse W3C Datetime / ISO 8601 sitemap `lastmod` values to POSIXct (UTC).
# Accepts a date (`YYYY-MM-DD`, taken as midnight UTC) or a datetime with a
# `Z` or `+hh:mm` offset, with optional fractional seconds. Unparseable or
# empty values become `NA` (a malformed `lastmod` is a Layer D finding, not a
# parse error). Vectorised over `x`.
parse_lastmod <- function(x) {
  out <- as.POSIXct(rep(NA_real_, length(x)), tz = "UTC")
  x <- trimws(as.character(x))
  ok <- !is.na(x) & nzchar(x)

  date_only <- ok & grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x)
  if (any(date_only)) {
    out[date_only] <- as.POSIXct(
      paste0(x[date_only], "T00:00:00+0000"),
      format = "%Y-%m-%dT%H:%M:%S%z",
      tz = "UTC"
    )
  }

  dt <- ok & !date_only
  if (any(dt)) {
    norm <- sub("[Zz]$", "+0000", x[dt])
    norm <- sub("([+-][0-9]{2}):([0-9]{2})$", "\\1\\2", norm)
    out[dt] <- as.POSIXct(
      norm,
      format = "%Y-%m-%dT%H:%M:%OS%z",
      tz = "UTC"
    )
  }

  out
}

# Parse `priority` text to numeric in [0, 1]; NA when absent or unparseable.
# Out-of-range values pass through unchanged (Layer D flags them).
parse_priority <- function(x) {
  suppressWarnings(as.numeric(trimws(x)))
}

# XXE-safe parse of raw bytes or a character string into an xml2 document.
# Re-raises any libxml2 well-formedness failure as a classed condition.
read_sitemap_xml <- function(x) {
  tryCatch(
    xml2::read_xml(x),
    error = function(cnd) {
      rlang::abort(
        "The XML sitemap is not well-formed and could not be parsed.",
        class = "sitemapr_xml_parse_error",
        parent = cnd
      )
    }
  )
}

# Collect the extension list-column for one extension type across all `url`
# nodes. Returns a list aligned to `url_nodes`: each element is NULL (no such
# extension element on that URL) or a list of `xml2::as_list()` conversions.
#
# A per-node `xml_find_all()` would re-resolve the document's namespaces on
# every call (`xml_ns.xml_document`), making a large urlset O(n^2). Instead this
# runs ONE document-level query for every matching extension element (direct
# children of a `url`) and groups the hits back to their owning `url` by node
# path — linear in the number of `url` nodes plus matched elements.
collect_extension <- function(root, url_nodes, uri, name) {
  n <- length(url_nodes)
  out <- vector("list", n)
  if (n == 0L) {
    return(out)
  }
  doc_xpath <- sprintf(
    "./*[local-name()='url']/*[namespace-uri()='%s' and local-name()='%s']",
    uri,
    name
  )
  els <- xml2::xml_find_all(root, doc_xpath)
  if (length(els) == 0L) {
    return(out) # no such extension anywhere — every element stays NULL
  }
  # Map each matched element to the index of its owning `url` node by node path.
  # `xml_path()` returns one path per element (1:1, unlike `xml_parent()`, which
  # collapses elements that share a parent into a single node); stripping the
  # last `/...` step yields each element's parent path, which matches the `url`
  # node's path exactly.
  parent_paths <- sub("/[^/]*$", "", xml2::xml_path(els))
  owner <- match(parent_paths, xml2::xml_path(url_nodes))
  converted <- lapply(els, xml2::as_list)
  for (i in seq_along(els)) {
    k <- owner[[i]]
    out[[k]] <- c(out[[k]], list(converted[[i]]))
  }
  out
}

# Parse a `urlset` root into the tidy row tibble.
parse_urlset <- function(root, source_sitemap) {
  url_nodes <- xml2::xml_find_all(root, xpath_child_local("url"))
  if (length(url_nodes) == 0L) {
    return(empty_sitemap_rows())
  }

  loc <- trimws(xml2::xml_text(
    xml2::xml_find_first(url_nodes, xpath_child_local("loc"))
  ))
  lastmod <- trimws(xml2::xml_text(
    xml2::xml_find_first(url_nodes, xpath_child_local("lastmod"))
  ))
  lastmod[!nzchar(lastmod)] <- NA_character_
  changefreq <- trimws(xml2::xml_text(
    xml2::xml_find_first(url_nodes, xpath_child_local("changefreq"))
  ))
  changefreq[!nzchar(changefreq)] <- NA_character_
  priority <- trimws(xml2::xml_text(
    xml2::xml_find_first(url_nodes, xpath_child_local("priority"))
  ))
  priority[!nzchar(priority)] <- NA_character_

  sitemap_rows(
    loc = loc,
    lastmod = lastmod,
    changefreq = changefreq,
    priority = priority,
    images = collect_extension(
      root,
      url_nodes,
      sitemap_xml_ns[["image"]],
      "image"
    ),
    video = collect_extension(
      root,
      url_nodes,
      sitemap_xml_ns[["video"]],
      "video"
    ),
    news = collect_extension(root, url_nodes, sitemap_xml_ns[["news"]], "news"),
    alternates = collect_extension(
      root,
      url_nodes,
      sitemap_xml_ns[["xhtml"]],
      "link"
    ),
    source_sitemap = source_sitemap
  )
}

# Parse a `sitemapindex` root into a tibble of child sitemaps (loc + lastmod),
# the input the index-expansion slice consumes.
parse_sitemapindex <- function(root) {
  sm_nodes <- xml2::xml_find_all(root, xpath_child_local("sitemap"))
  loc <- trimws(xml2::xml_text(
    xml2::xml_find_first(sm_nodes, xpath_child_local("loc"))
  ))
  lastmod <- parse_lastmod(xml2::xml_text(
    xml2::xml_find_first(sm_nodes, xpath_child_local("lastmod"))
  ))
  tibble::tibble(loc = loc, lastmod = lastmod)
}

#' Parse an XML sitemap document into rows
#'
#' Dispatches on the document root: a `urlset` yields the tidy URL-row tibble
#' (with extension list-columns); a `sitemapindex` yields the child-sitemap
#' table for the expansion layer. Any other root raises a classed condition.
#'
#' @param x Raw bytes or a character string of XML (already fetched/decoded).
#' @param source_sitemap Provenance value written to the `source_sitemap`
#'   column of `urlset` rows. Defaults to `NA`.
#' @return A list with `kind` (`"urlset"` or `"sitemapindex"`), `rows` (the
#'   tidy row tibble; empty for an index), and `children` (the child-sitemap
#'   tibble for an index, otherwise `NULL`).
#' @keywords internal
#' @noRd
parse_sitemap_xml <- function(x, source_sitemap = NA_character_) {
  doc <- read_sitemap_xml(x)
  root <- xml2::xml_root(doc)
  kind <- xml2::xml_name(root)

  if (identical(kind, "urlset")) {
    list(
      kind = "urlset",
      rows = parse_urlset(root, source_sitemap),
      children = NULL
    )
  } else if (identical(kind, "sitemapindex")) {
    list(
      kind = "sitemapindex",
      rows = empty_sitemap_rows(),
      children = parse_sitemapindex(root)
    )
  } else {
    rlang::abort(
      sprintf(
        paste0(
          "Unsupported sitemap root element <%s>; expected <urlset> or ",
          "<sitemapindex>."
        ),
        kind
      ),
      class = "sitemapr_unsupported_root",
      root = kind
    )
  }
}
