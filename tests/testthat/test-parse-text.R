# Unit tests for the text sitemap parser (R/parse-text.R). Pure/offline: every
# fixture is an inline string or raw vector, no network and no temp files.

test_that("a text sitemap parses to the contract row tibble", {
  txt <- "https://a/\nhttps://b/\nhttps://c/"
  rows <- parse_sitemap_text(txt)
  expect_s3_class(rows, "tbl_df")
  expect_named(
    rows,
    c(
      "loc",
      "lastmod",
      "changefreq",
      "priority",
      "images",
      "video",
      "news",
      "alternates",
      "source_sitemap"
    )
  )
  expect_identical(rows$loc, c("https://a/", "https://b/", "https://c/"))
})

test_that("every non-loc column is NA / per-row NULL", {
  rows <- parse_sitemap_text("https://a/\nhttps://b/")
  expect_true(all(is.na(rows$lastmod)))
  expect_type(rows$lastmod, "character")
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
  expect_type(parse_sitemap_text("")$lastmod, "character")
})

test_that("raw UTF-8 bytes are decoded and parsed", {
  bytes <- charToRaw("https://a/\nhttps://b/")
  expect_identical(
    parse_sitemap_text(bytes)$loc,
    c("https://a/", "https://b/")
  )
})

test_that("a leading UTF-8 BOM is stripped from the first URL", {
  bytes <- c(
    as.raw(c(0xEF, 0xBB, 0xBF)),
    charToRaw("https://a/\nhttps://b/")
  )
  rows <- parse_sitemap_text(bytes)
  expect_identical(rows$loc, c("https://a/", "https://b/"))
  # U+FEFF survives trimws(), so guard the leading codepoint directly.
  expect_false(utf8ToInt(substr(rows$loc[[1L]], 1L, 1L)) == 65279L)
})

test_that("a BOM-only document yields the zero-row schema", {
  expect_identical(nrow(parse_sitemap_text(as.raw(c(0xEF, 0xBB, 0xBF)))), 0L)
})

test_that("a non-UTF-8 byte-order mark is rejected", {
  expect_error(
    parse_sitemap_text(as.raw(c(0xFF, 0xFE, 0x68, 0x00, 0x74, 0x00))),
    class = "sitemapr_text_parse_error"
  )
  expect_error(
    parse_sitemap_text(as.raw(c(0xFE, 0xFF, 0x00, 0x68))),
    class = "sitemapr_text_parse_error"
  )
  expect_error(
    parse_sitemap_text(as.raw(c(0x00, 0x00, 0xFE, 0xFF, 0x00))),
    class = "sitemapr_text_parse_error"
  )
  expect_error(
    parse_sitemap_text(as.raw(c(0xFF, 0xFE, 0x00, 0x00, 0x68))),
    class = "sitemapr_text_parse_error"
  )
})

test_that("undecodable bytes raise a classed condition, not a bare error", {
  # An embedded NUL makes rawToChar() fail; the module contract is that every
  # failure is classed (architecture.md section 3).
  expect_error(
    parse_sitemap_text(c(charToRaw("https://a/"), as.raw(0L), charToRaw("b"))),
    class = "sitemapr_text_parse_error"
  )
})

test_that("source_sitemap provenance is written to every row", {
  rows <- parse_sitemap_text(
    "https://a/\nhttps://b/",
    source_sitemap = "submitted-directly"
  )
  expect_identical(rows$source_sitemap, rep("submitted-directly", 2L))
})
