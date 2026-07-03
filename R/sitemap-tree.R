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
  c(
    "depth",
    "parent_sitemap",
    "sitemap_url",
    "page_count",
    "gzip",
    "status",
    "reason",
    "provenance"
  )
}

# Construct the tree tibble with the stable 8-column contract and coerced types.
# Vectorized; scalar arguments recycle to the `sitemap_url` row count.
sitemap_tree_rows <- function(
  depth,
  parent_sitemap,
  sitemap_url,
  page_count,
  gzip,
  status,
  reason,
  provenance
) {
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
    depth = integer(0),
    parent_sitemap = character(0),
    sitemap_url = character(0),
    page_count = integer(0),
    gzip = logical(0),
    status = character(0),
    reason = character(0),
    provenance = character(0)
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
#' Discovers a site's sitemaps and returns them as a tree: one row per evaluated
#' sitemap, `accepted` or `rejected`, with the columns needed to explain the
#' result. Two input modes select what `x` is:
#'
#' \describe{
#'   \item{`from = "root"` (default)}{`x` is a site-root URL. `sitemap_tree()`
#'     reads robots.txt `Sitemap:` directives (provenance `"robots"`) and tries
#'     the guessed-path catalog (every generic guess first, then
#'     WordPress/Shopify), classifying each candidate. A guessed path that 404s
#'     is a `rejected` `not-found` row, never a validation finding, and a single
#'     unreachable guess never fails the call. Robots rules (`Disallow`/`Allow`)
#'     are never applied — only the `Sitemap:` directive is read (ADR-005). Turn
#'     either source off with `use_robots` / `use_known_paths`.}
#'   \item{`from = "sitemap"`}{`x` is an exact sitemap or sitemapindex URL.
#'     `sitemap_tree()` fetches that one URL (no catalog, no guessing) and, if
#'     it is a `sitemapindex`, expands it. The root row carries provenance
#'     `"seed"`. A fetch or parse failure yields a single `rejected` seed row.}
#' }
#'
#' In both modes each accepted candidate's page count and gzip flag come from
#' the body fetched during discovery, so no source is requested twice, and an
#' accepted `sitemapindex` is expanded recursively (cycle-safe, depth- and
#' count-capped), contributing deeper rows parented to the index with provenance
#' `"child-of-index"`. To discover from sitemap bytes you already fetched
#' yourself (no network for the root), use [sitemap_tree_from_bytes()].
#'
#' @param x A single URL (character). With `from = "root"` a site-root URL (a
#'   bare host is accepted and normalized to `https://` via the shared
#'   site-entrypoint policy); with `from = "sitemap"` an exact sitemap URL.
#' @param from Input mode: `"root"` (default) treats `x` as a site root and
#'   runs discovery; `"sitemap"` treats `x` as an exact sitemap URL and fetches
#'   only that.
#' @param use_robots When `from = "root"`, fetch robots.txt and add every
#'   `Sitemap:` directive it lists (provenance `"robots"`), deduplicated against
#'   the guessed paths. Default `TRUE`. Robots rules (`Disallow`/`Allow`) are
#'   never applied — only the `Sitemap:` directive is read.
#' @param use_known_paths When `from = "root"`, try the guessed-path catalog
#'   (provenance `"guessed-path"`). Default `TRUE`. Set both `use_robots` and
#'   `use_known_paths` to `FALSE` for an empty tree.
#' @param user_agent The User-Agent header for HTTP fetches. Defaults to the
#'   package User-Agent.
#' @param limits Discovery limits (the candidate cap), as from
#'   `discovery_limits()`. Used only when `from = "root"`.
#' @param net_limits Network limits for the per-candidate fetches, as from
#'   `fetch_limits()`.
#' @param index_limits Sitemapindex-expansion bounds, as from `index_limits()`.
#'   Defaults to `index_limits()`.
#' @return A tibble with one row per evaluated sitemap (and per expanded index
#'   child) and columns `depth`, `parent_sitemap`, `sitemap_url`, `page_count`,
#'   `gzip`, `status`, `reason`, and `provenance`. Accepted rows carry a
#'   `page_count`/`gzip`; rejected rows carry their rejection `reason` and `NA`
#'   page count.
#' @seealso [sitemap_tree_from_bytes()] to discover from already-fetched bytes.
#' @export
#' @examples
#' \dontrun{
#' # Discover a site's sitemaps from its root URL as a tree of candidates.
#' sitemap_tree("https://example.com")
#'
#' # A bare host is accepted and normalized to https://.
#' sitemap_tree("example.com")
#'
#' # Fetch and expand one exact sitemap URL, skipping the guessed-path catalog.
#' sitemap_tree("https://example.com/sitemap_index.xml", from = "sitemap")
#' }
sitemap_tree <- function(
  x,
  from = c("root", "sitemap"),
  use_robots = TRUE,
  use_known_paths = TRUE,
  user_agent = default_user_agent(),
  limits = discovery_limits(),
  net_limits = fetch_limits(),
  index_limits = NULL
) {
  from <- match.arg(from)
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }

  if (identical(from, "sitemap")) {
    return(seed_tree_from_url(
      x,
      user_agent = user_agent,
      net_limits = net_limits,
      index_limits = index_limits
    ))
  }

  disc <- discover_candidates(
    x,
    limits = limits,
    user_agent = user_agent,
    net_limits = net_limits,
    use_known_paths = use_known_paths,
    use_robots = use_robots
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
        candidate_url,
        parsed$children,
        depth = 0L,
        user_agent = user_agent,
        limits = index_limits,
        net_limits = net_limits
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
