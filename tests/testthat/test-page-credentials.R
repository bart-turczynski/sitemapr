# Offline tests for credential handling on inspected pages (SITE-ksiytozz).
#
# Page inspection fetches the `<loc>`s a validate call gathered. A page carries
# the request policy's credentials only when it is on the origin of a source
# that advertised it; a page another origin's sitemap names gets none. Pages a
# local file advertised keep them: the caller chose the file's contents.

page_cred_policy <- function() {
  request_policy(
    auth = request_auth_bearer("s3cret-token"),
    headers = list("X-Env" = "staging", "Cookie" = "session=abc")
  )
}

page_cred_urlset <- function(url, locs) {
  body <- paste0(
    "<?xml version=\"1.0\"?>",
    "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
    paste0("<url><loc>", locs, "</loc></url>", collapse = ""),
    "</urlset>"
  )
  httr2::response(
    status_code = 200L,
    url = url,
    headers = list("Content-Type" = "application/xml"),
    body = charToRaw(body)
  )
}

page_cred_html <- function(url) {
  httr2::response(
    status_code = 200L,
    url = url,
    headers = list("Content-Type" = "text/html"),
    body = charToRaw("<html><head><title>t</title></head><body></body></html>")
  )
}

# Names of the credential-bearing headers on a built request, lower-cased.
page_cred_names <- function(req) {
  nms <- ascii_lower(names(req$headers))
  intersect(nms, c("authorization", "proxy-authorization", "cookie"))
}

# Serve the routed sitemaps, an HTML page for any other URL, and record every
# built request by URL.
page_cred_mock <- function(routes, env = parent.frame()) {
  seen <- new.env(parent = emptyenv())
  seen$reqs <- list()
  httr2::local_mocked_responses(
    function(req) {
      seen$reqs[[req$url]] <- req
      resp <- routes[[req$url]]
      if (is.null(resp)) page_cred_html(req$url) else resp
    },
    env = env
  )
  seen
}

page_cred_validate <- function(x, fun = validate_sitemap) {
  suppressWarnings(fun(
    x,
    policy = page_cred_policy(),
    inspect_pages = TRUE,
    page_mode = "full"
  ))
}

test_that("a page on another origin than its sitemap gets no credentials", {
  seen <- page_cred_mock(list(
    "https://example.com/s.xml" = page_cred_urlset(
      "https://example.com/s.xml",
      c("https://example.com/p", "https://other.example/q")
    )
  ))
  page_cred_validate("https://example.com/s.xml")

  expect_setequal(
    page_cred_names(seen$reqs[["https://example.com/p"]]),
    c("authorization", "cookie")
  )
  other <- seen$reqs[["https://other.example/q"]]
  expect_identical(page_cred_names(other), character(0))
  expect_identical(other$headers[["X-Env"]], "staging")
})

test_that("each source's pages keep only that source's origin", {
  seen <- page_cred_mock(list(
    "https://example.com/s.xml" = page_cred_urlset(
      "https://example.com/s.xml",
      c("https://example.com/p", "https://third.example/r")
    ),
    "https://other.example/t.xml" = page_cred_urlset(
      "https://other.example/t.xml",
      "https://other.example/q"
    )
  ))
  page_cred_validate(
    c("https://example.com/s.xml", "https://other.example/t.xml"),
    fun = validate_sitemaps
  )

  expect_length(page_cred_names(seen$reqs[["https://example.com/p"]]), 2L)
  expect_length(page_cred_names(seen$reqs[["https://other.example/q"]]), 2L)
  expect_identical(
    page_cred_names(seen$reqs[["https://third.example/r"]]),
    character(0)
  )
})

test_that("a page any advertising source shares an origin with keeps them", {
  seen <- page_cred_mock(list(
    "https://example.com/s.xml" = page_cred_urlset(
      "https://example.com/s.xml",
      "https://other.example/q"
    ),
    "https://other.example/t.xml" = page_cred_urlset(
      "https://other.example/t.xml",
      "https://other.example/q"
    )
  ))
  page_cred_validate(
    c("https://example.com/s.xml", "https://other.example/t.xml"),
    fun = validate_sitemaps
  )

  expect_length(page_cred_names(seen$reqs[["https://other.example/q"]]), 2L)
})

test_that("pages a local sitemap advertises keep the credentials", {
  path <- withr::local_tempfile(fileext = ".xml")
  writeBin(page_cred_urlset("file", "https://example.com/p")$body, path)
  seen <- page_cred_mock(list())
  page_cred_validate(path)

  expect_setequal(
    page_cred_names(seen$reqs[["https://example.com/p"]]),
    c("authorization", "cookie")
  )
})
