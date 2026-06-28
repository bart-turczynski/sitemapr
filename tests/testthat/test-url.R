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

test_that("build_loc_key keeps query/port/userinfo that clean_url drops", {
  url <- "https://user@example.com:8443/p?q=1"
  parsed <- sitemapr:::parse_url_adapter(url)
  key <- sitemapr:::build_loc_key(parsed)

  expect_true(grepl("8443", key, fixed = TRUE))
  expect_true(grepl("?q=1", key, fixed = TRUE))
  expect_true(grepl("user@", key, fixed = TRUE))

  # clean_url drops exactly these components, proving the key is distinct.
  expect_false(grepl("8443", parsed$clean_url, fixed = TRUE))
  expect_false(grepl("q=1", parsed$clean_url, fixed = TRUE))
})

test_that("build_loc_key keeps a contentful query verbatim (SITE-vrgszbnu)", {
  parsed <- sitemapr:::parse_url_adapter(
    "https://example.com/sitemap.php?page=2&type=products"
  )
  expect_identical(
    sitemapr:::build_loc_key(parsed),
    "https://example.com/sitemap.php?page=2&type=products"
  )
})

test_that("build_loc_key drops the fragment (not part of fetch or identity)", {
  parsed <- sitemapr:::parse_url_adapter("https://example.com/sitemap.xml#frag")
  key <- sitemapr:::build_loc_key(parsed)
  expect_identical(key, "https://example.com/sitemap.xml")
  expect_false(grepl("#", key, fixed = TRUE))
})

test_that("two URLs differing only by fragment share one identity", {
  parsed <- sitemapr:::parse_url_adapter(
    c("https://example.com/s", "https://example.com/s#a")
  )
  keys <- sitemapr:::build_loc_key(parsed)
  expect_identical(keys[[1]], keys[[2]])
})

test_that("build_loc_key collapses the scheme's default port to identity", {
  http_pair <- sitemapr:::build_loc_key(sitemapr:::parse_url_adapter(
    c("http://example.com:80/s", "http://example.com/s")
  ))
  expect_identical(http_pair[[1]], http_pair[[2]])

  https_pair <- sitemapr:::build_loc_key(sitemapr:::parse_url_adapter(
    c("https://example.com:443/s", "https://example.com/s")
  ))
  expect_identical(https_pair[[1]], https_pair[[2]])
})

test_that("a non-default port is still retained and distinguishing", {
  keys <- sitemapr:::build_loc_key(sitemapr:::parse_url_adapter(
    c("https://example.com:8443/s", "https://example.com/s")
  ))
  expect_true(grepl(":8443", keys[[1]], fixed = TRUE))
  expect_false(keys[[1]] == keys[[2]])
})

test_that("a mismatched default port (http:443) is not collapsed", {
  key <- sitemapr:::build_loc_key(
    sitemapr:::parse_url_adapter("http://example.com:443/s")
  )
  expect_true(grepl(":443", key, fixed = TRUE))
})
