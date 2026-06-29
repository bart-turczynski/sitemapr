#' Parse URLs into sitemapr's canonical component set
#'
#' Thin wrapper over `rurl::safe_parse_urls()` that pins the canonicalization
#' options sitemapr relies on (IDNA/Punycode host output, dot-segment + slash
#' path normalization, lower-cased host, and RFC 3987 IRI to RFC 3986 URI
#' mapping of the path/query). The host is IDNA-encoded and the path/query are
#' percent-encoded (`path_encoding = "encode"`), so a Unicode `loc`/sitemap URL
#' resolves to its canonical ASCII URI form — the form an HTTP request line
#' actually carries and the form the identity key must compare on. The mapping
#' is a no-op for an already-ASCII URL and never double-encodes an existing
#' `%XX` octet, so query parameters and pre-encoded paths pass through verbatim;
#' entrypoint scheme policy (bare domain to `https://`) belongs to a later unit,
#' not here. The untouched input is preserved in `original_url`.
#'
#' Performance (ADR-005): `rurl::safe_parse_urls()` runs a per-URL R routine
#' (IDNA, Public Suffix List, IRI to URI encoding) and costs ~1.8 ms/URL —
#' ~90 s for a max-size 50 000-`<loc>` sitemap. The vast majority of real
#' `<loc>`s are plain ASCII `http(s)` URLs that this canonicalization leaves
#' byte-for-byte unchanged, so `rurl` is invoked only for the URLs where it can
#' actually change the answer (`url_needs_rurl()`); the rest are resolved from a
#' cheap `curl` component split. The fast path is taken **only where `rurl` is a
#' proven no-op**, so the merged result is identical to running `rurl` on every
#' URL — see the equivalence test in `tests/testthat/test-url.R`.
#'
#' @param urls Character vector of URL strings.
#' @return A data.frame with one row per input URL, including at least
#'   `original_url`, `scheme`, `host`, `port`, `path`, `query`, `fragment`,
#'   `user`, `is_ip_host`, and `parse_status`.
#' @keywords internal
#' @noRd
parse_url_adapter <- function(urls) {
  n <- length(urls)
  if (n == 0L) {
    return(rurl_parse(urls))
  }

  fast <- !url_needs_rurl(urls)
  comp <- vector("list", n)
  for (i in which(fast)) {
    c_i <- url_fast_components(urls[[i]])
    if (is.null(c_i)) {
      fast[i] <- FALSE # ambiguous once parsed — defer to rurl
    } else {
      comp[[i]] <- c_i
    }
  }

  if (!any(fast)) {
    return(rurl_parse(urls))
  }
  if (all(fast)) {
    return(url_fast_rows(urls, comp))
  }

  # Build both halves with the identical 14-column schema, then restore order.
  fast_df <- url_fast_rows(urls[fast], comp[fast])
  slow_df <- rurl_parse(urls[!fast])
  combined <- rbind(fast_df, slow_df)
  combined[order(c(which(fast), which(!fast))), , drop = FALSE]
}

# Local null-coalescing helper (base R gained `%||%` only in 4.4; the package
# targets R >= 4.0). Internal to this file's fast-path plumbing.
`%||%` <- function(x, y) if (is.null(x)) y else x

# The pinned rurl call (canonicalization options sitemapr relies on).
rurl_parse <- function(urls) {
  rurl::safe_parse_urls(
    urls,
    host_encoding = "idna",
    path_normalization = "both",
    case_handling = "lower_host",
    path_encoding = "encode"
  )
}

# Cheap, vectorized first cut: a URL MIGHT need rurl if it is not pure ASCII, or
# carries a `%` (possible escape normalization), or contains a character rurl
# would percent-encode or that complicates parsing. Returning TRUE only routes a
# URL to rurl; the precise per-component decision is `url_fast_components()`.
# Conservative by design: a false TRUE costs only speed, never correctness.
url_needs_rurl <- function(urls) {
  is.na(urls) |
    grepl("[\x80-\xff]", urls, useBytes = TRUE) | # any non-ASCII byte
    grepl("%", urls, fixed = TRUE) | # existing escape; rurl owns it
    grepl("@", urls, fixed = TRUE) | # userinfo; defer to rurl
    grepl("[^A-Za-z0-9._~:/?#&=-]", urls) # any char outside the no-op set
}

# Path segments and query allow only characters rurl's `encode` config leaves
# untouched (verified empirically): unreserved + `/` in the path; additionally
# `&` `=` `?` in the query. Anything else (sub-delims, parens, `:` in a path,
# `+`, `;`, ...) is encoded by rurl, so such a URL is not fast-eligible.
url_path_is_noop <- function(path) {
  if (is.null(path) || !nzchar(path)) {
    return(TRUE)
  }
  if (!grepl("^[A-Za-z0-9._~/-]*$", path)) {
    return(FALSE)
  }
  # No dot-segments or empty segments: rurl would collapse `/./`, `/../`, `//`.
  # The leading empty segment from a path's initial `/` is expected, so test for
  # `//` directly rather than via the split.
  if (grepl("//", path, fixed = TRUE)) {
    return(FALSE)
  }
  segs <- strsplit(path, "/", fixed = TRUE)[[1L]]
  !any(segs %in% c(".", ".."))
}

url_query_is_noop <- function(query) {
  is.null(query) || !nzchar(query) || grepl("^[A-Za-z0-9._~&=/?-]*$", query)
}

# A host is fast-eligible only when it is unambiguously a DNS name: ASCII
# letters/digits/dots/hyphens whose rightmost label contains a letter. That
# excludes every IP-literal form (dotted-quad, decimal, hex, IPv6) so the
# security-sensitive `is_ip_host` flag is never guessed here — those defer to
# rurl, which owns IP detection (R/ssrf.R depends on it).
url_host_is_dns_name <- function(host) {
  if (is.null(host) || !nzchar(host)) {
    return(FALSE)
  }
  if (!grepl("^[A-Za-z0-9.-]+$", host)) {
    return(FALSE)
  }
  last <- sub("^.*\\.", "", host)
  grepl("[A-Za-z]", last)
}

# Split a fast-prefiltered URL into components by regex and confirm every one is
# a proven rurl no-op. Returns the component list on success, or NULL to defer
# the URL to rurl. Done by slicing the raw string (not `curl::curl_parse_url`,
# which returns decoded query `params` rather than the raw query) so the
# fast-path components are literally the input's — which, for a no-op URL, is
# exactly what rurl emits.
url_fast_components <- function(url) {
  m <- regmatches(
    url,
    regexec("^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)(/[^?#]*)?", url)
  )[[1L]]
  if (length(m) == 0L) {
    return(NULL) # no scheme://authority — let rurl produce the error row
  }
  scheme <- tolower(m[[2L]])
  if (!scheme %in% c("http", "https")) {
    return(NULL)
  }

  authority <- m[[3L]]
  host <- authority
  port <- NA_integer_
  if (grepl(":", authority, fixed = TRUE)) {
    parts <- strsplit(authority, ":", fixed = TRUE)[[1L]]
    if (length(parts) != 2L || !grepl("^[0-9]+$", parts[[2L]])) {
      return(NULL)
    }
    host <- parts[[1L]]
    port <- as.integer(parts[[2L]])
  }
  if (!url_host_is_dns_name(host)) {
    return(NULL)
  }

  # rurl normalizes a missing path to "/" when a host is present.
  raw_path <- m[[4L]]
  path <- if (is.na(raw_path) || !nzchar(raw_path)) "/" else raw_path
  if (!url_path_is_noop(path)) {
    return(NULL)
  }

  # Query: the slice between the first `?` and the `#`/end. An empty query
  # (`...?` or `...?#`) is ambiguous against rurl's NA, so defer it.
  query <- NA_character_
  if (grepl("?", url, fixed = TRUE)) {
    query <- sub("^[^?]*\\?([^#]*).*$", "\\1", url)
    if (!nzchar(query)) {
      return(NULL)
    }
    if (!url_query_is_noop(query)) {
      return(NULL)
    }
  }

  fragment <- NA_character_
  if (grepl("#", url, fixed = TRUE)) {
    fragment <- sub("^[^#]*#(.*)$", "\\1", url)
  }

  list(
    scheme = scheme,
    host = tolower(host),
    port = port,
    path = path,
    query = query,
    fragment = if (nzchar(fragment %||% "")) fragment else NA_character_
  )
}

# Assemble the rurl-shaped 14-column data.frame for the fast rows. Columns no
# sitemapr consumer reads (domain, tld, clean_url, password, parse_status) are
# left NA / "ok"; the host is a confirmed DNS name so is_ip_host is FALSE. The
# read columns (scheme, host, port, path, query, user, is_ip_host) are
# byte-identical to rurl by the no-op invariant.
url_fast_rows <- function(urls, comp) {
  g <- function(field, default) {
    vapply(comp, function(c) c[[field]] %||% default, default)
  }
  data.frame(
    original_url = as.character(urls),
    scheme = g("scheme", NA_character_),
    host = g("host", NA_character_),
    port = g("port", NA_integer_),
    path = g("path", NA_character_),
    query = g("query", NA_character_),
    fragment = g("fragment", NA_character_),
    user = NA_character_,
    password = NA_character_,
    domain = NA_character_,
    tld = NA_character_,
    is_ip_host = FALSE,
    clean_url = NA_character_,
    parse_status = "ok",
    stringsAsFactors = FALSE
  )
}

#' Assemble sitemapr's canonical sitemap URL (fetch target and identity key)
#'
#' Builds the canonical sitemap URL string from the parsed component set. This
#' single form serves BOTH the fetch target and the dedup/scoping identity key,
#' because for a sitemap source the canonical thing to fetch *is* its identity.
#'
#' Unlike `rurl::clean_url` — which is a display helper that drops port, query,
#' and fragment, and so would produce the wrong fetch URL for a dynamic sitemap
#' endpoint or a paginated `sitemapindex` child (`?page=2`) and the wrong
#' identity for a non-default port — this build keeps the components that
#' matter and canonicalizes the ones that don't (SITE-vrgszbnu):
#'
#' \itemize{
#'   \item \strong{userinfo, host, path} — kept (host already IDNA/lower-cased
#'     and path dot-segment-normalized by `parse_url_adapter()`).
#'   \item \strong{query} — kept verbatim. A sitemap served from a dynamic route
#'     (`sitemap.php?page=2`) or a query-parametrized index child is a distinct
#'     resource; dropping the query would fetch the wrong document. Tracking-
#'     parameter stripping is deliberately NOT attempted (the server is the
#'     authority for what a query means).
#'   \item \strong{port} — kept when explicit and non-default; the scheme's
#'     default port (`:80` for http, `:443` for https) is dropped so that
#'     `https://h:443/s` and `https://h/s` are one identity (the default-port
#'     equivalence bug this fixes).
#'   \item \strong{fragment} — dropped. A fragment is never sent over HTTP and
#'     does not identify a separate fetched resource (RFC 3986 §3.5), so it
#'     belongs to neither the fetch URL nor the identity.
#' }
#'
#' Vectorized over rows.
#'
#' @param parsed A parsed structure from `parse_url_adapter()` (one or many
#'   rows).
#' @return Character vector of canonical sitemap URLs, one per input row.
#' @keywords internal
#' @noRd
build_loc_key <- function(parsed) {
  blank <- function(x) is.na(x) | !nzchar(x)

  scheme <- as.character(parsed$scheme)
  host <- as.character(parsed$host)
  port <- parsed$port
  path <- as.character(parsed$path)
  query <- as.character(parsed$query)
  user <- as.character(parsed$user)

  # Drop the scheme's default port so it is identity-equivalent to no port.
  is_default_port <- (scheme == "http" & port == 80L) |
    (scheme == "https" & port == 443L)
  drop_port <- is.na(port) | (!is.na(is_default_port) & is_default_port)

  userinfo <- ifelse(blank(user), "", paste0(user, "@"))
  port_part <- ifelse(drop_port, "", paste0(":", port))
  path_part <- ifelse(blank(path), "", path)
  query_part <- ifelse(blank(query), "", paste0("?", query))

  paste0(
    scheme,
    "://",
    userinfo,
    host,
    port_part,
    path_part,
    query_part
  )
}
