# Unit tests for the text sitemap parser (R/parse-text.R). Pure/offline: every
# fixture is an inline string or raw vector, no network and no temp files.

test_that("a text sitemap parses to the contract row tibble", {
  txt <- "https://a/\nhttps://b/\nhttps://c/"
  rows <- parse_sitemap_text(txt)
  expect_s3_class(rows, "tbl_df")
  expect_identical(
    names(rows),
    c("loc", "lastmod", "changefreq", "priority", "images", "video",
      "news", "alternates", "source_sitemap")
  )
  expect_identical(rows$loc, c("https://a/", "https://b/", "https://c/"))
})

test_that("every non-loc column is NA / per-row NULL", {
  rows <- parse_sitemap_text("https://a/\nhttps://b/")
  expect_true(all(is.na(rows$lastmod)))
  expect_s3_class(rows$lastmod, "POSIXct")
  expect_true(all(is.na(rows$changefreq)))
  expect_true(all(is.na(rows$priority)))
  expect_null(rows$images[[1L]])
  expect_null(rows$video[[2L]])
  expect_null(rows$news[[1L]])
  expect_null(rows$alternates[[2L]])
})

test_that("blank and whitespace-only lines are skipped", {
  txt <- "\nhttps://a/\n   \n\t\nhttps://b/\n\n"
  rows <- parse_sitemap_text(txt)
  expect_identical(rows$loc, c("https://a/", "https://b/"))
})

test_that("surrounding whitespace on a URL line is trimmed", {
  txt <- "  https://a/  \n\thttps://b/\t"
  rows <- parse_sitemap_text(txt)
  expect_identical(rows$loc, c("https://a/", "https://b/"))
})

test_that("CRLF and lone-CR line endings are accepted", {
  expect_identical(
    parse_sitemap_text("https://a/\r\nhttps://b/")$loc,
    c("https://a/", "https://b/")
  )
  expect_identical(
    parse_sitemap_text("https://a/\rhttps://b/")$loc,
    c("https://a/", "https://b/")
  )
})

test_that("an empty or all-blank document yields the zero-row schema", {
  expect_identical(nrow(parse_sitemap_text("")), 0L)
  expect_identical(nrow(parse_sitemap_text("\n  \n\t\n")), 0L)
  expect_s3_class(parse_sitemap_text("")$lastmod, "POSIXct")
})

test_that("raw UTF-8 bytes are decoded and parsed", {
  bytes <- charToRaw("https://a/\nhttps://b/")
  expect_identical(
    parse_sitemap_text(bytes)$loc,
    c("https://a/", "https://b/")
  )
})

test_that("source_sitemap provenance is written to every row", {
  rows <- parse_sitemap_text(
    "https://a/\nhttps://b/",
    source_sitemap = "submitted-directly"
  )
  expect_identical(rows$source_sitemap, rep("submitted-directly", 2L))
})
