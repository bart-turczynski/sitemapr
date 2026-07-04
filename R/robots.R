# robots.txt Sitemap: directive discovery (SITE-stxkwfbq; revisits ADR-002).
#
# The `Sitemap:` directive is GROUP-INDEPENDENT: unlike `Disallow`/`Allow`, it
# is not scoped to any `User-agent` group and applies to the whole file. Sitemap
# discovery therefore needs only a focused directive extractor, NOT a full
# robots.txt grammar with User-agent group parsing. (ADR-002's objection to a
# "thin" parser concerned User-agent scoping for `Disallow`/`Allow` rules, which
# does not apply to the `Sitemap:` directive; see ADR-006.)
#
# This engine never applies robots rules (`Disallow`/`Allow`) — that remains out
# of scope. It only harvests `Sitemap:` URLs to feed the discovery pipeline.
#
# Reused internals (do NOT reimplement here):
#   fetch_source()       R/fetch.R   bounded, SSRF-safe fetch
#   parse_url_adapter()  R/url.R     canonical URL component parse
#   build_loc_key()      R/url.R     full-URL identity key for dedup

# Build the robots.txt URL for a normalized origin (`scheme://host[:port]`).
robots_txt_url <- function(origin) {
  paste0(origin, "/robots.txt")
}

# Is `url` an absolute http(s) URL with a parseable host? A `Sitemap:` directive
# must be an absolute URL (sitemaps.org / robots.txt spec); a relative or
# non-http value is not a usable sitemap location.
robots_is_http_url <- function(url) {
  if (!grepl("^https?://", url, ignore.case = TRUE)) {
    return(FALSE)
  }
  parsed <- tryCatch(parse_url_adapter(url), error = function(e) NULL)
  !is.null(parsed) &&
    identical(parsed$parse_status[[1L]], "ok") &&
    !is.na(parsed$host[[1L]]) &&
    nzchar(parsed$host[[1L]])
}

# Extract sitemap URLs from robots.txt text. The `Sitemap:` directive is matched
# per line, case-insensitively and tolerant of the `site-map` misspelling. Order
# is preserved; duplicates are removed on the full-URL identity key. A directive
# whose value is not an absolute http(s) URL is skipped with a warning (never an
# error), so a single malformed line cannot fail discovery.
parse_robots_sitemaps <- function(text) {
  lines <- strsplit(text, "\r\n|\r|\n", perl = TRUE)[[1L]]
  pat <- "(?i)^\\s*site-?map\\s*:\\s*(\\S.*?)\\s*$"
  hits <- grepl(pat, lines, perl = TRUE)
  if (!any(hits)) {
    return(character(0))
  }
  vals <- sub(pat, "\\1", lines[hits], perl = TRUE)

  valid <- vapply(vals, robots_is_http_url, logical(1L), USE.NAMES = FALSE)
  if (any(!valid)) {
    rlang::warn(
      sprintf(
        "Skipped %d non-absolute-http Sitemap: directive(s) in robots.txt: %s",
        sum(!valid),
        paste(vals[!valid], collapse = ", ")
      ),
      class = "sitemapr_robots_bad_directive"
    )
  }

  good <- vals[valid]
  if (length(good) == 0L) {
    return(character(0))
  }
  keys <- vapply(
    good,
    function(u) build_loc_key(parse_url_adapter(u)),
    character(1L),
    USE.NAMES = FALSE
  )
  good[!duplicated(keys)]
}

# Fetch and harvest `Sitemap:` URLs from an origin's robots.txt. Fetch failures
# are swallowed gracefully (an SSRF block, transport failure, or non-2xx status
# yields no URLs, never an error), mirroring discovery's candidate handling — a
# missing or unreachable robots.txt simply contributes nothing. Returns an
# ordered, deduplicated character vector of sitemap URLs (possibly empty).
discover_robots_sitemaps <- function(
  origin,
  user_agent = default_user_agent(),
  net_limits = fetch_limits()
) {
  url <- robots_txt_url(origin)
  rec <- tryCatch(
    withCallingHandlers(
      fetch_source(url, user_agent = user_agent, limits = net_limits),
      sitemapr_http_error = function(w) invokeRestart("muffleWarning")
    ),
    sitemapr_ssrf_blocked = function(e) NULL,
    error = function(e) NULL
  )
  if (is.null(rec) || !is.na(rec$error_class)) {
    return(character(0))
  }
  body <- attr(rec, "body")
  if (is.null(body) || length(body) == 0L) {
    return(character(0))
  }
  text <- rawToChar(body)
  Encoding(text) <- "UTF-8"
  parse_robots_sitemaps(text)
}
