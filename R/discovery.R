# Sitemap discovery from a site root (Discovery slice; docs/sitemap-spec.md §9).
#
# Builds the ordered, deduplicated set of candidate sitemap URLs to try against
# a site root from the enabled discovery sources: robots.txt `Sitemap:`
# directives (R/robots.R; ADR-006) and the guessed-path catalog
# (R/discovery-catalog.R), each toggled by `use_robots` / `use_known_paths`.
# robots directives take precedence over catalog guesses on dedup. This file
# owns candidate-URL assembly, full-URL deduplication, the candidate-count cap,
# and classification of candidates into accepted/rejected rows.
#
# Reused internals (do NOT reimplement here):
#   create_source_records()  R/input.R  root -> normalized origin (as = "site")
#   parse_url_adapter()       R/url.R    canonical URL component parse
#   build_loc_key()           R/url.R    full-URL identity key for dedup
#   discovery_catalog()       R/discovery-catalog.R  ordered guess catalog

#' Default limits for discovery
#'
#' Returns the configurable limits applied while discovering candidates. The
#' candidate cap bounds how many distinct guessed-path candidates are evaluated
#' against a single site root (after deduplication), so a large catalog can
#' never trigger an unbounded burst of requests.
#'
#' @param max_candidates Maximum number of distinct candidates to evaluate.
#'   Resolves from the argument, then `getOption("sitemapr.max_candidates")`,
#'   then the default of 50.
#' @return A named list of limits with coerced types.
#' @keywords internal
#' @noRd
discovery_limits <- function(
  max_candidates = getOption("sitemapr.max_candidates", 50L)
) {
  list(max_candidates = as.integer(max_candidates))
}

#' Build the ordered, deduplicated candidate set for a site root
#'
#' Joins each guessed-path catalog entry to the normalized origin of `root`,
#' producing absolute candidate URLs in catalog order (every generic guess
#' first, then CMS guesses). Candidates are deduplicated on the full-URL
#' identity key — keeping the first (catalog-order) occurrence — so a CMS entry
#' whose URL equals a generic one (Shopify's `/sitemap.xml`) yields a single
#' candidate and a single request. The candidate cap then truncates the list.
#'
#' The root is normalized through the shared site-entrypoint policy
#' (`create_source_records(as = "site")`): a schemeless root gets `https://`,
#' the host is IDNA/lower-cased, and any path/query/fragment is dropped to the
#' bare `scheme://host[:port]` origin before the catalog paths are appended.
#'
#' @param root A single site-root URL (character). A bare host is accepted.
#' @param catalog The guess catalog, as from `discovery_catalog()`.
#' @param limits Discovery limits, as from `discovery_limits()`.
#' @return A tibble with columns `candidate_url`, `catalog_path`, `kind`,
#'   `source`, and `loc_key`, ordered by catalog precedence, deduplicated on
#'   `loc_key`, and truncated to the candidate cap. A root that cannot be
#'   parsed raises the underlying `create_source_records()` classed error.
#' @keywords internal
#' @noRd
discovery_candidates <- function(
  root,
  catalog = discovery_catalog(),
  limits = discovery_limits()
) {
  if (
    !is.character(root) || length(root) != 1L || is.na(root) || !nzchar(root)
  ) {
    rlang::abort(
      "`root` must be a single non-empty site-root URL.",
      class = "sitemapr_bad_input"
    )
  }

  root_rec <- create_source_records(root, as = "site")
  origin <- root_rec$normalized_url[[1L]]

  # Build the fetch URLs from the normalized origin + catalog paths. The origin
  # retains any explicit port; `rurl::clean_url` would drop a non-default port,
  # so the identity key (`build_loc_key`, which keeps the port) drives dedup.
  candidate_url <- paste0(origin, catalog$path)
  cand <- tibble::tibble(
    candidate_url = candidate_url,
    catalog_path = catalog$path,
    kind = catalog$kind,
    source = catalog$source,
    loc_key = build_loc_key(parse_url_adapter(candidate_url))
  )

  # Dedup on the full-URL identity, keeping the first (catalog-order) hit, THEN
  # enforce the candidate cap — mirroring create_source_records()' ordering.
  cand <- cand[!duplicated(cand$loc_key), , drop = FALSE]
  if (nrow(cand) > limits$max_candidates) {
    cand <- cand[seq_len(limits$max_candidates), , drop = FALSE]
  }

  tibble::as_tibble(cand)
}

# Classify one candidate's fetch outcome into (status, reason, http_status).
# Accepted on a 2xx; otherwise rejected with a reason that distinguishes a
# missing guess (`not-found`) from other HTTP and transport outcomes. A 404 is
# an ordinary rejected candidate, NEVER a finding (docs/sitemap-spec.md §9). The
# accepted reason records how the candidate was discovered: `robots` for a
# robots.txt `Sitemap:` directive, else the catalog basis.
classify_candidate <- function(kind, source, rec, provenance = "guessed-path") {
  ok_reason <- if (identical(provenance, "robots")) {
    "robots"
  } else if (identical(kind, "cms")) {
    paste0("catalog-", source)
  } else {
    "catalog-generic"
  }

  if (is.na(rec$error_class)) {
    return(list(
      status = "accepted",
      reason = ok_reason,
      http_status = as.integer(rec$status)
    ))
  }

  status <- as.integer(rec$status)
  reason <- if (!is.na(status) && status == 404L) {
    "not-found"
  } else if (!is.na(status)) {
    paste0("http-", status)
  } else {
    "unreachable"
  }
  list(status = "rejected", reason = reason, http_status = status)
}

# Fetch one candidate, suppressing the expected non-2xx warning (a missing
# guessed path is normal during discovery), and turn a transport/SSRF/timeout
# ABORT into a rejected outcome instead of letting it fail the whole discovery.
# Returns list(rec, status, reason, http_status, final_url); `rec` is the fetch
# record (carrying the body attribute) for an evaluated response, else NULL.
fetch_candidate <- function(
  candidate_url,
  kind,
  source,
  user_agent,
  limits,
  provenance = "guessed-path"
) {
  rec <- tryCatch(
    withCallingHandlers(
      fetch_source(candidate_url, user_agent = user_agent, limits = limits),
      sitemapr_http_error = function(w) invokeRestart("muffleWarning")
    ),
    sitemapr_ssrf_blocked = function(e) {
      structure(list(reason = "blocked"), class = "discovery_abort")
    },
    error = function(e) {
      structure(list(reason = "unreachable"), class = "discovery_abort")
    }
  )

  if (inherits(rec, "discovery_abort")) {
    return(list(
      rec = NULL,
      status = "rejected",
      reason = rec$reason,
      http_status = NA_integer_,
      final_url = NA_character_
    ))
  }

  cls <- classify_candidate(kind, source, rec, provenance = provenance)
  list(
    rec = rec,
    status = cls$status,
    reason = cls$reason,
    http_status = cls$http_status,
    final_url = as.character(rec$final_url)
  )
}

# Build the robots.txt `Sitemap:` candidate frame for a normalized origin, in
# the same column shape as `discovery_candidates()` plus a `provenance` column.
# Returns a 0-row frame when robots discovery is off or yields no directives.
robots_candidates <- function(origin, user_agent, net_limits) {
  urls <- discover_robots_sitemaps(
    origin,
    user_agent = user_agent,
    net_limits = net_limits
  )
  if (length(urls) == 0L) {
    return(NULL)
  }
  data.frame(
    candidate_url = urls,
    catalog_path = NA_character_,
    kind = "robots",
    source = NA_character_,
    provenance = "robots",
    loc_key = vapply(
      urls,
      function(u) build_loc_key(parse_url_adapter(u)),
      character(1L),
      USE.NAMES = FALSE
    ),
    stringsAsFactors = FALSE
  )
}

empty_discovery_candidates <- function(root) {
  # Validate `root` even when both sources are off, for a consistent contract.
  create_source_records(root, as = "site")
  tibble::tibble(
    candidate_url = character(0),
    catalog_path = character(0),
    kind = character(0),
    source = character(0),
    provenance = character(0),
    loc_key = character(0)
  )
}

guessed_path_candidates <- function(root, catalog, limits) {
  g <- discovery_candidates(root, catalog = catalog, limits = limits)
  data.frame(
    candidate_url = g$candidate_url,
    catalog_path = g$catalog_path,
    kind = g$kind,
    source = g$source,
    provenance = "guessed-path",
    loc_key = g$loc_key,
    stringsAsFactors = FALSE
  )
}

# Assemble the ordered, deduplicated candidate set for `root` from the enabled
# discovery sources: robots.txt `Sitemap:` directives first (authoritative),
# then the guessed-path catalog. Deduplication on the full-URL identity key
# keeps the first (robots-then-catalog order) occurrence, so a URL listed in
# both robots.txt and the catalog is a single `robots` candidate; the candidate
# cap then applies to the combined set. Returns a tibble with `provenance`.
assemble_candidates <- function(
  root,
  catalog,
  limits,
  user_agent,
  net_limits,
  use_known_paths,
  use_robots
) {
  parts <- list()

  if (isTRUE(use_robots)) {
    origin <- create_source_records(root, as = "site")$normalized_url[[1L]]
    parts[[length(parts) + 1L]] <- robots_candidates(
      origin,
      user_agent,
      net_limits
    )
  }

  if (isTRUE(use_known_paths)) {
    parts[[length(parts) + 1L]] <- guessed_path_candidates(
      root,
      catalog,
      limits
    )
  }

  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0L) {
    return(empty_discovery_candidates(root))
  }

  cand <- do.call(rbind, parts)
  cand <- cand[!duplicated(cand$loc_key), , drop = FALSE]
  if (nrow(cand) > limits$max_candidates) {
    cand <- cand[seq_len(limits$max_candidates), , drop = FALSE]
  }
  tibble::as_tibble(cand)
}

#' Evaluate discovery candidates against a site root
#'
#' Assembles the candidate set for `root` from the enabled discovery sources
#' (`assemble_candidates()`) and fetches each one, classifying it as `accepted`
#' (a 2xx response) or `rejected` (a 404 becomes reason `not-found`; other
#' non-2xx become `http-<status>`; an SSRF block becomes `blocked`; a timeout or
#' transport failure becomes `unreachable`). A missing guess is a rejected
#' candidate, never a finding, and one unreachable guess never fails discovery.
#'
#' Two sources feed the candidate set: robots.txt `Sitemap:` directives
#' (provenance `robots`) and the guessed-path catalog (provenance
#' `guessed-path`), each toggled by `use_robots` / `use_known_paths`. robots.txt
#' is fetched only
#' for its `Sitemap:` directives; robots rules (`Disallow`/`Allow`) are never
#' applied (ADR-006).
#'
#' The fetch record for each evaluated response (carrying the body attribute) is
#' returned in the `records` attribute, parallel to the result rows, so the
#' `sitemap_tree()` assembler can populate page-count/gzip for accepted
#' candidates without a second fetch.
#'
#' @param root A single site-root URL (character). A bare host is accepted.
#' @param catalog The guess catalog, as from `discovery_catalog()`.
#' @param limits Discovery limits, as from `discovery_limits()`.
#' @param user_agent The User-Agent header for HTTP fetches.
#' @param net_limits Network limits for the per-candidate fetches, as from
#'   `fetch_limits()`.
#' @param use_known_paths Fetch the guessed-path catalog (default `TRUE`).
#' @param use_robots Fetch robots.txt for its `Sitemap:` directives (default
#'   `TRUE`).
#' @return A tibble with one row per evaluated candidate and columns
#'   `candidate_url`, `catalog_path`, `kind`, `source`, `provenance`, `status`,
#'   `reason`, `http_status`, and `final_url`. The `records` attribute holds the
#'   parallel list of fetch records.
#' @keywords internal
#' @noRd
discover_candidates <- function(
  root,
  catalog = discovery_catalog(),
  limits = discovery_limits(),
  user_agent = default_user_agent(),
  net_limits = fetch_limits(),
  use_known_paths = TRUE,
  use_robots = TRUE
) {
  cand <- assemble_candidates(
    root,
    catalog = catalog,
    limits = limits,
    user_agent = user_agent,
    net_limits = net_limits,
    use_known_paths = use_known_paths,
    use_robots = use_robots
  )

  outcomes <- lapply(seq_len(nrow(cand)), function(i) {
    fetch_candidate(
      cand$candidate_url[[i]],
      cand$kind[[i]],
      cand$source[[i]],
      user_agent = user_agent,
      limits = net_limits,
      provenance = cand$provenance[[i]]
    )
  })

  result <- tibble::tibble(
    candidate_url = cand$candidate_url,
    catalog_path = cand$catalog_path,
    kind = cand$kind,
    source = cand$source,
    provenance = cand$provenance,
    status = vapply(outcomes, `[[`, character(1L), "status"),
    reason = vapply(outcomes, `[[`, character(1L), "reason"),
    http_status = vapply(outcomes, `[[`, integer(1L), "http_status"),
    final_url = vapply(outcomes, `[[`, character(1L), "final_url")
  )
  attr(result, "records") <- lapply(outcomes, `[[`, "rec")
  result
}
