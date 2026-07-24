#' @keywords internal
#' @seealso
#' Reading: [read_sitemap()].
#' Discovery: [sitemap_tree()], [sitemap_tree_from_bytes()], [probe_url()].
#' Validation: [validate_sitemap()], [validate_sitemap_ruleset()].
#' Rulesets and per-source context: [sitemap_rulesets()],
#' [ruleset_revision()], [ruleset_context()], [ruleset_context_for_child()],
#' [gsc_submission()], [robots_cross_submission()].
#' Auditing: [audit_sitemap()], [sitemap_audit()], [compare_sitemap_audits()],
#' [audit_unchanged()], [audit_accessors()], [sitemap_companions()].
#' Limits: [discovery_limits()], [index_limits()], [fetch_limits()].
#' Reporting: [report_sitemap()].
#' Request customization: [request_policy()], [request_auth_basic()],
#' [request_auth_bearer()], [request_proxy()], [request_retry()],
#' [request_throttle()].
#'
#' The `introduction` vignette is a full tour:
#' `vignette("introduction", package = "sitemapr")`.
#'
#' URL parsing and canonicalization are delegated to the \pkg{rurl} package,
#' robots.txt evaluation to \pkg{robotstxtr}, and HTTP is performed by
#' \pkg{httr2}.
#'
#' @examples
#' # A short offline tour; no call below performs a network request.
#'
#' # A small sitemap with two deliberate problems: a priority outside [0, 1]
#' # and a date-only lastmod.
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   '<url><loc>https://example.com/</loc>',
#'   '<lastmod>2024-01-01</lastmod><priority>0.8</priority></url>',
#'   '<url><loc>https://example.com/about</loc>',
#'   '<priority>7</priority></url>',
#'   '</urlset>'
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#'
#' # 1. Read the source into one tidy row per URL. Extension elements arrive
#' # in the images/video/news/alternates list-columns.
#' read_sitemap(path)
#'
#' # 2. Validate it: one row per issue, each with a stable code, a severity,
#' # and the layer that produced it. The same source always yields a
#' # row-for-row identical result.
#' validate_sitemap(path)[, c("code", "severity", "layer")]
#'
#' # 3. Audit in a single pass, then reach into the components.
#' audit <- audit_sitemap(path)
#' audit_findings(audit)$code
#' nrow(audit_urls(audit))
#'
#' # 4. Engine-aware validation. Each supported ruleset interprets the same
#' # source under its own published rules, and the findings carry the
#' # ruleset and its revision.
#' sitemap_rulesets()
#' ruleset_revision("google")
#' google <- validate_sitemap_ruleset(path, sitemap_ruleset = "google")
#' google[, c("code", "severity", "ruleset")]
#'
#' # 5. The default bounds every fetch and index expansion runs under.
#' fetch_limits()
#' index_limits()
"_PACKAGE"

## usethis namespace: start
## usethis namespace: end
NULL
