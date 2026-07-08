# Unit tests for report_sitemap() (R/report.R). Fully offline: every case
# renders from a bundled corpus/local fixture file, so no network is touched.
#
# The report is a self-contained HTML surface over read_sitemap() +
# validate_sitemap() output. The assertions are deliberately structural
# (grepl on section markers, class/id names, and CSS/JS hooks) rather than
# brittle full-HTML snapshots.

# A fixture with several path-bearing URLs (drives the tree + URL table); a
# fixture that produces findings; and a valid index.
core_fixture <- function() {
  test_path("fixtures", "corpus", "xml", "valid-core.xml")
}
findings_fixture <- function() {
  test_path("fixtures", "priority-out-of-range.xml")
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

render_string <- function(...) {
  as.character(report_sitemap(...))
}

# ---- return / write contract -------------------------------------------------

test_that(
  paste0(
    "report_sitemap() returns a self-contained HTML string with every ",
    "section"
  ),
  {
    html <- render_string(core_fixture())
    expect_type(html, "character")
    expect_length(html, 1L)

    # Full self-contained document scaffold.
    expect_match(html, "<!DOCTYPE html>", fixed = TRUE)
    expect_match(html, "<head>", fixed = TRUE)
    expect_match(html, "<style>", fixed = TRUE)
    expect_match(html, "<script>", fixed = TRUE)

    # Each reference section is present.
    expect_match(html, "smr-hero", fixed = TRUE) # 1. hero
    expect_match(html, ">Sitemaps<", fixed = TRUE) # 2. sitemap table
    expect_match(html, ">lastmod<", fixed = TRUE) # 3. lastmod cards + histogram
    expect_match(html, "smr-bar-fill", fixed = TRUE) #    histogram bars
    expect_match(html, "URL structure", fixed = TRUE) # 4. folder tree
    expect_match(html, ">Severity<", fixed = TRUE) # 5. severity dashboard
    expect_match(html, "Findings", fixed = TRUE) # 6. findings by layer
    expect_match(html, "URL analysis", fixed = TRUE) # 7. URL table
  }
)

test_that(
  paste0(
    "report_sitemap(output=) writes the file and returns the path ",
    "invisibly"
  ),
  {
    out <- withr::local_tempfile(fileext = ".html")
    res <- report_sitemap(core_fixture(), output = out)
    expect_identical(res, out)
    expect_true(file.exists(out))
    expect_gt(file.info(out)$size, 3000L) # non-trivial

    html <- paste(readLines(out, warn = FALSE), collapse = "\n")
    expect_match(html, "smr-hero", fixed = TRUE)
    expect_match(html, "URL analysis", fixed = TRUE)
  }
)

# ---- self-containment (no external hosts / CDN) ------------------------------

test_that("the rendered HTML references no external resources", {
  html <- render_string(core_fixture())

  # No external stylesheets, scripts, images, fonts, or CSS imports.
  expect_no_match(html, "<script[^>]+src=")
  expect_no_match(html, "<link[^>]+href=\"https?://")
  expect_no_match(html, "<img[^>]+src=\"https?://")
  expect_no_match(html, "@import")
  expect_no_match(html, "url\\(\\s*['\"]?https?://") # no url(http...) in CSS

  # Styles and scripts are inlined, not linked out.
  expect_match(html, "<style>", fixed = TRUE)
  expect_match(html, "<script>", fixed = TRUE)
  expect_no_match(html, "rel=\"stylesheet\"", fixed = TRUE)
})

test_that("content anchor links to the sitemap's own URLs are still present", {
  # Self-containment forbids external *assets*, not content links: the URL table
  # legitimately links to the URLs the sitemap lists.
  html <- render_string(core_fixture())
  expect_match(html, "<a href=\"https://example.com/about\"", fixed = TRUE)
})

# ---- dark-mode support -------------------------------------------------------

test_that(
  paste0(
    "the report ships a dark variant with a prefers-color-scheme ",
    "default and a toggle"
  ),
  {
    html <- render_string(core_fixture())
    # Default follows the OS via the media query...
    expect_match(html, "prefers-color-scheme: dark", fixed = TRUE)
    # ...and both toggle directions win via explicit data-theme rules.
    expect_match(html, "root[data-theme=\"dark\"]", fixed = TRUE)
    expect_match(html, "data-theme=\"light\"", fixed = TRUE)
    # A toggle button and the JS that stamps data-theme on the root.
    expect_match(html, "smr-theme-toggle", fixed = TRUE)
    expect_match(html, "setAttribute('data-theme'", fixed = TRUE)
  }
)

# ---- interactive URL-table hooks ---------------------------------------------

test_that("the URL table wires search, sort, and CSV export", {
  html <- render_string(core_fixture())
  expect_match(html, "smr-url-search", fixed = TRUE) # search box
  expect_match(html, "smr-sortable", fixed = TRUE) # sortable headers
  expect_match(html, "smr-csv-btn", fixed = TRUE) # CSV button
  expect_match(html, "text/csv", fixed = TRUE) # CSV export blob
})

# ---- findings rendering ------------------------------------------------------

test_that(
  paste0(
    "a fixture with findings renders a severity dashboard and ",
    "layer-grouped findings"
  ),
  {
    findings <- validate_sitemap(findings_fixture())
    expect_gt(nrow(findings), 0L) # precondition: this fixture has findings

    html <- render_string(findings_fixture())
    expect_match(html, "smr-sevgrid", fixed = TRUE) # severity dashboard grid
    expect_match(html, "smr-layer", fixed = TRUE) # a layer block
    # The actual finding code(s) appear in the findings table.
    expect_match(html, findings$code[[1]], fixed = TRUE)
    # The layer heading names the layer.
    expect_match(html, findings$layer[[1]], fixed = TRUE)
  }
)

test_that("a clean sitemap reports no findings", {
  html <- render_string(core_fixture())
  expect_match(html, "No issues found", fixed = TRUE)
})

# ---- precomputed inputs ------------------------------------------------------

test_that("precomputed urls/findings are consumed without recomputation", {
  urls <- read_sitemap(core_fixture())
  findings <- validate_sitemap(core_fixture())
  # x is only a label here; a bogus path must NOT be read because urls+findings
  # are supplied.
  html <- render_string(
    "my-sitemap-label",
    urls = urls,
    findings = findings
  )
  expect_match(html, "my-sitemap-label", fixed = TRUE) # used as source label
  expect_match(html, "smr-hero", fixed = TRUE)
  expect_match(html, "URL analysis", fixed = TRUE)
})

test_that("precomputed source metadata drives sitemap summary rows", {
  sources <- report_sources_fixture(
    requested_url = c(
      "https://ex.com/index.xml",
      "https://origin.example/redirected.xml",
      "https://ex.com/sitemap.txt",
      "https://ex.com/sitemap.xml.gz",
      "https://ex.com/custom"
    ),
    final_url = c(
      NA_character_,
      "https://ex.com/sitemap.xml",
      "https://ex.com/sitemap.txt",
      "https://ex.com/sitemap.xml.gz",
      "https://ex.com/custom"
    ),
    format = c("xml-sitemapindex", "xml", "text", "gzip", "custom-format")
  )
  urls <- report_urls_fixture(
    loc = c(
      "https://ex.com/docs/a",
      "https://ex.com/feed/item",
      "https://ex.com/archive/item",
      "https://ex.com/custom/item"
    ),
    source_sitemap = sources$final_url[-1L],
    lastmod = c("2024-01-01", NA, NA, NA)
  )
  attr(urls, "sources") <- sources

  html <- render_string(
    "precomputed",
    urls = urls,
    findings = validate_sitemap(core_fixture())
  )

  expect_match(html, "1 index, 2 sitemaps", fixed = TRUE)
  expect_match(html, "https://ex.com/index.xml", fixed = TRUE)
  expect_match(html, "Index", fixed = TRUE)
  expect_match(html, "Text", fixed = TRUE)
  expect_match(html, "gzip", fixed = TRUE)
  expect_match(html, "custom-format", fixed = TRUE)
  expect_match(html, "colspan=\"3\"", fixed = TRUE)
  expect_match(html, ">200<", fixed = TRUE)
  expect_match(html, ">100<", fixed = TRUE)
})

test_that("precomputed urls without sources still render fallback summaries", {
  urls <- report_urls_fixture(
    loc = c("https://ex.com/a", "https://ex.com/b"),
    source_sitemap = c("https://ex.com/one.xml", "https://ex.com/two.xml"),
    lastmod = c("2024-01-01", NA)
  )

  html <- render_string(
    "source-less",
    urls = urls,
    findings = validate_sitemap(core_fixture())
  )

  expect_match(html, "2 sitemaps", fixed = TRUE)
  expect_match(html, "smr-card-num smr-warn", fixed = TRUE)
  expect_match(html, ">50%<", fixed = TRUE)
  expect_no_match(html, ">Sitemaps<", fixed = TRUE)
})

test_that("report sections skip empty trees and URL tables cleanly", {
  empty_urls <- report_urls_fixture(character(0), character(0), numeric(0))
  html_empty <- render_string(
    "empty",
    urls = empty_urls,
    findings = validate_sitemap(core_fixture())
  )
  expect_no_match(html_empty, "URL structure", fixed = TRUE)
  expect_no_match(html_empty, "URL analysis", fixed = TRUE)

  root_only <- report_urls_fixture("https://ex.com", "https://ex.com/root.xml")
  html_root <- render_string(
    "root-only",
    urls = root_only,
    findings = validate_sitemap(core_fixture())
  )
  expect_no_match(html_root, "URL structure", fixed = TRUE)
  expect_match(html_root, "URL analysis", fixed = TRUE)
})

test_that("large reports cap tree and URL table rendering", {
  n <- 10001L
  urls <- report_urls_fixture(
    loc = sprintf("https://ex.com/docs/pages/%05d.html", seq_len(n)),
    source_sitemap = "https://ex.com/sitemap.xml"
  )

  html <- render_string(
    "large",
    urls = urls,
    findings = validate_sitemap(core_fixture())
  )

  expect_match(
    html,
    "Tree built from the first 10,000 of 10,001 URLs.",
    fixed = TRUE
  )
  expect_match(
    html,
    "Showing the first 1,000 of 10,001 URLs.",
    fixed = TRUE
  )
  expect_match(html, "smr-tree-node", fixed = TRUE)
})

test_that("custom titles and evidence locations are rendered", {
  findings <- validate_sitemap(findings_fixture())
  findings$evidence[[1L]] <- list(
    excerpt = "bad priority",
    line = 3L,
    column = 9L
  )

  html <- render_string(
    "with-finding",
    urls = read_sitemap(findings_fixture()),
    findings = findings,
    title = "Custom sitemap report"
  )

  expect_match(html, "<title>Custom sitemap report</title>", fixed = TRUE)
  expect_match(html, "bad priority", fixed = TRUE)
  expect_match(html, "line 3, col 9", fixed = TRUE)
})

test_that("the source label appears in the hero and the document title", {
  html <- render_string(core_fixture())
  expect_match(html, "<title>Sitemap report", fixed = TRUE)
  expect_match(html, "smr-hero-source", fixed = TRUE)
})

# ---- input validation --------------------------------------------------------

test_that("a non-scalar or empty input raises sitemapr_bad_input", {
  expect_error(report_sitemap(c("a", "b")), class = "sitemapr_bad_input")
  expect_error(report_sitemap(character(0)), class = "sitemapr_bad_input")
  expect_error(report_sitemap(NA_character_), class = "sitemapr_bad_input")
  expect_error(report_sitemap(""), class = "sitemapr_bad_input")
})
