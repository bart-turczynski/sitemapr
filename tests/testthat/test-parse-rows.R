# Unit tests for the read_sitemap() row-schema constructor (R/parse-rows.R).

test_that("empty_sitemap_rows is a 0-row tibble with the 9-column contract", {
  rows <- empty_sitemap_rows()
  expect_s3_class(rows, "tbl_df")
  expect_identical(nrow(rows), 0L)
  expect_identical(
    names(rows),
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
  expect_type(rows$lastmod, "character")
  expect_type(rows$loc, "character")
  expect_type(rows$priority, "character")
  expect_type(rows$images, "list")
})

test_that("loc sets the row count and scalar fields default to NA", {
  rows <- sitemap_rows(loc = c("https://a/", "https://b/"))
  expect_identical(nrow(rows), 2L)
  expect_true(all(is.na(rows$lastmod)))
  expect_true(all(is.na(rows$changefreq)))
  expect_true(all(is.na(rows$priority)))
  expect_true(all(is.na(rows$source_sitemap)))
})

test_that("list-columns default to a per-row NULL element", {
  rows <- sitemap_rows(loc = c("https://a/", "https://b/"))
  expect_type(rows$images, "list")
  expect_length(rows$images, 2L)
  expect_null(rows$images[[1L]])
  expect_null(rows$video[[2L]])
})

test_that("lastmod is kept as the raw character string (faithful form)", {
  rows <- sitemap_rows(
    loc = "https://a/",
    lastmod = "2026-01-02T03:04:05Z"
  )
  expect_type(rows$lastmod, "character")
  expect_identical(rows$lastmod[[1L]], "2026-01-02T03:04:05Z")
})

test_that("priority is kept as the raw character string (faithful form)", {
  rows <- sitemap_rows(loc = "https://a/", priority = "0.8")
  expect_type(rows$priority, "character")
  expect_identical(rows$priority[[1L]], "0.8")
})

test_that("project_typed_rows coerces lastmod/priority to the typed contract", {
  rows <- sitemap_rows(
    loc = c("https://a/", "https://b/"),
    lastmod = c("2026-01-02T03:04:05Z", NA_character_),
    priority = c("0.8", NA_character_)
  )
  typed <- project_typed_rows(rows)
  expect_s3_class(typed$lastmod, "POSIXct")
  expect_identical(attr(typed$lastmod, "tzone"), "UTC")
  expect_false(is.na(typed$lastmod[[1L]]))
  expect_true(is.na(typed$lastmod[[2L]]))
  expect_type(typed$priority, "double")
  expect_identical(typed$priority[[1L]], 0.8)
  expect_true(is.na(typed$priority[[2L]]))
})

test_that("project_typed_rows handles the zero-row case", {
  typed <- project_typed_rows(empty_sitemap_rows())
  expect_identical(nrow(typed), 0L)
  expect_s3_class(typed$lastmod, "POSIXct")
  expect_type(typed$priority, "double")
})

test_that("scalar fields recycle to the row count", {
  rows <- sitemap_rows(
    loc = c("https://a/", "https://b/", "https://c/"),
    changefreq = "daily",
    priority = "0.5",
    source_sitemap = "https://a/sitemap.xml"
  )
  expect_identical(rows$changefreq, rep("daily", 3L))
  expect_identical(rows$priority, rep("0.5", 3L))
  expect_identical(rows$source_sitemap, rep("https://a/sitemap.xml", 3L))
})

test_that("per-row list-column data is preserved", {
  imgs <- list(list(loc = "https://a/1.jpg"), NULL)
  rows <- sitemap_rows(loc = c("https://a/", "https://b/"), images = imgs)
  expect_identical(rows$images[[1L]]$loc, "https://a/1.jpg")
  expect_null(rows$images[[2L]])
})

test_that("a length mismatch raises sitemapr_row_length_error", {
  expect_error(
    sitemap_rows(
      loc = c("https://a/", "https://b/"),
      changefreq = c("daily", "weekly", "monthly")
    ),
    class = "sitemapr_row_length_error"
  )
})

test_that("a mismatched list-column length raises the same error", {
  expect_error(
    sitemap_rows(
      loc = c("https://a/", "https://b/"),
      images = list(list(), list(), list())
    ),
    class = "sitemapr_row_length_error"
  )
})
