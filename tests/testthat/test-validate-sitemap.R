# Unit tests for validate_sitemap() (Layer F entry point; SITE-ynxpeikq).
#
# Offline only: local fixtures for every branch, plus an in-memory text fixture
# for the over-long-line case. No real network is touched.

# The 10-column findings contract, in order.
contract_cols <- c(
  "code",
  "severity",
  "layer",
  "subject_type",
  "subject_ref",
  "message",
  "evidence",
  "mode",
  "is_strict_only",
  "remediation_hint"
)

fixture <- function(name) test_path("fixtures", name)

test_that("a valid urlset yields zero findings", {
  out <- validate_sitemap(fixture("valid-minimal.xml"))
  expect_s3_class(out, "tbl_df")
  expect_identical(names(out), contract_cols)
  expect_identical(nrow(out), 0L)
})

test_that("every branch returns the full 10-column contract", {
  out <- validate_sitemap(fixture("urlset-duplicate-loc.xml"))
  expect_identical(names(out), contract_cols)
})

test_that("a duplicate loc yields a PROTOCOL_DUPLICATE_LOC finding", {
  out <- validate_sitemap(fixture("urlset-duplicate-loc.xml"))
  expect_true("PROTOCOL_DUPLICATE_LOC" %in% out$code)
  row <- out[out$code == "PROTOCOL_DUPLICATE_LOC", ]
  expect_identical(row$layer, "protocol")
  expect_identical(row$severity, "warning")
})

test_that("a schema-invalid urlset is an error in strict mode", {
  out <- validate_sitemap(fixture("schema-invalid-urlset.xml"), mode = "strict")
  schema <- out[out$code == "SCHEMA_INVALID", ]
  expect_gt(nrow(schema), 0L)
  expect_true(all(schema$severity == "error"))
})

test_that("a schema-invalid urlset is downgraded to warning in non-strict", {
  out <- validate_sitemap(
    fixture("schema-invalid-urlset.xml"),
    mode = "non-strict"
  )
  schema <- out[out$code == "SCHEMA_INVALID", ]
  expect_gt(nrow(schema), 0L)
  expect_true(all(schema$severity == "warning"))
})

test_that("an unsupported root yields UNSUPPORTED_ROOT", {
  out <- validate_sitemap(fixture("unsupported-root.xml"))
  expect_true("UNSUPPORTED_ROOT" %in% out$code)
  row <- out[out$code == "UNSUPPORTED_ROOT", ]
  expect_identical(row$layer, "classification")
})

test_that("a long text-sitemap line yields PROTOCOL_TEXT_URL_TOO_LONG", {
  long_url <- paste0(
    "https://example.com/",
    paste(rep("a", 2100L), collapse = "")
  )
  path <- withr::local_tempfile(fileext = ".txt")
  writeLines(c("https://example.com/", long_url), path)

  out <- validate_sitemap(path)
  expect_true("PROTOCOL_TEXT_URL_TOO_LONG" %in% out$code)
})

test_that("a sitemapindex feed child yields UNSUPPORTED_FEED (offline)", {
  root <- "https://example.com/sitemap.xml"
  child <- "https://example.com/feed.xml"
  index_body <- paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n",
    "  <sitemap><loc>",
    child,
    "</loc></sitemap>\n",
    "</sitemapindex>\n"
  )
  rss_body <- paste0(
    "<?xml version=\"1.0\"?>\n",
    "<rss version=\"2.0\"><channel><title>Feed</title></channel></rss>\n"
  )
  map <- list()
  map[[root]] <- index_body
  map[[child]] <- rss_body

  httr2::local_mocked_responses(function(req) {
    body <- map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404, url = req$url))
    }
    httr2::response(
      status_code = 200,
      url = req$url,
      headers = list("Content-Type" = "application/xml; charset=UTF-8"),
      body = charToRaw(body)
    )
  })

  out <- validate_sitemap(root)
  expect_identical(names(out), contract_cols)
  expect_true("UNSUPPORTED_FEED" %in% out$code)
  row <- out[out$code == "UNSUPPORTED_FEED", ]
  expect_identical(nrow(row), 1L)
  expect_identical(row$layer, "classification")
  expect_identical(row$subject_type, "index-child")
})

test_that("validation is deterministic for a fixture and mode", {
  a <- validate_sitemap(fixture("urlset-duplicate-loc.xml"), mode = "strict")
  b <- validate_sitemap(fixture("urlset-duplicate-loc.xml"), mode = "strict")
  expect_identical(a, b)
})
