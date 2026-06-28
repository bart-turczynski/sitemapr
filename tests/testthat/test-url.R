test_that("parse_url_adapter emits Punycode host for Unicode input", {
  parsed <- sitemapr:::parse_url_adapter("https://münchen.de/")
  expect_identical(parsed$host, "xn--mnchen-3ya.de")
})

test_that("parse_url_adapter resolves dot-segments in the path", {
  parsed <- sitemapr:::parse_url_adapter(
    "https://example.com/a/../sitemaps/./sitemap.xml"
  )
  expect_identical(parsed$path, "/sitemaps/sitemap.xml")
})

test_that("build_loc_key retains the port", {
  parsed <- sitemapr:::parse_url_adapter("https://example.com:8443/p")
  key <- sitemapr:::build_loc_key(parsed)
  expect_true(grepl("8443", key, fixed = TRUE))
})

test_that("build_loc_key distinguishes URLs that differ only by port", {
  parsed <- sitemapr:::parse_url_adapter(
    c("https://example.com/p", "https://example.com:8443/p")
  )
  keys <- sitemapr:::build_loc_key(parsed)
  expect_false(keys[[1]] == keys[[2]])
})

test_that("build_loc_key keeps query/fragment/port that clean_url drops", {
  url <- "https://user@example.com:8443/p?q=1#f"
  parsed <- sitemapr:::parse_url_adapter(url)
  key <- sitemapr:::build_loc_key(parsed)

  expect_true(grepl("8443", key, fixed = TRUE))
  expect_true(grepl("?q=1", key, fixed = TRUE))
  expect_true(grepl("#f", key, fixed = TRUE))
  expect_true(grepl("user@", key, fixed = TRUE))

  # clean_url drops exactly these components, proving the key is distinct.
  expect_false(grepl("8443", parsed$clean_url, fixed = TRUE))
  expect_false(grepl("q=1", parsed$clean_url, fixed = TRUE))
})
