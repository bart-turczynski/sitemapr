# Unit tests for report_sitemap() (R/report.R). Fully offline: every case
# renders from a bundled corpus/local fixture file, so no network is touched.
#
# The report is a self-contained HTML surface over read_sitemap() +
# validate_sitemap() output. The assertions are deliberately structural
# (grepl on section markers, class/id names, and CSS/JS hooks) rather than
# brittle full-HTML snapshots.

# A fixture with several path-bearing URLs (drives the tree + URL table); a
# fixture that produces findings; and a valid index.
core_fixture <- function() test_path("fixtures", "corpus", "xml", "valid-core.xml")
findings_fixture <- function() test_path("fixtures", "priority-out-of-range.xml")

render_string <- function(...) {
  as.character(report_sitemap(...))
}

# ---- return / write contract -------------------------------------------------

test_that("report_sitemap() returns a self-contained HTML string with every section", {
  html <- render_string(core_fixture())
  expect_true(is.character(html) && length(html) == 1L)

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
})

test_that("report_sitemap(output=) writes the file and returns the path invisibly", {
  out <- withr::local_tempfile(fileext = ".html")
  res <- report_sitemap(core_fixture(), output = out)
  expect_identical(res, out)
  expect_true(file.exists(out))
  expect_gt(file.info(out)$size, 3000L) # non-trivial

  html <- paste(readLines(out, warn = FALSE), collapse = "\n")
  expect_match(html, "smr-hero", fixed = TRUE)
  expect_match(html, "URL analysis", fixed = TRUE)
})

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

test_that("the report ships a dark variant with a prefers-color-scheme default and a toggle", {
  html <- render_string(core_fixture())
  # Default follows the OS via the media query...
  expect_match(html, "prefers-color-scheme: dark", fixed = TRUE)
  # ...and both toggle directions win via explicit data-theme rules.
  expect_match(html, "root[data-theme=\"dark\"]", fixed = TRUE)
  expect_match(html, "data-theme=\"light\"", fixed = TRUE)
  # A toggle button and the JS that stamps data-theme on the root.
  expect_match(html, "smr-theme-toggle", fixed = TRUE)
  expect_match(html, "setAttribute('data-theme'", fixed = TRUE)
})

# ---- interactive URL-table hooks ---------------------------------------------

test_that("the URL table wires search, sort, and CSV export", {
  html <- render_string(core_fixture())
  expect_match(html, "smr-url-search", fixed = TRUE) # search box
  expect_match(html, "smr-sortable", fixed = TRUE) # sortable headers
  expect_match(html, "smr-csv-btn", fixed = TRUE) # CSV button
  expect_match(html, "text/csv", fixed = TRUE) # CSV export blob
})

# ---- findings rendering ------------------------------------------------------

test_that("a fixture with findings renders a severity dashboard and layer-grouped findings", {
  findings <- validate_sitemap(findings_fixture())
  expect_gt(nrow(findings), 0L) # precondition: this fixture has findings

  html <- render_string(findings_fixture())
  expect_match(html, "smr-sevgrid", fixed = TRUE) # severity dashboard grid
  expect_match(html, "smr-layer", fixed = TRUE) # a layer block
  # The actual finding code(s) appear in the findings table.
  expect_match(html, findings$code[[1]], fixed = TRUE)
  # The layer heading names the layer.
  expect_match(html, findings$layer[[1]], fixed = TRUE)
})

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
