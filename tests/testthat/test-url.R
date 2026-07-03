test_that("parse_url_adapter emits Punycode host for Unicode input", {
  parsed <- sitemapr:::parse_url_adapter("https://münchen.de/")
  expect_identical(parsed$host, "xn--mnchen-3ya.de")
})

test_that("parse_url_adapter maps an IRI path to its percent-encoded URI", {
  parsed <- sitemapr:::parse_url_adapter("https://example.com/パス?q=テスト")
  expect_identical(parsed$path, "/%E3%83%91%E3%82%B9")
  expect_identical(parsed$query, "q=%E3%83%86%E3%82%B9%E3%83%88")
})

test_that("parse_url_adapter leaves an ASCII path/query untouched", {
  parsed <- sitemapr:::parse_url_adapter(
    "https://example.com/sitemap.php?page=2&type=products"
  )
  expect_identical(parsed$path, "/sitemap.php")
  expect_identical(parsed$query, "page=2&type=products")
})

test_that("parse_url_adapter does not double-encode an existing %XX octet", {
  parsed <- sitemapr:::parse_url_adapter("https://example.com/a%20b/x")
  expect_identical(parsed$path, "/a%20b/x")
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

# --- ADR-005: rurl fast-path gate ------------------------------------------
# parse_url_adapter() routes plain-ASCII no-op URLs through a cheap regex split
# and only invokes rurl where canonicalization can change the URL. The fast path
# must be byte-identical to rurl on every column sitemapr consumes.

test_that("parse_url_adapter fast path matches rurl on read columns", {
  read_cols <- c(
    "original_url",
    "scheme",
    "host",
    "port",
    "path",
    "query",
    "user",
    "is_ip_host"
  )
  corpus <- c(
    # fast-eligible
    "https://example.com/p/q",
    "https://example.com/search?q=a&b=c",
    "HTTPS://Example.COM/Path",
    "https://example.com:8080/p",
    "https://example.com:443/p",
    "https://sub.example.co.uk/a/b/c",
    "https://example.com/tilde~ok-dash_dot.html",
    "https://example.com/",
    "https://example.com",
    "https://localhost/p",
    "https://example.com/a?x=1#frag",
    # must defer to rurl
    "https://example.com/café",
    "https://café.com/p",
    "https://example.com/p%41q",
    "https://example.com/a/../b",
    "https://example.com/a//b",
    "https://example.com/(paren)",
    "https://example.com/p?u=1+2",
    "https://example.com/a?k=v;w=z",
    "https://1.2.3.4/x",
    "https://2130706433/x",
    "https://user:pw@example.com/p",
    "ftp://example.com/p",
    "https://example.com/a b",
    "not a url",
    NA_character_
  )
  fast <- sitemapr:::parse_url_adapter(corpus)
  slow <- sitemapr:::rurl_parse(corpus)
  for (col in read_cols) {
    expect_identical(
      as.character(fast[[col]]),
      as.character(slow[[col]]),
      info = col
    )
  }
})

test_that("parse_url_adapter fast path is differentially equivalent to rurl", {
  skip_on_cran()
  set.seed(42)
  read_cols <- c(
    "original_url",
    "scheme",
    "host",
    "port",
    "path",
    "query",
    "user",
    "is_ip_host"
  )
  scheme <- c("https", "http", "HTTP", "ftp", "")
  host <- c(
    "example.com",
    "sub.ex.co.uk",
    "localhost",
    "1.2.3.4",
    "2130706433",
    "xn--caf-dma.com",
    "café.com",
    "EXAMPLE.COM",
    "a-b.example.io",
    "[::1]"
  )
  port <- c("", ":80", ":443", ":8080", ":x")
  path <- c(
    "",
    "/",
    "/a/b",
    "/a/../b",
    "/a//b",
    "/p%41",
    "/(x)",
    "/t~_-.d",
    "/é",
    "/a;b",
    "/a b"
  )
  query <- c("", "?q=1", "?a=1&b=2", "?u=1+2", "?k=v;w", "?x=%20", "?z=9&ok=y")
  frag <- c("", "#f", "#sec 1")
  gen <- function() {
    paste0(
      sample(scheme, 1),
      if (runif(1) < 0.85) "://" else ":",
      if (runif(1) < 0.1) "user:pw@" else "",
      sample(host, 1),
      sample(port, 1),
      sample(path, 1),
      sample(query, 1),
      sample(frag, 1)
    )
  }
  urls <- c(vapply(seq_len(2000L), function(i) gen(), character(1)), "http://")
  fast <- sitemapr:::parse_url_adapter(urls)
  slow <- sitemapr:::rurl_parse(urls)
  for (col in read_cols) {
    expect_identical(
      as.character(fast[[col]]),
      as.character(slow[[col]]),
      info = col
    )
  }
})

test_that("url_needs_rurl flags exactly the non-no-op URLs", {
  expect_false(sitemapr:::url_needs_rurl("https://example.com/a/b?x=1&y=2"))
  expect_true(sitemapr:::url_needs_rurl("https://example.com/café"))
  expect_true(sitemapr:::url_needs_rurl("https://example.com/p%20q"))
  expect_true(sitemapr:::url_needs_rurl("https://user@example.com/p"))
  expect_true(sitemapr:::url_needs_rurl("https://example.com/(x)"))
})

test_that("an IP-literal host is never resolved on the fast path", {
  # is_ip_host feeds SSRF checks (R/ssrf.R); the fast path must defer every
  # IP-literal form to rurl rather than guess (resolved == FALSE).
  ip_literals <- c(
    "https://1.2.3.4/x",
    "https://2130706433/x",
    "https://[::1]/x"
  )
  expect_false(any(sitemapr:::url_fast_components_vec(ip_literals)$resolved))
})
