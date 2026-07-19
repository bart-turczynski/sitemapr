# Offline integration tests for page inspection wired through the engine-aware
# entry points (validate_sitemap_ruleset / validate_sitemaps_ruleset; E.1f
# follow-up SITE-htoqbghl).
#
# The wiring mirrors validate_sitemap(): inspect_pages = FALSE stays
# byte-identical (baseline ten / engine fourteen columns, no coverage attr);
# inspect_pages = TRUE runs the batch-wide page pass and stamps the coverage
# attribute. What the ruleset path adds is that the page-layer findings are
# assembled under the SAME ruleset as the base, so under an engine overlay they
# carry the additive schema-v2 columns and per-engine provenance too. Page
# fetches are httr2-mocked, so the suite is CRAN-safe.

# Local mock builder + one-URL local sitemap (helpers in sibling test files are
# not visible here).
vri_mock_status <- function(status, url) {
  httr2::response(
    status_code = status,
    url = url,
    headers = list("Content-Type" = "text/html; charset=UTF-8"),
    body = charToRaw("<html></html>")
  )
}

vri_local_sitemap <- function(loc = "https://example.com/a") {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<url><loc>",
    loc,
    "</loc></url></urlset>"
  )
  path <- tempfile(fileext = ".xml")
  writeLines(xml, path)
  path
}

# ---- byte-identity: inspect_pages = FALSE ------------------------------------

test_that("baseline inspect_pages = FALSE is byte-identical, no coverage", {
  path <- vri_local_sitemap()
  off <- validate_sitemap_ruleset(path, "sitemaps.org")
  explicit_off <- validate_sitemap_ruleset(
    path,
    "sitemaps.org",
    inspect_pages = FALSE
  )
  expect_identical(off, explicit_off)
  expect_null(attr(off, "page_coverage"))
  expect_identical(ncol(off), 10L)
  expect_false("page" %in% off$layer)
})

test_that("engine overlay inspect_pages = FALSE is byte-identical", {
  path <- vri_local_sitemap()
  off <- validate_sitemap_ruleset(path, "google")
  explicit_off <- validate_sitemap_ruleset(
    path,
    "google",
    inspect_pages = FALSE
  )
  expect_identical(off, explicit_off)
  expect_null(attr(off, "page_coverage"))
  # Engine overlay keeps its fourteen columns without page inspection.
  expect_identical(ncol(off), 14L)
})

# ---- inspect_pages = TRUE, baseline ------------------------------------------

test_that("baseline inspect_pages = TRUE emits page rows + coverage attr", {
  path <- vri_local_sitemap("https://example.com/a")
  httr2::local_mocked_responses(
    list(vri_mock_status(404L, "https://example.com/a"))
  )

  out <- validate_sitemap_ruleset(path, "sitemaps.org", inspect_pages = TRUE)
  cov <- attr(out, "page_coverage")
  expect_false(is.null(cov))
  expect_identical(cov$scope, "batch")
  expect_identical(cov$eligible, 1L)

  page_rows <- out[out$layer == "page", ]
  expect_identical(nrow(page_rows), 1L)
  expect_identical(page_rows$code, "PAGE_STATUS_ERROR")
  # Baseline keeps the pinned ten columns (coverage rides an attribute).
  expect_identical(ncol(out), 10L)
})

# ---- inspect_pages = TRUE under an engine overlay (the point of E.1f) --------

test_that("engine overlay stamps page findings with the additive columns", {
  path <- vri_local_sitemap("https://example.com/a")
  httr2::local_mocked_responses(
    list(vri_mock_status(404L, "https://example.com/a"))
  )

  out <- validate_sitemap_ruleset(path, "google", inspect_pages = TRUE)
  # The page finding is carried under the engine ruleset, not dropped to a
  # generic baseline diagnostic: fourteen columns overall.
  expect_true(all(
    c("ruleset", "ruleset_revision", "context", "provenance") %in% names(out)
  ))
  expect_identical(ncol(out), 14L)

  page_rows <- out[out$layer == "page", ]
  expect_identical(nrow(page_rows), 1L)
  expect_identical(page_rows$code, "PAGE_STATUS_ERROR")
  # The page row rides the same engine ruleset + per-engine provenance as the
  # base findings (no per-code override exists yet: ADR-009 §0 default class).
  expect_identical(page_rows$ruleset, "google")
  expect_identical(page_rows$provenance, "inherited_protocol")
  # The page context axis is threaded through onto the page row too.
  ctx <- page_rows$context[[1L]]
  expect_identical(ctx$page_outcome, "http_status")
  expect_identical(ctx$page_status, 404L)

  # Coverage still stamped on the engine path (a 404 is attempted but not a
  # completed body fetch).
  cov <- attr(out, "page_coverage")
  expect_identical(cov$eligible, 1L)
  expect_identical(cov$attempted, 1L)
})

# ---- plural delegates identically --------------------------------------------

test_that("validate_sitemaps_ruleset threads the page params through", {
  path <- vri_local_sitemap("https://example.com/a")
  httr2::local_mocked_responses(
    list(vri_mock_status(404L, "https://example.com/a"))
  )

  singular <- validate_sitemap_ruleset(path, "google", inspect_pages = TRUE)

  httr2::local_mocked_responses(
    list(vri_mock_status(404L, "https://example.com/a"))
  )
  plural <- validate_sitemaps_ruleset(path, "google", inspect_pages = TRUE)

  # The findings themselves are row-for-row identical; the coverage attribute
  # carries a wall-clock `elapsed`, so it is compared field-wise minus timing.
  attr(singular, "page_coverage") <- NULL
  cov_plural <- attr(plural, "page_coverage")
  attr(plural, "page_coverage") <- NULL
  expect_identical(singular, plural)
  expect_identical(cov_plural$eligible, 1L)
  expect_identical(cov_plural$attempted, 1L)
})
