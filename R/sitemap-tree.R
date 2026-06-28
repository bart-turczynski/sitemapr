# sitemap_tree(): the discovery/index structure (architecture.md §7).
#
# Public entry point from a site root to the discovery tree: one row per
# evaluated guessed-path candidate, accepted or rejected, with enough columns
# to explain discovery (depth, parent, URL, page count, gzip, status, reason,
# provenance). Accepted candidates have page_count/gzip populated from the body
# already fetched during discovery (no second request); rejected candidates
# carry their rejection reason. Recursive index expansion — which adds deeper,
# parented rows to this same structure — is the separate index-expansion slice
# (SITE-mzbuuyfy); v1 discovery rows are all depth 0 with no parent.
#
# Reused internals (do NOT reimplement here):
#   discover_candidates()  R/discovery.R     candidate fetch + classification
#   parse_dispatch()       R/read-sitemap.R  body bytes -> list(kind, rows, ...)

# The tree row-schema column contract, in documented order.
sitemap_tree_cols <- function() {
  c("depth", "parent_sitemap", "sitemap_url", "page_count", "gzip",
    "status", "reason", "provenance")
}

# Construct the tree tibble with the stable 8-column contract and coerced types.
# Vectorized; scalar arguments recycle to the `sitemap_url` row count.
sitemap_tree_rows <- function(depth, parent_sitemap, sitemap_url, page_count,
                              gzip, status, reason, provenance) {
  tibble::tibble(
    depth = as.integer(depth),
    parent_sitemap = as.character(parent_sitemap),
    sitemap_url = as.character(sitemap_url),
    page_count = as.integer(page_count),
    gzip = as.logical(gzip),
    status = as.character(status),
    reason = as.character(reason),
    provenance = as.character(provenance)
  )
}

# A 0-row tree tibble carrying the column contract and types.
empty_sitemap_tree <- function() {
  sitemap_tree_rows(
    depth = integer(0), parent_sitemap = character(0),
    sitemap_url = character(0), page_count = integer(0),
    gzip = logical(0), status = character(0),
    reason = character(0), provenance = character(0)
  )
}

# Count the pages a parsed document represents: the URL count for a urlset/text
# sitemap, or the child-sitemap count for an index. Returns NA on a body that
# cannot be parsed (e.g. unsupported content behind a 200).
count_pages <- function(parsed) {
  if (identical(parsed$kind, "sitemapindex")) {
    nrow(parsed$children)
  } else {
    nrow(parsed$rows)
  }
}

#' Discover a site's sitemaps as a tree
#'
#' From a site-root URL, tries the guessed-path catalog (every generic guess
#' first, then WordPress/Shopify), classifies each candidate as `accepted` or
#' `rejected`, and returns the result as a discovery tree: one row per evaluated
#' candidate. A guessed path that 404s is a `rejected` `not-found` row, never a
#' validation finding, and a single unreachable guess never fails the call.
#' robots.txt is not consulted in v1.
#'
#' Each accepted candidate's page count and gzip flag are taken from the body
#' fetched during discovery, so no source is requested twice. v1 discovery rows
#' are all depth 0 with no parent; recursive index expansion contributes the
#' deeper, parented rows separately.
#'
#' @param x A single site-root URL (character). A bare host is accepted and
#'   normalized to `https://` via the shared site-entrypoint policy.
#' @param user_agent The User-Agent header for HTTP fetches. Defaults to the
#'   package User-Agent.
#' @param limits Discovery limits (the candidate cap), as from
#'   `discovery_limits()`.
#' @param net_limits Network limits for the per-candidate fetches, as from
#'   `fetch_limits()`.
#' @return A tibble with one row per evaluated candidate and columns `depth`,
#'   `parent_sitemap`, `sitemap_url`, `page_count`, `gzip`, `status`, `reason`,
#'   and `provenance`. Accepted rows carry a `page_count`/`gzip`; rejected rows
#'   carry their rejection `reason` and `NA` page count.
#' @export
sitemap_tree <- function(x,
                         user_agent = default_user_agent(),
                         limits = discovery_limits(),
                         net_limits = fetch_limits()) {
  disc <- discover_candidates(
    x, limits = limits, user_agent = user_agent, net_limits = net_limits
  )
  records <- attr(disc, "records")
  n <- nrow(disc)

  page_count <- rep(NA_integer_, n)
  gzip <- rep(NA, n)

  for (i in seq_len(n)) {
    rec <- records[[i]]
    if (is.null(rec)) {
      next
    }
    gzip[i] <- identical(as.character(rec$format), "gzip")
    if (identical(disc$status[[i]], "accepted")) {
      page_count[i] <- tryCatch(
        count_pages(parse_dispatch(
          attr(rec, "body"), source_sitemap = disc$candidate_url[[i]]
        )),
        error = function(e) NA_integer_
      )
    }
  }

  sitemap_tree_rows(
    depth = 0L,
    parent_sitemap = NA_character_,
    sitemap_url = disc$candidate_url,
    page_count = page_count,
    gzip = gzip,
    status = disc$status,
    reason = disc$reason,
    provenance = disc$provenance
  )
}
