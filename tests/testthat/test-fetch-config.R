test_that("fetch_limits() returns the ADR-003 defaults with correct types", {
  withr::local_options(list(
    sitemapr.timeout = NULL,
    sitemapr.max_redirects = NULL,
    sitemapr.max_bytes = NULL
  ))

  lim <- fetch_limits()

  expect_identical(lim$timeout, 30)
  expect_identical(lim$max_redirects, 5L)
  expect_identical(lim$max_bytes, 524288000L)

  expect_type(lim$timeout, "double")
  expect_type(lim$max_redirects, "integer")
  expect_type(lim$max_bytes, "integer")
})

test_that("fetch_limits() arguments override the defaults", {
  withr::local_options(list(
    sitemapr.timeout = NULL,
    sitemapr.max_redirects = NULL,
    sitemapr.max_bytes = NULL
  ))

  lim <- fetch_limits(timeout = 5, max_redirects = 2L, max_bytes = 1024L)

  expect_identical(lim$timeout, 5)
  expect_identical(lim$max_redirects, 2L)
  expect_identical(lim$max_bytes, 1024L)
})

test_that("fetch_limits() falls back to sitemapr.* options", {
  withr::local_options(list(
    sitemapr.timeout = 12,
    sitemapr.max_redirects = 9L,
    sitemapr.max_bytes = 4096L
  ))

  lim <- fetch_limits()

  expect_identical(lim$timeout, 12)
  expect_identical(lim$max_redirects, 9L)
  expect_identical(lim$max_bytes, 4096L)
})

test_that("default_user_agent() follows the documented pattern", {
  ua <- default_user_agent()

  expect_match(
    ua,
    "^sitemapr/[0-9.]+.*\\(\\+https://github\\.com/bart-turczynski/sitemapr\\)$"
  )

  version <- sub("^sitemapr/([0-9.]+).*$", "\\1", ua)
  expect_true(nzchar(version))
})

test_that("source_metadata() returns the 13 contract columns in order", {
  meta <- source_metadata()

  expect_s3_class(meta, "data.frame")
  expect_identical(nrow(meta), 1L)
  expect_identical(
    names(meta),
    c(
      "requested_url",
      "final_url",
      "status",
      "redirect_chain",
      "content_type",
      "charset",
      "bytes",
      "timing",
      "error_class",
      "format",
      "root",
      "namespaces",
      "profile_id"
    )
  )
})

test_that("source_metadata() uses the contract column types", {
  meta <- source_metadata()

  expect_type(meta$requested_url, "character")
  expect_type(meta$final_url, "character")
  expect_type(meta$status, "integer")
  expect_type(meta$content_type, "character")
  expect_type(meta$charset, "character")
  expect_type(meta$bytes, "integer")
  expect_type(meta$timing, "double")
  expect_type(meta$error_class, "character")
  expect_type(meta$format, "character")
  expect_type(meta$root, "character")
  expect_type(meta$profile_id, "character")

  expect_true(is.list(meta$redirect_chain))
  expect_true(is.list(meta$namespaces))
})

test_that("source_metadata() defaults downstream fields to NA / empty", {
  meta <- source_metadata()

  expect_true(is.na(meta$root))
  expect_true(is.na(meta$profile_id))
  expect_identical(meta$namespaces[[1L]], list())
  expect_identical(meta$redirect_chain[[1L]], list())
})

test_that("source_metadata() carries supplied values including list-columns", {
  meta <- source_metadata(
    requested_url = "https://example.com/sitemap.xml",
    final_url = "https://example.com/final.xml",
    status = 200L,
    redirect_chain = c("https://example.com/sitemap.xml"),
    content_type = "application/xml",
    charset = "UTF-8",
    bytes = 4096L,
    timing = 0.5
  )

  expect_identical(meta$requested_url, "https://example.com/sitemap.xml")
  expect_identical(meta$status, 200L)
  expect_identical(meta$bytes, 4096L)
  expect_identical(meta$timing, 0.5)
  expect_identical(
    meta$redirect_chain[[1L]],
    c("https://example.com/sitemap.xml")
  )
})
