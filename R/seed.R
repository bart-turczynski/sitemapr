# Explicit-seed discovery (SITE-roktqpyi).
#
# Build a discovery tree from a single explicit seed instead of the guessed-path
# catalog: either an exact sitemap/sitemapindex URL (fetched once, no catalog)
# or already-fetched sitemap bytes (parsed in memory). A sitemapindex seed is
# expanded RECURSIVELY over the network with the same bounds as `sitemap_tree()`
# and `read_sitemap()` (cycle-safe, depth- and child-count-capped). Every seed
# root row carries provenance `"seed"`; children keep `"child-of-index"`.
#
# Reused internals (do NOT reimplement here):
#   create_source_records()  R/input.R           input -> normalized record
#   fetch_source()           R/fetch.R           bounded SSRF-safe fetch
#   classify_candidate()     R/discovery.R       fetch record -> status/reason
#   parse_dispatch()         R/read-sitemap.R    body bytes -> list(kind, ...)
#   expand_index()           R/index-expansion.R recursive bounded expansion
#   count_pages()            R/sitemap-tree.R    parsed doc -> page/child count
#   sniff_format()           R/sniff.R           raw bytes -> format string

# The depth-0 seed root row (accepted) plus its recursive expansion. An index
# seed contributes deeper `child-of-index` rows; a urlset/text seed is a single
# row. `root_url` is the seed's own URL (redirect-resolved for a fetched URL,
# the caller-supplied source URL for bytes) and seeds the expansion cycle set.
seed_accepted_tree <- function(
  parsed,
  root_url,
  gzip,
  user_agent,
  index_limits,
  net_limits,
  policy
) {
  root_row <- sitemap_tree_rows(
    depth = 0L,
    parent_sitemap = NA_character_,
    sitemap_url = root_url,
    page_count = count_pages(parsed),
    gzip = gzip,
    status = "accepted",
    reason = NA_character_,
    provenance = "seed"
  )
  if (!identical(parsed$kind, "sitemapindex")) {
    return(root_row)
  }
  ex <- expand_index(
    root_url,
    parsed$children,
    depth = 0L,
    user_agent = user_agent,
    limits = index_limits,
    net_limits = net_limits,
    policy = policy
  )
  rbind(root_row, ex$tree)
}

# A single rejected depth-0 seed row: the seed could not be fetched or parsed.
# Keeps the tree contract (a tibble is always returned) rather than erroring on
# a content/transport failure, mirroring `sitemap_tree()`'s candidate handling.
seed_rejected_tree <- function(root_url, reason) {
  sitemap_tree_rows(
    depth = 0L,
    parent_sitemap = NA_character_,
    sitemap_url = root_url,
    page_count = NA_integer_,
    gzip = NA,
    status = "rejected",
    reason = reason,
    provenance = "seed"
  )
}

# Fetch one seed URL record gracefully: an SSRF block or transport failure
# becomes a rejected outcome (never fails the call), and the expected non-2xx
# warning is muffled. Reuses `classify_candidate()` for the reason mapping,
# overriding its accepted reason (a seed is not a catalog hit) to NA. Returns
# `list(rec, status, reason)`; `rec` is the fetch record on accept, else NULL.
seed_fetch <- function(rec_row, user_agent, net_limits, policy) {
  out <- tryCatch(
    withCallingHandlers(
      fetch_source(
        rec_row,
        user_agent = user_agent,
        limits = net_limits,
        policy = policy
      ),
      sitemapr_http_error = function(w) invokeRestart("muffleWarning")
    ),
    sitemapr_ssrf_blocked = function(e) {
      structure(list(reason = "blocked"), class = "seed_abort")
    },
    error = function(e) {
      structure(list(reason = "unreachable"), class = "seed_abort")
    }
  )
  if (inherits(out, "seed_abort")) {
    return(list(rec = NULL, status = "rejected", reason = out$reason))
  }
  cls <- classify_candidate("generic", NA_character_, out)
  if (identical(cls$status, "accepted")) {
    list(rec = out, status = "accepted", reason = NA_character_)
  } else {
    list(rec = NULL, status = "rejected", reason = cls$reason)
  }
}

# Build a seed tree from an exact sitemap/sitemapindex URL: normalize the URL,
# fetch it once (no catalog), parse the body, and expand a sitemapindex. A
# fetch/HTTP/parse failure yields a single rejected seed row.
seed_tree_from_url <- function(
  x,
  user_agent,
  net_limits,
  index_limits,
  policy
) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    rlang::abort(
      "`x` must be a single non-empty sitemap URL when `from = \"sitemap\"`.",
      class = "sitemapr_bad_input"
    )
  }

  rec_row <- create_source_records(x, as = "sitemap")
  url <- rec_row$normalized_url[[1L]]

  fetched <- seed_fetch(rec_row, user_agent, net_limits, policy)
  if (identical(fetched$status, "rejected")) {
    return(seed_rejected_tree(url, fetched$reason))
  }

  rec <- fetched$rec
  parsed <- tryCatch(
    parse_dispatch(attr(rec, "body"), source_sitemap = rec$final_url),
    error = function(e) NULL
  )
  if (is.null(parsed)) {
    return(seed_rejected_tree(rec$final_url, "unparseable"))
  }

  gzip <- identical(as.character(rec$format), "gzip")
  seed_accepted_tree(
    parsed,
    rec$final_url,
    gzip,
    user_agent,
    index_limits,
    net_limits,
    policy
  )
}

seed_bytes_input <- function(bytes) {
  if (is.character(bytes) && length(bytes) == 1L && !is.na(bytes)) {
    return(charToRaw(bytes))
  }
  if (is.raw(bytes)) {
    return(bytes)
  }
  rlang::abort(
    "`bytes` must be a raw vector or a length-1 character string.",
    class = "sitemapr_bad_input"
  )
}

seed_source_url_input <- function(source_url) {
  if (
    is.character(source_url) &&
      length(source_url) == 1L &&
      !is.na(source_url) &&
      nzchar(source_url)
  ) {
    return(source_url)
  }
  rlang::abort(
    "`source_url` must be a single non-empty URL.",
    class = "sitemapr_bad_input"
  )
}

seed_parse_bytes <- function(bytes, source_url) {
  tryCatch(
    parse_dispatch(bytes, source_sitemap = source_url),
    error = function(e) NULL
  )
}

#' Discover a site's sitemaps from already-fetched bytes
#'
#' Builds the same discovery tree as [sitemap_tree()], but from sitemap bytes
#' you have already fetched yourself rather than from a site root. This is the
#' explicit-seed entry point for sources `sitemap_tree()` cannot fetch directly
#' — for example a site behind a TLS-fingerprint bot wall, whose sitemap you
#' retrieved through a browser or proxy. The root document is parsed in memory
#' (no network request for it); if it is a `sitemapindex`, its child sitemaps
#' are still fetched and expanded over the network, cycle-safe and depth- and
#' count-capped, exactly as [sitemap_tree()] and [read_sitemap()] do.
#'
#' A leaf `urlset`/text seed performs no network access at all. The root row
#' carries `provenance = "seed"`; expansion children carry `"child-of-index"`.
#' Content that cannot be parsed yields a single `rejected` seed row rather than
#' an error.
#'
#' @param bytes The raw sitemap document: a raw vector, or a length-1 character
#'   string of the sitemap text. Transparent gzip is inflated automatically.
#' @param source_url The URL the bytes came from (length-1 character). Used as
#'   the root row's `sitemap_url`, as the cycle-detection identity for
#'   expansion, and as the parent attribution for expanded children.
#' @param user_agent The User-Agent header for the child fetches an index seed
#'   triggers. Defaults to the package User-Agent.
#' @param net_limits Network limits for the child fetches, as from
#'   `fetch_limits()`.
#' @param index_limits Sitemapindex-expansion bounds, as from `index_limits()`.
#'   Defaults to `index_limits()`.
#' @param policy A request policy applied to every index-child HTTP hop.
#'   Defaults to the no-op policy.
#' @return A tibble with the same 8-column contract as [sitemap_tree()]:
#'   `depth`, `parent_sitemap`, `sitemap_url`, `page_count`, `gzip`, `status`,
#'   `reason`, and `provenance`.
#' @seealso [sitemap_tree()] for discovery from a site root or an exact URL.
#' @export
#' @examples
#' # Parse an already-fetched leaf sitemap with no network access.
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   "<url><loc>https://example.com/</loc></url>",
#'   "<url><loc>https://example.com/about</loc></url>",
#'   "</urlset>"
#' )
#' sitemap_tree_from_bytes(xml, source_url = "https://example.com/sitemap.xml")
sitemap_tree_from_bytes <- function(
  bytes,
  source_url,
  user_agent = default_user_agent(),
  net_limits = fetch_limits(),
  index_limits = NULL,
  policy = request_policy()
) {
  bytes <- seed_bytes_input(bytes)
  source_url <- seed_source_url_input(source_url)
  index_limits <- resolve_index_limits(index_limits)

  gzip <- identical(sniff_format(bytes), "gzip")
  parsed <- seed_parse_bytes(bytes, source_url)
  if (is.null(parsed)) {
    return(seed_rejected_tree(source_url, "unparseable"))
  }

  seed_accepted_tree(
    parsed,
    source_url,
    gzip,
    user_agent,
    index_limits,
    net_limits,
    policy
  )
}
