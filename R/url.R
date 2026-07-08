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
  fc_kept <- NULL
  if (any(fast)) {
    fc <- url_fast_components_vec(urls[fast])
    # Candidates that did not resolve to a proven no-op defer to rurl.
    fast[which(fast)[!fc$resolved]] <- FALSE
    fc_kept <- fc[fc$resolved, , drop = FALSE]
  }

  if (!any(fast)) {
    return(rurl_parse(urls))
  }
  if (all(fast)) {
    return(url_fast_rows(urls, fc_kept))
  }

  # Build both halves on the identical canonical schema, then restore order.
  fast_df <- url_fast_rows(urls[fast], fc_kept)
  slow_df <- rurl_parse(urls[!fast])
  combined <- rbind(fast_df, slow_df)
  combined[order(c(which(fast), which(!fast))), , drop = FALSE]
}

# The canonical URL-component columns every sitemapr consumer reads. Both the
# rurl output and the fast-path frame are projected onto exactly this set before
# they are combined, so sitemapr depends on the columns it uses, not on rurl's
# full schema width: rurl may add columns (as 2.1.0 did: password, domain, tld,
# domain_ascii/unicode, tld_ascii/unicode, clean_url) without breaking the
# fast/slow rbind. rurl must supply every name listed here.
url_adapter_cols <- c(
  "original_url", "scheme", "host", "port", "path", "query",
  "fragment", "user", "is_ip_host", "parse_status"
)

# The pinned rurl call (canonicalization options sitemapr relies on), projected
# onto sitemapr's canonical column set.
rurl_parse <- function(urls) {
  parsed <- rurl::safe_parse_urls(
    urls,
    host_encoding = "idna",
    path_normalization = "both",
    case_handling = "lower_host",
    path_encoding = "encode"
  )
  parsed[, url_adapter_cols, drop = FALSE]
}

# Cheap, vectorized first cut: a URL MIGHT need rurl if it is not pure ASCII, or
# carries a `%` (possible escape normalization), or contains a character rurl
# would percent-encode or that complicates parsing. Returning TRUE only routes a
# URL to rurl; the exact per-component decision is `url_fast_components_vec()`.
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
# Vectorized over a character vector of paths -> logical vector.
url_path_is_noop <- function(path) {
  empty <- is.na(path) | !nzchar(path)
  # No dot-segments or empty segments: rurl would collapse `/./`, `/../`, `//`.
  # `(^|/)[.]{1,2}(/|$)` matches a `.`/`..` segment anywhere (equivalent to the
  # per-segment `%in% c(".", "..")` check); `//` is tested directly.
  ok <- grepl("^[A-Za-z0-9._~/-]*$", path) &
    !grepl("//", path, fixed = TRUE) &
    !grepl("(^|/)[.]{1,2}(/|$)", path)
  empty | (!is.na(ok) & ok)
}

# Vectorized over a character vector of queries -> logical vector.
url_query_is_noop <- function(query) {
  is.na(query) | !nzchar(query) | grepl("^[A-Za-z0-9._~&=/?-]*$", query)
}

# A host is fast-eligible only when it is unambiguously a DNS name: ASCII
# letters/digits/dots/hyphens whose rightmost label contains a letter. That
# excludes every IP-literal form (dotted-quad, decimal, hex, IPv6) so the
# security-sensitive `is_ip_host` flag is never guessed here — those defer to
# rurl, which owns IP detection (R/ssrf.R depends on it). Vectorized over a
# character vector of hosts -> logical vector.
url_host_is_dns_name <- function(host) {
  ok <- !is.na(host) & nzchar(host) & grepl("^[A-Za-z0-9.-]+$", host)
  last <- sub("^.*\\.", "", host)
  ok & grepl("[A-Za-z]", last)
}

url_fast_authority <- function(auth) {
  host <- auth
  port <- rep(NA_integer_, length(auth))
  has_colon <- grepl(":", auth, fixed = TRUE)
  pm <- regmatches(auth, regexec("^([^:]+):([0-9]+)$", auth))
  colon_ok <- lengths(pm) == 3L
  ci <- which(has_colon & colon_ok)
  if (length(ci)) {
    cmat <- do.call(rbind, pm[ci])
    host[ci] <- cmat[, 2L]
    port[ci] <- as.integer(cmat[, 3L])
  }
  list(
    host = host,
    port = port,
    colon_ok = !has_colon | colon_ok
  )
}

url_fast_query <- function(u) {
  has_q <- grepl("?", u, fixed = TRUE)
  query <- rep(NA_character_, length(u))
  query[has_q] <- sub("^[^?]*\\?([^#]*).*$", "\\1", u[has_q])
  invalid <- has_q & (
    is.na(query) | !nzchar(query) | !url_query_is_noop(query)
  )
  list(
    query = query,
    valid = !invalid
  )
}

url_fast_fragment <- function(u) {
  fragment <- rep(NA_character_, length(u))
  has_f <- grepl("#", u, fixed = TRUE)
  fragment[has_f] <- sub("^[^#]*#(.*)$", "\\1", u[has_f])
  fragment[!is.na(fragment) & !nzchar(fragment)] <- NA_character_
  fragment
}

url_fast_empty_components <- function(n) {
  list(
    scheme = rep(NA_character_, n),
    host = rep(NA_character_, n),
    port = rep(NA_integer_, n),
    path = rep(NA_character_, n),
    query = rep(NA_character_, n),
    fragment = rep(NA_character_, n),
    resolved = rep(FALSE, n)
  )
}

url_fast_set_resolved <- function(out, oi, keep, sch, h, p, pth, q, frag) {
  kept <- which(keep)
  gi <- oi[kept]
  out$resolved[gi] <- TRUE
  out$scheme[gi] <- sch[kept]
  out$host[gi] <- tolower(h[kept])
  out$port[gi] <- p[kept]
  out$path[gi] <- pth[kept]
  out$query[gi] <- q[kept]
  out$fragment[gi] <- frag[kept]
  out
}

url_fast_apply_matches <- function(out, u, mm, ok) {
  oi <- which(ok)
  uok <- u[ok]
  mat <- do.call(rbind, mm[ok]) # cols: full, scheme, authority, path
  sch <- tolower(mat[, 2L])
  auth <- mat[, 3L]
  rawpath <- mat[, 4L]

  keep <- sch %in% c("http", "https")
  authority <- url_fast_authority(auth)
  h <- authority$host
  p <- authority$port
  keep <- keep & authority$colon_ok
  keep <- keep & url_host_is_dns_name(h)

  pth <- ifelse(is.na(rawpath) | !nzchar(rawpath), "/", rawpath)
  keep <- keep & url_path_is_noop(pth)

  query <- url_fast_query(uok)
  keep <- keep & query$valid
  url_fast_set_resolved(
    out,
    oi,
    keep,
    sch,
    h,
    p,
    pth,
    query$query,
    url_fast_fragment(uok)
  )
}

# Split fast-prefiltered URLs into components by regex and confirm every one is
# a proven rurl no-op, in a single vectorized pass. Returns a data.frame with
# one row per input URL: the six component columns plus a `resolved` logical
# that is TRUE only where every component is a confirmed no-op (a FALSE row
# defers to rurl; its component cells are NA). Done by slicing the raw string
# (not `curl::curl_parse_url`, which returns decoded query `params` rather than
# the raw query) so the fast-path components are literally the input's — which,
# for a no-op URL, is exactly what rurl emits.
url_fast_components_vec <- function(u) {
  out <- url_fast_empty_components(length(u))
  mm <- regmatches(
    u,
    regexec("^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]+)(/[^?#]*)?", u)
  )
  ok <- lengths(mm) == 4L # full + 3 groups; 0 = no match -> defer to rurl
  if (any(ok)) {
    out <- url_fast_apply_matches(out, u, mm, ok)
  }

  data.frame(
    scheme = out$scheme,
    host = out$host,
    port = out$port,
    path = out$path,
    query = out$query,
    fragment = out$fragment,
    resolved = out$resolved,
    stringsAsFactors = FALSE
  )
}

# Assemble the fast rows onto sitemapr's canonical column set
# (`url_adapter_cols`) from the resolved-component frame
# (`url_fast_components_vec()`, `resolved` rows only). The host is a confirmed
# DNS name so is_ip_host is FALSE; parse_status is "ok". The read columns
# (scheme, host, port, path, query, user, is_ip_host) are
# byte-identical to rurl by the no-op invariant.
url_fast_rows <- function(urls, fc) {
  data.frame(
    original_url = as.character(urls),
    scheme = fc$scheme,
    host = fc$host,
    port = fc$port,
    path = fc$path,
    query = fc$query,
    fragment = fc$fragment,
    user = NA_character_,
    is_ip_host = FALSE,
    parse_status = "ok",
    stringsAsFactors = FALSE
  )[, url_adapter_cols, drop = FALSE]
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
