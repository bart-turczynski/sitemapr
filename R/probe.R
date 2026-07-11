# probe_url(): non-resolving inspection primitive (ADR-007 §2).
#
# The permissive *reader* already exists (read_sitemap()); probe_url() fills the
# one genuine gap ADR-007 accepts — a lightweight, NON-resolving inspection that
# answers "what is this URL?" without expanding indexes or following children.
#
# It is a thin composition over existing internals: it fetches EXACTLY the given
# URL through fetch_source() (so it inherits the ADR-003 SSRF guard, redirect
# and body-size ceilings, and request-policy seam for free) and classifies the
# bytes with sniff_format() (byte-level, no new vocabulary). For a sitemap index
# it COUNTS the direct <sitemap> children by parsing the index locally, but it
# NEVER fetches them — that is what makes it a probe and not a resolver.
#
# The return is a single typed `sitemapr_probe` record aligned with the
# problems / sitemap_audit diagnostic convention (a classed list with a print
# method), never a new wrapper taxonomy. A fetch or parse failure is REPRESENTED
# in the record (detected_type = fetch_error / not_found / parse_error plus a
# `problems` row), not thrown — probe is diagnostic (ADR-007 §4).
#
# Reused internals (do NOT reimplement here):
#   fetch_source()        R/fetch.R        bounded, SSRF-safe single fetch
#   sniff_format()        R/sniff.R        raw bytes -> closed format string
#   gzip_decompress()     R/decompress.R   transparent gzip inflate
#   read_sitemap_xml()    R/parse-xml.R    XXE-safe xml2 parse
#   xpath_child_local()   R/parse-xml.R    namespace-agnostic child xpath
#   create_source_records() R/input.R      URL/path normalization
#   parse_problems()      R/problems.R     problems companion constructor

# ---- classification helpers --------------------------------------------------

# One-row `problems` finding for a diagnostic probe. Severity is always
# "warning" (the parse convention never downgrades an error to a problem).
probe_problem <- function(subject_ref, message, category = "classification") {
  parse_problems(
    severity = "warning",
    category = category,
    subject_ref = subject_ref,
    message = message
  )
}

# Map a sniff_format() name to the ADR-007 detected_type vocabulary, or
# NA_character_ for a name with no direct mapping (text/binary/empty/gzip/tar),
# which the caller resolves (robots detection or the unhappy path).
probe_type_from_format <- function(fmt) {
  switch(
    fmt,
    "xml-urlset" = "sitemap",
    "xml-sitemapindex" = "sitemap_index",
    "feed" = "feed",
    "html" = "html",
    "xml" = "xml_other",
    NA_character_
  )
}

# Suggested next call for a detected_type, mirroring the guidance ADR-007 §4
# describes: readers for sitemap/index, root discovery for robots/html.
probe_suggested_next <- function(detected_type) {
  switch(
    detected_type,
    "sitemap" = "read_sitemap() to extract the URL rows",
    "sitemap_index" = "read_sitemap() to expand the index and extract URLs",
    "feed" = "this is a web feed, not a sitemap; no sitemap action applies",
    "robots_txt" = "sitemap_tree(from = \"root\") to discover sitemaps",
    "html" = "sitemap_tree(from = \"root\") to discover this site's sitemaps",
    "xml_other" = "unrecognized XML; inspect the document manually",
    "not_found" = "verify the URL is correct and the resource exists",
    "fetch_error" = "check connectivity and that the URL is reachable",
    "parse_error" = "the content is not a recognized sitemap format",
    NA_character_
  )
}

# A short, bounded, human-readable excerpt of the body for eyeballing. Keeps
# only tab/newline/CR and printable ASCII, collapses runs of whitespace, and
# truncates to `max_chars`. Returns NA_character_ for an empty/undecodable body.
probe_text_excerpt <- function(bytes, max_chars = 500L) {
  if (is.null(bytes) || length(bytes) == 0L) {
    return(NA_character_)
  }
  take <- min(length(bytes), 4096L)
  ints <- as.integer(bytes[seq_len(take)])
  keep <- ints %in% c(0x09L, 0x0AL, 0x0DL) | (ints >= 0x20L & ints <= 0x7EL)
  ints <- ints[keep]
  if (length(ints) == 0L) {
    return(NA_character_)
  }
  s <- trimws(gsub("[[:space:]]+", " ", rawToChar(as.raw(ints))))
  if (nchar(s) > max_chars) {
    s <- paste0(substr(s, 1L, max_chars), "...")
  }
  s
}

# Direct URL-line count for a plain-text sitemap, mirroring parse_sitemap_text()
# (R/parse-text.R): one URL per non-blank, trimmed line. Text bytes never carry
# a NUL (a NUL sniffs as binary), so the UTF-8 decode is safe.
probe_text_url_count <- function(bytes) {
  if (is.null(bytes) || length(bytes) == 0L) {
    return(NA_integer_)
  }
  s <- rawToChar(bytes)
  Encoding(s) <- "UTF-8"
  lines <- trimws(strsplit(s, "\r\n|\r|\n", perl = TRUE)[[1L]])
  as.integer(sum(nzchar(lines)))
}

# Is this a robots.txt resource? True when the URL path is `/robots.txt`, or a
# `text` body carries robots directives. robots_txt is not a sniff_format() name
# (robots.txt sniffs as "text"), so this tiny detector supplies it without
# touching the sniffer's closed classification set.
probe_looks_like_robots <- function(url, bytes) {
  if (grepl("/robots\\.txt(\\?|#|$)", url, ignore.case = TRUE)) {
    return(TRUE)
  }
  txt <- probe_text_excerpt(bytes, 500L)
  if (is.na(txt)) {
    return(FALSE)
  }
  grepl("(?i)(user-agent|disallow|sitemap)\\s*:", txt, perl = TRUE)
}

# Inflate a gzip body and re-sniff the inner stream; a tar body is left as-is.
# Returns list(bytes, fmt, compressed, decomp_ok): `bytes`/`fmt` are the inner
# stream and its format for gzip, or the original bytes and outer format
# otherwise. `decomp_ok` is FALSE only when a gzip stream fails to inflate.
probe_prepare_bytes <- function(body) {
  fmt <- sniff_format(body)
  if (identical(fmt, "gzip")) {
    inner <- tryCatch(gzip_decompress(body), error = function(e) NULL)
    if (is.null(inner)) {
      return(list(
        bytes = body,
        fmt = fmt,
        compressed = TRUE,
        decomp_ok = FALSE
      ))
    }
    return(list(
      bytes = inner,
      fmt = sniff_format(inner),
      compressed = TRUE,
      decomp_ok = TRUE
    ))
  }
  list(
    bytes = body,
    fmt = fmt,
    compressed = identical(fmt, "tar"),
    decomp_ok = TRUE
  )
}

# Root element name and direct-child count for an XML body, parsed LOCALLY (no
# child fetch). `count` is the number of <sitemap> children for an index or
# <url> entries for a urlset; NA for feed / generic XML. `ok` is FALSE when the
# body is not well-formed XML.
probe_xml_details <- function(bytes, fmt) {
  doc <- tryCatch(read_sitemap_xml(bytes), error = function(e) NULL)
  if (is.null(doc)) {
    return(list(root = NA_character_, count = NA_integer_, ok = FALSE))
  }
  root <- xml2::xml_root(doc)
  child <- switch(
    fmt,
    "xml-sitemapindex" = "sitemap",
    "xml-urlset" = "url",
    NA_character_
  )
  count <- if (is.na(child)) {
    NA_integer_
  } else {
    length(xml2::xml_find_all(root, xpath_child_local(child)))
  }
  list(root = xml2::xml_name(root), count = as.integer(count), ok = TRUE)
}

# The empty classification skeleton shared by every body-classification path.
probe_empty_classification <- function(compressed, sample) {
  list(
    detected_type = NA_character_,
    xml_root = NA_character_,
    is_compressed = compressed,
    child_count = NA_integer_,
    sample = sample,
    problems = empty_problems()
  )
}

# Finish classification for a recognized sniff type. HTML needs no XML parse;
# the XML-ish types (sitemap/index/feed/xml_other) are parsed locally for the
# root name and, for an index/urlset, the direct-child count. A malformed XML
# body downgrades to parse_error.
probe_finish_known <- function(base, type, fmt, bytes, url) {
  base$detected_type <- type
  if (identical(type, "html")) {
    return(base)
  }
  det <- probe_xml_details(bytes, fmt)
  if (!det$ok) {
    base$detected_type <- "parse_error"
    base$problems <- probe_problem(url, "the XML body is not well-formed")
    return(base)
  }
  base$xml_root <- det$root
  base$child_count <- det$count
  base
}

# Classify an already-fetched body into the detected_type / xml_root /
# is_compressed / child_count / sample / problems fields. Never fetches.
probe_classify_body <- function(body, url) {
  prep <- probe_prepare_bytes(body)
  base <- probe_empty_classification(
    prep$compressed,
    probe_text_excerpt(prep$bytes)
  )
  if (prep$compressed && !prep$decomp_ok) {
    base$detected_type <- "parse_error"
    base$problems <- probe_problem(
      url,
      "the gzip body could not be decompressed"
    )
    return(base)
  }
  type <- probe_type_from_format(prep$fmt)
  if (!is.na(type)) {
    return(probe_finish_known(base, type, prep$fmt, prep$bytes, url))
  }
  if (identical(prep$fmt, "text") && probe_looks_like_robots(url, prep$bytes)) {
    base$detected_type <- "robots_txt"
    return(base)
  }
  # A plain-text URL list is a valid first-class sitemap format that
  # read_sitemap() parses (R/parse-text.R); classify it as a sitemap for
  # consistency with the reader (ADR-007 §2). Children are counted, not fetched.
  if (identical(prep$fmt, "text")) {
    base$detected_type <- "sitemap"
    base$child_count <- probe_text_url_count(prep$bytes)
    return(base)
  }
  base$detected_type <- "parse_error"
  base$problems <- probe_problem(
    url,
    sprintf("the content (%s) is not a recognized sitemap format", prep$fmt)
  )
  base
}

# ---- record assembly ---------------------------------------------------------

# Assemble the classed `sitemapr_probe` record from its parts. `suggested_next`
# is derived from the resolved detected_type so it always matches the record.
new_sitemapr_probe <- function(url, final_url, status_code, content_type, cls) {
  structure(
    list(
      url = url,
      final_url = final_url,
      status_code = status_code,
      content_type = content_type,
      detected_type = cls$detected_type,
      xml_root = cls$xml_root,
      is_compressed = cls$is_compressed,
      child_count = cls$child_count,
      sample = cls$sample,
      problems = cls$problems,
      suggested_next = probe_suggested_next(cls$detected_type)
    ),
    class = "sitemapr_probe"
  )
}

# Build a probe record for an error state (not_found / fetch_error), carrying a
# problems row and no body classification.
probe_error_record <- function(url, final_url, status_code, content_type,
                               detected_type, message) {
  cls <- probe_empty_classification(FALSE, NA_character_)
  cls$detected_type <- detected_type
  cls$problems <- probe_problem(final_url, message, category = "fetch")
  new_sitemapr_probe(url, final_url, status_code, content_type, cls)
}

# Turn a caught fetch abort (SSRF / timeout / redirect / ceiling) into a
# fetch_error record rather than propagating it — probe is diagnostic.
probe_fetch_error <- function(url, cnd) {
  final_url <- if (!is.null(cnd$url)) cnd$url else url
  probe_error_record(
    url, final_url, NA_integer_, NA_character_, "fetch_error",
    sprintf("fetch failed: %s", conditionMessage(cnd))
  )
}

# Assemble a probe record from a successful fetch_source() metadata record. A
# non-2xx terminal status (error_class set) is a fetch_error, or not_found for
# 404; otherwise the buffered body is classified.
probe_from_record <- function(url, rec) {
  status <- rec$status[[1L]]
  final_url <- rec$final_url[[1L]]
  content_type <- rec$content_type[[1L]]
  if (!is.na(rec$error_class[[1L]])) {
    detected_type <- if (identical(as.integer(status), 404L)) {
      "not_found"
    } else {
      "fetch_error"
    }
    return(probe_error_record(
      url, final_url, as.integer(status), content_type, detected_type,
      sprintf("HTTP %s while fetching %s", status, final_url)
    ))
  }
  cls <- probe_classify_body(attr(rec, "body"), final_url)
  new_sitemapr_probe(url, final_url, as.integer(status), content_type, cls)
}

# Probe a local file: read its bytes and classify them without any fetch.
probe_local <- function(path) {
  size <- file.info(path)$size
  body <- readBin(path, what = "raw", n = size)
  cls <- probe_classify_body(body, path)
  new_sitemapr_probe(path, path, NA_integer_, NA_character_, cls)
}

# Probe a remote URL through fetch_source() (SSRF + ceilings inherited). Fetch
# aborts are caught and represented as a fetch_error record.
probe_remote <- function(url, source, limits, user_agent, ssrf_guard, policy) {
  rec <- tryCatch(
    suppressWarnings(fetch_source(
      source,
      limits = limits,
      user_agent = user_agent,
      ssrf_guard = ssrf_guard,
      policy = policy
    )),
    sitemapr_ssrf_blocked = function(cnd) cnd,
    sitemapr_timeout = function(cnd) cnd,
    sitemapr_redirect_limit = function(cnd) cnd,
    sitemapr_body_ceiling = function(cnd) cnd
  )
  if (inherits(rec, "condition")) {
    return(probe_fetch_error(url, rec))
  }
  probe_from_record(url, rec)
}

probe_check_url <- function(url) {
  if (!is.character(url) || length(url) != 1L || is.na(url) || !nzchar(url)) {
    rlang::abort(
      "`url` must be a single non-empty, non-NA character string.",
      class = "sitemapr_bad_input"
    )
  }
  invisible(url)
}

# ---- public entry point ------------------------------------------------------

#' Probe a URL to inspect what it is, without resolving it
#'
#' `probe_url()` is a lightweight, **non-resolving** inspection: it fetches
#' exactly one URL (or reads one local file) and reports what it is — a sitemap,
#' a sitemap index, a feed, robots.txt, an HTML page, or an error state —
#' **without** expanding indexes or following children. It is the diagnostic
#' counterpart to [read_sitemap()], which resolves a sitemap to its final URL
#' rows. Use `probe_url()` to diagnose first and [read_sitemap()] to resolve.
#'
#' The fetch goes through the same bounded, SSRF-safe engine as the rest of the
#' package, so `probe_url()` inherits the network-safety policy (per-hop SSRF
#' guard, redirect and body-size ceilings) and the `limits` / `policy`
#' overrides. It fetches **only** the given URL: for a sitemap index it *counts*
#' the direct `<sitemap>` children by parsing the index locally, but it never
#' fetches them.
#'
#' A fetch or parse failure is represented in the returned record
#' (`detected_type` becomes `"fetch_error"`, `"not_found"`, or `"parse_error"`,
#' with an explanatory `problems` row), not thrown — `probe_url()` is
#' diagnostic. Only invalid input (a non-string `url`) raises an error.
#'
#' @param url A single sitemap URL or local file path to inspect.
#' @param limits Network limits for the fetch, as from [fetch_limits()].
#' @param user_agent The User-Agent header for the fetch. Defaults to the
#'   package User-Agent.
#' @param ssrf_guard Logical; when `TRUE` (default) the structural SSRF guard
#'   runs on every hop.
#' @param policy A request policy applied to the fetch, as from
#'   `request_policy()`. Defaults to the no-op policy.
#' @return A `sitemapr_probe` object: a classed list with the fields `url`,
#'   `final_url`, `status_code`, `content_type`, `detected_type`, `xml_root`,
#'   `is_compressed`, `child_count`, `sample`, `problems`, and `suggested_next`.
#'   `detected_type` is one of `"sitemap"`, `"sitemap_index"`, `"feed"`,
#'   `"robots_txt"`, `"html"`, `"xml_other"`, `"not_found"`, `"fetch_error"`,
#'   or `"parse_error"`.
#' @seealso [read_sitemap()] to resolve a sitemap to its URL rows, and
#'   [sitemap_tree()] to discover a site's sitemaps from its root.
#' @export
#' @examples
#' # Probe a local sitemap file: detected as a urlset, with a child count.
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   "<url><loc>https://example.com/</loc></url>",
#'   "<url><loc>https://example.com/about</loc></url>",
#'   "</urlset>"
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#' probe_url(path)
#'
#' # A sitemap index: children are COUNTED, never fetched.
#' index <- paste0(
#'   '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   "<sitemap><loc>https://example.com/s1.xml</loc></sitemap>",
#'   "<sitemap><loc>https://example.com/s2.xml</loc></sitemap>",
#'   "</sitemapindex>"
#' )
#' index_path <- tempfile(fileext = ".xml")
#' writeLines(index, index_path)
#' probe_url(index_path)
#'
#' # Probe a live URL (requires network):
#' # probe_url("https://example.com/sitemap.xml")
probe_url <- function(
  url,
  limits = fetch_limits(),
  user_agent = default_user_agent(),
  ssrf_guard = TRUE,
  policy = request_policy()
) {
  probe_check_url(url)
  source <- create_source_records(url, as = "sitemap")[1L, , drop = FALSE]
  if (isTRUE(source$is_local_file[[1L]])) {
    return(probe_local(source$normalized_url[[1L]]))
  }
  probe_remote(url, source, limits, user_agent, ssrf_guard, policy)
}

# ---- print method ------------------------------------------------------------

# One `<label>: <value>` line for the print method, skipping absent values.
probe_print_line <- function(label, value) {
  if (is.null(value) || length(value) == 0L || is.na(value)) {
    return(invisible())
  }
  cat(sprintf("  %-14s %s\n", paste0(label, ":"), format(value)))
  invisible()
}

#' @export
print.sitemapr_probe <- function(x, ...) {
  cat("<sitemapr_probe>\n")
  probe_print_line("url", x$url)
  if (!is.na(x$final_url) && !identical(x$final_url, x$url)) {
    probe_print_line("final_url", x$final_url)
  }
  probe_print_line("detected_type", x$detected_type)
  probe_print_line("status_code", x$status_code)
  probe_print_line("content_type", x$content_type)
  probe_print_line("xml_root", x$xml_root)
  probe_print_line("is_compressed", x$is_compressed)
  probe_print_line("child_count", x$child_count)
  probe_print_line("suggested_next", x$suggested_next)
  cat(sprintf("  %-14s %d\n", "problems:", nrow(x$problems)))
  invisible(x)
}
