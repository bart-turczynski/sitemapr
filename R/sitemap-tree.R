# sitemap_tree(): the discovery/index structure (architecture.md §7).
#
# Public entry point from a site root to the discovery tree: one row per
# evaluated guessed-path candidate, accepted or rejected, with enough columns
# to explain discovery (depth, parent, URL, page count, gzip, status, reason,
# provenance). Accepted candidates have page_count/gzip populated from the body
# already fetched during discovery (no second request); rejected candidates
# carry their rejection reason. An accepted candidate that is a sitemapindex is
# expanded recursively by the index-expansion engine, which adds deeper,
# parented rows (depth >= 1, provenance "child-of-index") to this structure.
#
# Reused internals (do NOT reimplement here):
#   discover_candidates()  R/discovery.R        candidate fetch + classification
#   parse_dispatch()       R/read-sitemap.R     body bytes -> list(kind, rows)
#   expand_index()         R/index-expansion.R  recursive bounded expansion

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
# sitemap, or the child-sitemap count for an index.
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
#' fetched during discovery, so no source is requested twice. Discovered
#' candidates are depth-0 rows with no parent; an accepted candidate that is a
#' `sitemapindex` is expanded recursively (cycle-safe, depth- and count-capped),
#' contributing deeper rows parented to the index, with provenance
#' `"child-of-index"`.
#'
#' @param x A single site-root URL (character). A bare host is accepted and
#'   normalized to `https://` via the shared site-entrypoint policy.
#' @param user_agent The User-Agent header for HTTP fetches. Defaults to the
#'   package User-Agent.
#' @param limits Discovery limits (the candidate cap), as from
#'   `discovery_limits()`.
#' @param net_limits Network limits for the per-candidate fetches, as from
#'   `fetch_limits()`.
#' @param index_limits Sitemapindex-expansion bounds, as from `index_limits()`.
#'   Defaults to `index_limits()`.
#' @return A tibble with one row per evaluated candidate (and per expanded index
#'   child) and columns `depth`, `parent_sitemap`, `sitemap_url`, `page_count`,
#'   `gzip`, `status`, `reason`, and `provenance`. Accepted rows carry a
#'   `page_count`/`gzip`; rejected rows carry their rejection `reason` and `NA`
#'   page count.
#' @export
sitemap_tree <- function(x,
                         user_agent = default_user_agent(),
                         limits = discovery_limits(),
                         net_limits = fetch_limits(),
                         index_limits = NULL) {
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }
  disc <- discover_candidates(
    x, limits = limits, user_agent = user_agent, net_limits = net_limits
  )
  records <- attr(disc, "records")
  n <- nrow(disc)

  page_count <- rep(NA_integer_, n)
  gzip <- rep(NA, n)
  expansion_parts <- list()

  for (i in seq_len(n)) {
    rec <- records[[i]]
    if (is.null(rec)) {
      next
    }
    gzip[i] <- identical(as.character(rec$format), "gzip")
    if (!identical(disc$status[[i]], "accepted")) {
      next
    }

    candidate_url <- disc$candidate_url[[i]]
    parsed <- tryCatch(
      parse_dispatch(attr(rec, "body"), source_sitemap = candidate_url),
      error = function(e) NULL
    )
    if (is.null(parsed)) {
      next
    }
    page_count[i] <- count_pages(parsed)

    # An accepted index candidate contributes deeper, parented rows.
    if (identical(parsed$kind, "sitemapindex")) {
      ex <- expand_index(
        candidate_url, parsed$children, depth = 0L,
        user_agent = user_agent, limits = index_limits, net_limits = net_limits
      )
      expansion_parts[[length(expansion_parts) + 1L]] <- ex$tree
    }
  }

  base <- sitemap_tree_rows(
    depth = 0L,
    parent_sitemap = NA_character_,
    sitemap_url = disc$candidate_url,
    page_count = page_count,
    gzip = gzip,
    status = disc$status,
    reason = disc$reason,
    provenance = disc$provenance
  )

  if (length(expansion_parts) > 0L) {
    do.call(rbind, c(list(base), expansion_parts))
  } else {
    base
  }
}
