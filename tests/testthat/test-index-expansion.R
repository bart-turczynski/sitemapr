test_that("index_limits() returns the documented defaults with correct types", {
  withr::local_options(list(
    sitemapr.max_index_depth = NULL,
    sitemapr.max_index_children = NULL
  ))

  lim <- index_limits()

  expect_identical(lim$max_depth, 3L)
  expect_identical(lim$max_children, 50000L)

  expect_type(lim$max_depth, "integer")
  expect_type(lim$max_children, "integer")
})

test_that("index_limits() arguments override the defaults", {
  withr::local_options(list(
    sitemapr.max_index_depth = NULL,
    sitemapr.max_index_children = NULL
  ))

  lim <- index_limits(max_depth = 1L, max_children = 2L)

  expect_identical(lim$max_depth, 1L)
  expect_identical(lim$max_children, 2L)
})

test_that("index_limits() falls back to sitemapr.* options", {
  withr::local_options(list(
    sitemapr.max_index_depth = 5L,
    sitemapr.max_index_children = 9L
  ))

  lim <- index_limits()

  expect_identical(lim$max_depth, 5L)
  expect_identical(lim$max_children, 9L)
})

test_that("index_loc_key() canonicalizes for cycle detection and dedup", {
  # Default port collapses to no port (identity-equivalent).
  expect_identical(
    index_loc_key("https://example.com:443/sitemap.xml"),
    index_loc_key("https://example.com/sitemap.xml")
  )
  # Query is significant (a paginated index child is a distinct resource).
  expect_false(identical(
    index_loc_key("https://example.com/sitemap.xml?page=1"),
    index_loc_key("https://example.com/sitemap.xml?page=2")
  ))
})
