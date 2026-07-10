# Bounded sitemapindex expansion (Index-expansion slice; architecture.md §4,
# docs/findings-contract.md INDEX_* codes).
#
# A top-level `sitemapindex` is expanded by fetching each child sitemap, parsing
# it, and attributing its rows to the child URL. Expansion is RECURSIVE but
# strictly bounded: a maximum depth, a per-index child-count cap, and cycle
# detection on the full-URL identity key together guarantee the traversal
# terminates and never materializes an unbounded global tree.
#
# Layering (architecture.md §3). This engine runs inside the parse API
# (`read_sitemap()` / `sitemap_tree()`), so the bounded-traversal events it
# detects are recorded as `problems` (the code-free parse companion), never as
# findings. The stable INDEX_* finding codes (INDEX_CYCLE_DETECTED,
# INDEX_DEPTH_EXCEEDED, INDEX_CHILD_COUNT_EXCEEDED, SITEMAP_INDEX_NESTED) are
# emitted later by `validate_sitemap()` (Layer F), which maps these problems to
# the findings contract.
#
# Reused internals (do NOT reimplement here):
#   fetch_source()          R/fetch.R          child fetch + metadata record
#   parse_dispatch()        R/read-sitemap.R   body bytes -> list(kind, rows...)
#   build_loc_key()         R/url.R            full-URL identity key
#   parse_url_adapter()     R/url.R            canonical URL component parse
#   parse_problems()        R/problems.R       problems companion constructor

#' Default limits for sitemapindex expansion
#'
#' Returns the configurable bounds the index-expansion engine applies while
#' recursively expanding a `sitemapindex`. Both are safety bounds, not protocol
#' rules: they keep a hostile or accidentally huge index tree from triggering an
#' unbounded burst of requests or unbounded recursion.
#'
#' `max_depth` counts levels below the root index: the root index is depth 0,
#' its children are depth 1, and an index whose children would land beyond
#' `max_depth` is not descended (an `INDEX_DEPTH_EXCEEDED` event).
#' `max_children` caps how many child entries one index contributes after dedup;
#' entries beyond the cap are dropped (an `INDEX_CHILD_COUNT_EXCEEDED` event).
#' `max_total_sitemaps` and `max_total_urls` are TRAVERSAL-WIDE aggregate
#' budgets spanning the whole recursive expansion: the first caps how many child
#' sitemaps are fetched in total (an `INDEX_TOTAL_SITEMAPS_EXCEEDED` event), the
#' second caps how many URL rows are gathered in total (an
#' `INDEX_TOTAL_URLS_EXCEEDED` event). Both default to `Inf` (no aggregate
#' bound), preserving the historical behavior; when a budget is reached the
#' traversal stops and returns the accumulated PARTIAL result.
#'
#' @param max_depth Maximum recursion depth below the root index (integer).
#'   Resolves from the argument, then `getOption("sitemapr.max_index_depth")`,
#'   then the default of 3.
#' @param max_children Maximum number of distinct child entries expanded per
#'   index (integer). Resolves from the argument, then
#'   `getOption("sitemapr.max_index_children")`, then the default of 50 000 (the
#'   sitemap-protocol per-index entry limit).
#' @param max_total_sitemaps Maximum number of child sitemaps fetched across the
#'   entire traversal (numeric). Resolves from the argument, then
#'   `getOption("sitemapr.max_total_sitemaps")`, then the default of `Inf` (no
#'   aggregate bound). Kept numeric so `Inf` is representable.
#' @param max_total_urls Maximum number of URL rows gathered across the entire
#'   traversal (numeric). Resolves from the argument, then
#'   `getOption("sitemapr.max_total_urls")`, then the default of `Inf` (no
#'   aggregate bound). Kept numeric so `Inf` is representable.
#' @return A named list of limits with coerced types.
#' @keywords internal
#' @noRd
index_limits <- function(
  max_depth = getOption("sitemapr.max_index_depth", 3L),
  max_children = getOption("sitemapr.max_index_children", 50000L),
  max_total_sitemaps = getOption("sitemapr.max_total_sitemaps", Inf),
  max_total_urls = getOption("sitemapr.max_total_urls", Inf)
) {
  list(
    max_depth = as.integer(max_depth),
    max_children = as.integer(max_children),
    max_total_sitemaps = as.numeric(max_total_sitemaps),
    max_total_urls = as.numeric(max_total_urls)
  )
}

resolve_index_limits <- function(limits) {
  if (is.null(limits)) {
    return(index_limits())
  }
  limits
}

# Full-URL identity key for one URL: the canonical form used for cycle detection
# and child deduplication. Mirrors discovery's loc-key composition (parse via
# the URL adapter, then build the identity key; see R/discovery.R) so an index
# child and a discovery candidate that denote the same resource share a key.
index_loc_key <- function(url) {
  build_loc_key(parse_url_adapter(url))
}

# Record one index-expansion tree row into the accumulator. `provenance` is
# "child-of-index" for every node reached by expansion (the parent is the index
# that listed it); `page_count`/`gzip` are NA for nodes never fetched.
add_tree_row <- function(
  acc,
  depth,
  parent_sitemap,
  sitemap_url,
  page_count = NA_integer_,
  gzip = NA,
  status,
  reason = NA_character_
) {
  acc$tree[[length(acc$tree) + 1L]] <- sitemap_tree_rows(
    depth = depth,
    parent_sitemap = parent_sitemap,
    sitemap_url = sitemap_url,
    page_count = page_count,
    gzip = gzip,
    status = status,
    reason = reason,
    provenance = "child-of-index"
  )
}

# Record one index-expansion problem into the accumulator (severity "warning",
# code-free per the problems!=findings invariant; see file header).
add_index_problem <- function(acc, category, subject_ref, message) {
  acc$problems[[length(acc$problems) + 1L]] <- parse_problems(
    severity = "warning",
    category = category,
    subject_ref = subject_ref,
    message = message
  )
}

# Traversal-wide aggregate-budget gate, evaluated at the top of every child
# loop (so it spans nested recursion via the shared accumulator). Returns TRUE
# once a budget stops the traversal, recording a single code-free problem the
# first time. The sitemap-count budget is enforced here (before fetching one
# more child); the URL-row budget is enforced in `add_leaf_index_child()`, which
# knows a leaf's row count and sets `acc$stopped` for this gate to honor.
index_budget_stop <- function(acc, parent_url, limits) {
  if (isTRUE(acc$stopped)) {
    return(TRUE)
  }
  if (acc$total_sitemaps >= limits$max_total_sitemaps) {
    add_index_problem(
      acc,
      "index-expansion",
      parent_url,
      sprintf(
        paste0(
          "Aggregate sitemap budget reached: %d child sitemaps fetched ",
          "(max_total_sitemaps = %s); traversal stopped, partial result."
        ),
        acc$total_sitemaps,
        format(limits$max_total_sitemaps)
      )
    )
    acc$stopped <- TRUE
    return(TRUE)
  }
  FALSE
}

# Deduplicate an index's children on the full-URL identity key (keeping catalog
# order) and apply the per-index child-count cap. The same child listed twice is
# fetched and expanded exactly once; overflow beyond the cap is dropped with one
# recorded event. Returns `list(locs, keys)` of the survivors.
dedup_and_cap_children <- function(locs, parent_url, limits, acc) {
  keys <- vapply(locs, index_loc_key, character(1L))
  keep <- !duplicated(keys)
  locs <- locs[keep]
  keys <- keys[keep]

  if (length(locs) > limits$max_children) {
    add_index_problem(
      acc,
      "index-expansion",
      parent_url,
      sprintf(
        "Sitemap index %s lists %d children; expanding the first %d (cap).",
        parent_url,
        length(locs),
        limits$max_children
      )
    )
    locs <- locs[seq_len(limits$max_children)]
    keys <- keys[seq_len(limits$max_children)]
  }

  list(locs = locs, keys = keys)
}

# Pre-fetch reject gates for one child, evaluated in order. Returns a rejection
# reason (`"cycle"` / `"depth-exceeded"`) and records the matching problem, or
# `NA_character_` when the child is fetchable. Cycle detection runs first and
# before any fetch, so a self-reference or A -> B -> A loop never recurses.
index_child_reject <- function(child_url, key, child_depth, limits, acc) {
  if (key %in% acc$visited) {
    add_index_problem(
      acc,
      "index-expansion",
      child_url,
      sprintf(
        "Sitemap index cycle: %s already visited; not followed.",
        child_url
      )
    )
    return("cycle")
  }

  if (child_depth > limits$max_depth) {
    add_index_problem(
      acc,
      "index-expansion",
      child_url,
      sprintf(
        "Sitemap index depth limit (%d) exceeded at %s; not followed.",
        limits$max_depth,
        child_url
      )
    )
    return("depth-exceeded")
  }

  NA_character_
}

index_unfetchable_child <- function(acc, child_url, child_depth, parent_url) {
  add_index_problem(
    acc,
    "fetch",
    child_url,
    sprintf("Child sitemap %s could not be fetched; skipped.", child_url)
  )
  add_tree_row(
    acc,
    child_depth,
    parent_url,
    child_url,
    status = "rejected",
    reason = "unfetchable"
  )
}

index_http_error_child <- function(acc, crec, child_depth, parent_url) {
  add_index_problem(
    acc,
    "fetch",
    crec$final_url,
    sprintf(
      "Child sitemap %s returned HTTP %s; skipped.",
      crec$final_url,
      crec$status
    )
  )
  add_tree_row(
    acc,
    child_depth,
    parent_url,
    crec$final_url,
    status = "rejected",
    reason = "http-error"
  )
}

index_unparseable_child <- function(acc, final_url, child_depth, parent_url) {
  add_index_problem(
    acc,
    "classification",
    final_url,
    sprintf("Child sitemap %s could not be parsed; skipped.", final_url)
  )
  add_tree_row(
    acc,
    child_depth,
    parent_url,
    final_url,
    status = "rejected",
    reason = "unparseable"
  )
}

# Fetch one child sitemap and parse it, recording its source metadata and any
# fetch/HTTP/parse failure as a problem + rejected tree row. Returns
# `list(crec, cparsed)` on success, or `NULL` when the child was skipped (the
# caller advances to the next child). The child's identity key is assumed
# already added to `acc$visited` by the caller; the redirect-resolved final URL
# is keyed here so a redirect onto an already-visited resource is caught.
fetch_and_parse_child <- function(
  child_url,
  child_depth,
  parent_url,
  user_agent,
  net_limits,
  policy,
  acc
) {
  crec <- tryCatch(
    fetch_source(
      child_url,
      user_agent = user_agent,
      limits = net_limits,
      policy = policy
    ),
    error = function(e) NULL
  )
  if (is.null(crec)) {
    index_unfetchable_child(acc, child_url, child_depth, parent_url)
    return(NULL)
  }
  acc$sources[[length(acc$sources) + 1L]] <- crec
  acc$total_sitemaps <- acc$total_sitemaps + 1L
  # A redirected child may resolve to an already-visited resource; key both.
  acc$visited <- c(acc$visited, index_loc_key(crec$final_url))

  if (!is.na(crec$error_class)) {
    index_http_error_child(acc, crec, child_depth, parent_url)
    return(NULL)
  }

  cparsed <- tryCatch(
    parse_dispatch(attr(crec, "body"), source_sitemap = crec$final_url),
    error = function(e) NULL
  )
  if (is.null(cparsed)) {
    index_unparseable_child(acc, crec$final_url, child_depth, parent_url)
    return(NULL)
  }

  list(crec = crec, cparsed = cparsed)
}

add_nested_index_child <- function(
  crec,
  cparsed,
  child_depth,
  parent_url,
  user_agent,
  limits,
  net_limits,
  policy,
  acc,
  gzip
) {
  add_index_problem(
    acc,
    "index-expansion",
    crec$final_url,
    sprintf(
      "Nested sitemap index at %s; expanded with a warning.",
      crec$final_url
    )
  )
  add_tree_row(
    acc,
    child_depth,
    parent_url,
    crec$final_url,
    page_count = nrow(cparsed$children),
    gzip = gzip,
    status = "accepted"
  )
  expand_index_node(
    crec$final_url,
    cparsed$children,
    child_depth,
    user_agent,
    limits,
    net_limits,
    policy,
    acc
  )
}

add_leaf_index_child <- function(
  crec,
  cparsed,
  child_depth,
  parent_url,
  limits,
  acc,
  gzip
) {
  n <- nrow(cparsed$rows)
  # Stop before emitting rows that would breach the aggregate URL budget: the
  # leaf is left out whole (never partially), so the partial result stays
  # internally consistent, and the leaf is recorded as a rejected tree node.
  if (acc$total_urls + n > limits$max_total_urls) {
    add_index_problem(
      acc,
      "index-expansion",
      crec$final_url,
      sprintf(
        paste0(
          "Aggregate URL budget reached: %d URL rows gathered, %d more from ",
          "%s would breach max_total_urls = %s; traversal stopped, partial ",
          "result."
        ),
        acc$total_urls,
        n,
        crec$final_url,
        format(limits$max_total_urls)
      )
    )
    acc$stopped <- TRUE
    add_tree_row(
      acc,
      child_depth,
      parent_url,
      crec$final_url,
      page_count = n,
      gzip = gzip,
      status = "rejected",
      reason = "url-budget"
    )
    return(invisible(NULL))
  }
  acc$rows[[length(acc$rows) + 1L]] <- cparsed$rows
  acc$total_urls <- acc$total_urls + n
  add_tree_row(
    acc,
    child_depth,
    parent_url,
    crec$final_url,
    page_count = n,
    gzip = gzip,
    status = "accepted"
  )
}

expand_index_child <- function(
  child_url,
  child_depth,
  parent_url,
  user_agent,
  limits,
  net_limits,
  policy,
  acc
) {
  res <- fetch_and_parse_child(
    child_url,
    child_depth,
    parent_url,
    user_agent,
    net_limits,
    policy,
    acc
  )
  if (is.null(res)) {
    return(invisible(NULL))
  }

  crec <- res$crec
  cparsed <- res$cparsed
  gzip <- identical(as.character(crec$format), "gzip")

  if (identical(cparsed$kind, "sitemapindex")) {
    add_nested_index_child(
      crec, cparsed, child_depth, parent_url, user_agent, limits, net_limits,
      policy, acc, gzip
    )
    return(invisible(NULL))
  }

  add_leaf_index_child(
    crec, cparsed, child_depth, parent_url, limits, acc, gzip
  )
  invisible(NULL)
}

# Expand one already-parsed sitemapindex node's children into the accumulator,
# recursing into nested indexes. `parent_url` is the index that listed these
# children; `parent_depth` is that index's depth (its children land at
# `parent_depth + 1`). The accumulator `acc` is an environment carrying the
# growing `rows`/`sources`/`problems`/`tree` lists and the `visited` key set.
expand_index_node <- function(
  parent_url,
  children,
  parent_depth,
  user_agent,
  limits,
  net_limits,
  policy,
  acc
) {
  capped <- dedup_and_cap_children(children$loc, parent_url, limits, acc)
  locs <- capped$locs
  keys <- capped$keys

  child_depth <- parent_depth + 1L

  for (i in seq_along(locs)) {
    if (index_budget_stop(acc, parent_url, limits)) {
      break
    }
    child_url <- locs[[i]]
    key <- keys[[i]]

    reason <- index_child_reject(child_url, key, child_depth, limits, acc)
    if (!is.na(reason)) {
      add_tree_row(
        acc,
        child_depth,
        parent_url,
        child_url,
        status = "rejected",
        reason = reason
      )
      next
    }

    acc$visited <- c(acc$visited, key)

    expand_index_child(
      child_url,
      child_depth,
      parent_url,
      user_agent,
      limits,
      net_limits,
      policy,
      acc
    )
  }

  invisible(NULL)
}

# Recursively expand a root sitemapindex's children into a bounded result.
#
# `root_url` is the index being expanded (already fetched and parsed by the
# caller); `root_children` is its `parse_sitemapindex()` child table. The root
# sits at `depth` (0 from `read_sitemap()`; the discovery candidate's depth from
# `sitemap_tree()`), so its children land at `depth + 1`. The root's own
# identity key seeds the visited set, so a child pointing back at the root is a
# cycle.
#
# Returns `list(rows, sources, problems, tree)`:
#   rows     tidy URL rows from every reachable leaf (urlset/text), with
#            per-child `source_sitemap` provenance.
#   sources  fetch-metadata records for every fetched child (not the root).
#   problems index-expansion / fetch / classification events (warnings).
#   tree     one `sitemap_tree` row per visited child node (depth >= depth + 1).
expand_index <- function(
  root_url,
  root_children,
  depth = 0L,
  user_agent = default_user_agent(),
  limits = index_limits(),
  net_limits = fetch_limits(),
  policy = request_policy(),
  visited = NULL
) {
  acc <- new.env(parent = emptyenv())
  acc$rows <- list()
  acc$sources <- list()
  acc$problems <- list()
  acc$tree <- list()
  acc$visited <- if (is.null(visited)) index_loc_key(root_url) else visited
  # Traversal-wide aggregate-budget accounting (spans the whole recursion).
  acc$total_sitemaps <- 0L
  acc$total_urls <- 0L
  acc$stopped <- FALSE

  expand_index_node(
    root_url,
    root_children,
    depth,
    user_agent,
    limits,
    net_limits,
    policy,
    acc
  )

  rows <- if (length(acc$rows) > 0L) {
    do.call(rbind, acc$rows)
  } else {
    empty_sitemap_rows()
  }
  sources <- if (length(acc$sources) > 0L) {
    do.call(rbind, acc$sources)
  } else {
    NULL
  }
  tree <- if (length(acc$tree) > 0L) {
    do.call(rbind, acc$tree)
  } else {
    empty_sitemap_tree()
  }

  list(
    rows = rows,
    sources = sources,
    problems = combine_problems(acc$problems),
    tree = tree
  )
}
