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

#' Assemble sitemapr's full-URL identity key
#'
#' Builds the dedup/scoping key string from the parsed component set. Unlike
#' `rurl::clean_url`, this key retains port, query, fragment, and userinfo,
#' all of which are meaningful for sitemap duplicate detection and fetch URL
#' assembly. Absent components are omitted cleanly. Vectorized over rows.
#'
#' @param parsed A parsed structure from `parse_url_adapter()` (one or many
#'   rows).
#' @return Character vector of canonical identity keys, one per input row.
#' @keywords internal
#' @noRd
build_loc_key <- function(parsed) {
  blank <- function(x) is.na(x) | !nzchar(x)

  scheme <- as.character(parsed$scheme)
  host <- as.character(parsed$host)
  port <- parsed$port
  path <- as.character(parsed$path)
  query <- as.character(parsed$query)
  fragment <- as.character(parsed$fragment)
  user <- as.character(parsed$user)

  userinfo <- ifelse(blank(user), "", paste0(user, "@"))
  port_part <- ifelse(is.na(port), "", paste0(":", port))
  path_part <- ifelse(blank(path), "", path)
  query_part <- ifelse(blank(query), "", paste0("?", query))
  fragment_part <- ifelse(blank(fragment), "", paste0("#", fragment))

  paste0(
    scheme, "://",
    userinfo,
    host,
    port_part,
    path_part,
    query_part,
    fragment_part
  )
}
