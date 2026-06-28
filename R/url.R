#' Parse URLs into sitemapr's canonical component set
#'
#' Thin wrapper over `rurl::safe_parse_urls()` that pins the canonicalization
#' options sitemapr relies on (IDNA/Punycode host output, dot-segment + slash
#' path normalization, lower-cased host). URLs are passed through verbatim;
#' entrypoint scheme policy (bare domain to `https://`) belongs to a later
#' unit, not here. The untouched input is preserved in `original_url`.
#'
#' @param urls Character vector of URL strings.
#' @return A data.frame with one row per input URL, including at least
#'   `original_url`, `scheme`, `host`, `port`, `path`, `query`, `fragment`,
#'   `user`, `is_ip_host`, and `parse_status`.
#' @keywords internal
#' @noRd
parse_url_adapter <- function(urls) {
  rurl::safe_parse_urls(
    urls,
    host_encoding = "idna",
    path_normalization = "both",
    case_handling = "lower_host"
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
    scheme, "://",
    userinfo,
    host,
    port_part,
    path_part,
    query_part
  )
}
