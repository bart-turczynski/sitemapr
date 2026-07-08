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

# A zero-row source-metadata frame, used when a batched read has no successful
# sources but still needs the `sources` attribute schema.
empty_source_metadata <- function() {
  source_metadata()[0L, , drop = FALSE]
}

# Row-bind source-metadata records, preserving the schema when none exist.
combine_source_metadata <- function(parts) {
  parts <- parts[!vapply(parts, is.null, logical(1L))]
  if (length(parts) == 0L) {
    return(empty_source_metadata())
  }
  do.call(rbind, parts)
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

# Fetch and dispatch a URL source record. Returns list(rows, sources, problems).
# A top-level sitemapindex is handed to the recursive index-expansion engine;
# the root's own fetch record is prepended to the engine's per-child source
# records.
read_sitemap_url <- function(source, user_agent, limits, idx_limits) {
  rec <- fetch_source(source, user_agent = user_agent, limits = limits)
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

# Read one normalized source record.
read_sitemap_source <- function(source, user_agent, limits, index_limits) {
  if (isTRUE(source$is_local_file[[1L]])) {
    return(read_sitemap_local(source$normalized_url[[1L]]))
  }
  read_sitemap_url(
    source,
    user_agent = user_agent,
    limits = limits,
    idx_limits = index_limits
  )
}

# Public entry-point input guard. `create_source_records()` owns URL/path
# normalization; this helper keeps the historical public class for bad `x`.
sitemap_public_source_records <- function(x) {
  if (
    !is.character(x) ||
      length(x) == 0L ||
      anyNA(x) ||
      !all(nzchar(x))
  ) {
    rlang::abort(
      "`x` must be a non-empty character vector of sitemap sources.",
      class = "sitemapr_bad_input"
    )
  }
  create_source_records(x, as = "sitemap")
}

# Turn one batched read failure into the parse-layer `problems` attribute.
read_source_failure_problem <- function(source, cnd) {
  category <- if (inherits(cnd, "sitemapr_unsupported_format")) {
    "classification"
  } else if (
    inherits(cnd, "sitemapr_decompression_error") ||
      inherits(cnd, "sitemapr_malformed_archive") ||
      inherits(cnd, "sitemapr_archive_limit")
  ) {
    "decompression"
  } else {
    "fetch"
  }
  subject <- source$normalized_url[[1L]]
  parse_problems(
    severity = "warning",
    category = category,
    subject_ref = subject,
    message = sprintf(
      "Submitted sitemap source %s failed: %s",
      subject,
      conditionMessage(cnd)
    )
  )
}

# Read multiple normalized source records, continuing after per-source failures.
read_sitemap_batch <- function(sources, user_agent, limits, index_limits) {
  row_parts <- list()
  source_parts <- list()
  problem_parts <- list()

  for (i in seq_len(nrow(sources))) {
    source <- sources[i, , drop = FALSE]
    out <- tryCatch(
      suppressWarnings(
        read_sitemap_source(source, user_agent, limits, index_limits)
      ),
      error = function(cnd) {
        list(
          rows = empty_sitemap_rows(),
          sources = NULL,
          problems = read_source_failure_problem(source, cnd)
        )
      }
    )
    row_parts[[length(row_parts) + 1L]] <- out$rows
    source_parts[[length(source_parts) + 1L]] <- out$sources
    problem_parts[[length(problem_parts) + 1L]] <- out$problems
  }

  rows <- if (length(row_parts) == 0L) {
    empty_sitemap_rows()
  } else {
    do.call(rbind, row_parts)
  }
  list(
    rows = rows,
    sources = combine_source_metadata(source_parts),
    problems = combine_problems(problem_parts)
  )
}

#' Read a sitemap into a tidy tibble of URLs
#'
#' Parses one or more sitemap sources — sitemap URLs or local sitemap files —
#' into the tidy row tibble: one row per URL with `loc`, `lastmod`,
#' `changefreq`, `priority`, the `images`/`video`/`news`/`alternates` extension
#' list-columns, and `source_sitemap` provenance. Supported formats are XML
#' `urlset` and `sitemapindex`, the plain-text format, transparent gzip
#' (`.xml.gz`/`.txt.gz`), and — local files only — bounded `.tar.gz` archives.
#'
#' The result carries a `sources` attribute (the per-source fetch-metadata
#' records) and a `problems` attribute (a tibble of non-fatal issues such as
#' skipped archive members, unfetchable index children, or failed members of a
#' submitted vector). `read_sitemap()` never returns a validation findings
#' tibble; use `validate_sitemap()` for that.
#'
#' A top-level sitemap index is expanded recursively (cycle-safe, depth- and
#' count-capped) so every reachable child sitemap's rows carry per-child
#' provenance; the bounds are configurable via `index_limits`.
#'
#' When `x` contains more than one source, inputs are normalized, deduplicated,
#' and capped using the submitted-list source-record policy. Per-source failures
#' are recorded in the `problems` attribute and successful sources still
#' contribute rows. Scalar calls keep the stricter historical behavior: an
#' entry-point fetch failure or unsupported content raises a classed condition.
#'
#' @param x One or more sitemap URLs or paths to local sitemap files (`.xml`,
#'   `.txt`, `.gz`, or `.tar.gz`).
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
#' @examples
#' # Read a local sitemap file into a tidy tibble of URLs.
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   '<url><loc>https://example.com/</loc>',
#'   '<lastmod>2024-01-01</lastmod></url>',
#'   '<url><loc>https://example.com/about</loc></url>',
#'   '</urlset>'
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#' read_sitemap(path)
#'
#' # Read directly from a sitemap URL; a top-level index expands recursively.
#' # read_sitemap("https://example.com/sitemap.xml")
read_sitemap <- function(
  x,
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL
) {
  sources <- sitemap_public_source_records(x)
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }

  out <- if (length(x) == 1L) {
    read_sitemap_source(
      sources[1L, , drop = FALSE],
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits
    )
  } else {
    read_sitemap_batch(
      sources,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits
    )
  }

  result <- project_typed_rows(out$rows)
  attr(result, "sources") <- out$sources
  attr(result, "problems") <- out$problems
  result
}

#' @rdname read_sitemap
#' @export
read_sitemaps <- function(
  x,
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL
) {
  read_sitemap(
    x,
    user_agent = user_agent,
    limits = limits,
    index_limits = index_limits
  )
}
