# read_sitemap() entry point (Layer C; architecture.md §7, PRD §1).
#
# The public parse entry point. It resolves a single source (a sitemap URL or a
# local file path), classifies its bytes with the format sniffer, and dispatches
# to the format parser (XML urlset/index, text, gzip, local tar.gz) to produce
# the tidy row tibble. The result carries two attributes (architecture.md §7):
#   - `sources`  : the per-source fetch-metadata records (one row each).
#   - `problems` : the non-fatal `parse_problems()` companion table.
#
# Conditions, never findings (architecture.md §3). The parse API NEVER returns
# a validation findings tibble — that is `validate_sitemap()`'s job. An
# entry-point failure is a CLASSED ERROR: a transport/SSRF/timeout failure
# propagates from `fetch_source()`; a non-2xx terminal status becomes
# `sitemapr_entrypoint_error` identifying the URL and HTTP status; unsupported
# content becomes `sitemapr_unsupported_format`.
#
# A top-level sitemapindex is expanded RECURSIVELY by the index-expansion engine
# (R/index-expansion.R): each child is fetched and parsed so its rows carry
# per-child provenance, with cycle detection, a depth cap, a child-count cap,
# and child deduplication. Bounded-traversal events (cycles, depth/count caps,
# nested indexes) are recorded as `problems`, never findings — the stable
# INDEX_* finding codes are `validate_sitemap()`'s job (Layer F).

# Dispatch one already-fetched document's bytes to the right format parser,
# returning the normalized list(kind, rows, children) shape that the XML parser
# uses. A gzip stream is transparently inflated and re-sniffed first; a tar
# stream delivered as bytes is rejected (tar.gz is local-only, PRD §1).
parse_dispatch <- function(bytes, source_sitemap) {
  fmt <- sniff_format(bytes)
  if (identical(fmt, "gzip")) {
    bytes <- gzip_decompress(bytes)
    fmt <- sniff_format(bytes)
    if (identical(fmt, "tar")) {
      rlang::abort(
        paste(
          "tar.gz archives are supported only as local files,",
          "not over the network."
        ),
        class = "sitemapr_unsupported_format",
        format = "tar"
      )
    }
  }

  if (fmt %in% c("xml-urlset", "xml-sitemapindex", "xml")) {
    return(parse_sitemap_xml(bytes, source_sitemap = source_sitemap))
  }
  if (identical(fmt, "text")) {
    return(list(
      kind = "text",
      rows = parse_sitemap_text(bytes, source_sitemap = source_sitemap),
      children = NULL
    ))
  }

  rlang::abort(
    sprintf("Unsupported sitemap content (sniffed format: %s).", fmt),
    class = "sitemapr_unsupported_format",
    format = fmt
  )
}

# Read and dispatch a local file. A local `.tar.gz` (gzip whose inner stream is
# tar) goes to the bounded archive extractor by path; everything else is
# dispatched from its bytes. Returns list(rows, sources, problems).
read_sitemap_local <- function(path) {
  size <- file.info(path)$size
  bytes <- readBin(path, what = "raw", n = size)
  fmt <- sniff_format(bytes)

  if (
    identical(fmt, "gzip") &&
      identical(sniff_format(gzip_decompress(bytes)), "tar")
  ) {
    meta <- source_metadata(
      requested_url = path,
      final_url = path,
      bytes = as.integer(size),
      format = "tar"
    )
    res <- parse_sitemap_archive(path, source_ref = path)
    return(list(rows = res$rows, sources = meta, problems = res$problems))
  }

  parsed <- parse_dispatch(bytes, source_sitemap = path)
  meta <- source_metadata(
    requested_url = path,
    final_url = path,
    bytes = as.integer(size),
    format = fmt
  )
  list(rows = parsed$rows, sources = meta, problems = empty_problems())
}

# Fetch and dispatch a URL source. Returns list(rows, sources, problems). A
# top-level sitemapindex is handed to the recursive index-expansion engine; the
# root's own fetch record is prepended to the engine's per-child source records.
read_sitemap_url <- function(url, user_agent, limits, idx_limits) {
  rec <- fetch_source(url, user_agent = user_agent, limits = limits)
  if (!is.na(rec$error_class)) {
    rlang::abort(
      sprintf(
        "Entry-point fetch of %s failed with HTTP %s.",
        rec$final_url,
        rec$status
      ),
      class = "sitemapr_entrypoint_error",
      url = rec$final_url,
      status = rec$status
    )
  }

  parsed <- parse_dispatch(attr(rec, "body"), source_sitemap = rec$final_url)
  if (identical(parsed$kind, "sitemapindex")) {
    ex <- expand_index(
      rec$final_url,
      parsed$children,
      depth = 0L,
      user_agent = user_agent,
      limits = idx_limits,
      net_limits = limits
    )
    sources <- if (is.null(ex$sources)) rec else rbind(rec, ex$sources)
    return(list(rows = ex$rows, sources = sources, problems = ex$problems))
  }
  list(rows = parsed$rows, sources = rec, problems = empty_problems())
}

#' Read a sitemap into a tidy tibble of URLs
#'
#' Parses a single sitemap source — a sitemap URL or a local sitemap file — into
#' the tidy row tibble: one row per URL with `loc`, `lastmod`, `changefreq`,
#' `priority`, the `images`/`video`/`news`/`alternates` extension list-columns,
#' and `source_sitemap` provenance. Supported formats are XML `urlset` and
#' `sitemapindex`, the plain-text format, transparent gzip
#' (`.xml.gz`/`.txt.gz`), and — local files only — bounded `.tar.gz` archives.
#'
#' The result carries a `sources` attribute (the per-source fetch-metadata
#' records) and a `problems` attribute (a tibble of non-fatal issues such as
#' skipped archive members or unfetchable index children). `read_sitemap()`
#' never returns a validation findings tibble; use `validate_sitemap()`
#' for that.
#'
#' A top-level sitemap index is expanded recursively (cycle-safe, depth- and
#' count-capped) so every reachable child sitemap's rows carry per-child
#' provenance; the bounds are configurable via `index_limits`.
#'
#' @param x A single source: a sitemap URL (character) or a path to a local
#'   sitemap file (`.xml`, `.txt`, `.gz`, or `.tar.gz`).
#' @param user_agent The User-Agent header for HTTP fetches. Defaults to the
#'   package User-Agent.
#' @param limits Network limits for HTTP fetches, as from `fetch_limits()`.
#' @param index_limits Sitemapindex-expansion bounds (recursion depth and
#'   per-index child-count cap), as from `index_limits()`. Defaults to
#'   `index_limits()`.
#' @return A tibble of URL rows with `sources` and `problems` attributes.
#'   An entry-point fetch failure or unsupported content raises a classed error
#'   condition.
#' @export
read_sitemap <- function(
  x,
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL
) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    rlang::abort(
      "`x` must be a single non-empty source: a URL or a local file path.",
      class = "sitemapr_bad_input"
    )
  }
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }

  out <- if (file.exists(x)) {
    read_sitemap_local(x)
  } else {
    read_sitemap_url(
      x,
      user_agent = user_agent,
      limits = limits,
      idx_limits = index_limits
    )
  }

  result <- project_typed_rows(out$rows)
  attr(result, "sources") <- out$sources
  attr(result, "problems") <- out$problems
  result
}
