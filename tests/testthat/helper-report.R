# Shared fixture builders for the report suites (test-report.R,
# test-report-checks.R, test-report-recommendations.R). They construct the two
# objects report_sitemap() consumes — a read_sitemap()-shaped `urls` tibble and
# its `sources` companion — without touching the network or a parser, so a test
# can pin one column at a time.

# A fixture with several path-bearing URLs (drives the tree + URL table), and a
# fixture that produces findings.
core_fixture <- function() {
  test_path("fixtures", "corpus", "xml", "valid-core.xml")
}

findings_fixture <- function() {
  test_path("fixtures", "priority-out-of-range.xml")
}

render_string <- function(...) {
  as.character(report_sitemap(...))
}

report_urls_fixture <- function(loc, source_sitemap = loc, lastmod = NA) {
  lastmod <- if (length(lastmod) == 0L) {
    as.POSIXct(character(), tz = "UTC")
  } else {
    as.POSIXct(lastmod, tz = "UTC")
  }
  tibble::tibble(
    loc = loc,
    lastmod = lastmod,
    changefreq = NA_character_,
    priority = NA_real_,
    images = rep(list(NULL), length(loc)),
    video = rep(list(NULL), length(loc)),
    news = rep(list(NULL), length(loc)),
    alternates = rep(list(NULL), length(loc)),
    source_sitemap = source_sitemap
  )
}

report_sources_fixture <- function(requested_url, final_url, format) {
  tibble::tibble(
    requested_url = requested_url,
    final_url = final_url,
    status = rep(200L, length(requested_url)),
    redirect_chain = rep("", length(requested_url)),
    content_type = rep("application/xml", length(requested_url)),
    charset = rep(NA_character_, length(requested_url)),
    bytes = seq_along(requested_url) * 1024,
    timing = seq_along(requested_url) / 10,
    error_class = rep(NA_character_, length(requested_url)),
    format = format,
    root = rep(NA_character_, length(requested_url)),
    namespaces = rep("", length(requested_url)),
    profile_id = rep(NA_character_, length(requested_url))
  )
}

# A findings-contract tibble (schema v1, the pinned ten columns) built from
# per-row code/severity/layer triples. Everything else is filler: the checks
# section reads only `code` and `layer`.
report_findings_fixture <- function(code, severity, layer) {
  n <- length(code)
  tibble::tibble(
    code = code,
    severity = severity,
    layer = layer,
    subject_type = rep("document", n),
    subject_ref = rep("sitemap://fixture", n),
    message = paste0(code, " fired."),
    evidence = rep(list(sitemapr_test_ns$finding_evidence()), n),
    mode = rep("strict", n),
    is_strict_only = rep(FALSE, n),
    remediation_hint = rep(NA_character_, n)
  )
}
