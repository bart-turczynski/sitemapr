# Unit tests for probe_url() (R/probe.R). Offline: local sources use tempfiles;
# URL sources use httr2::local_mocked_responses, so the real network is never
# hit (CRAN-safe). A request-counting mock proves that a sitemap index is
# inspected without fetching its children.

urlset_xml <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    "</urlset>"
  )
}

index_xml <- function(...) {
  kids <- paste0("<sitemap><loc>", c(...), "</loc></sitemap>", collapse = "")
  paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    kids,
    "</sitemapindex>"
  )
}

write_probe_file <- function(text, ext = ".xml") {
  path <- withr::local_tempfile(fileext = ext, .local_envir = parent.frame())
  writeBin(charToRaw(text), path)
  path
}

# A request-counting mock that dispatches on the request URL via a named map of
# bodies and records how many requests reached req_perform().
counting_mock <- function(counter, map, content_type = "application/xml") {
  function(req) {
    counter$n <- counter$n + 1L
    body <- map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = content_type),
      body = charToRaw(body)
    )
  }
}

# ---- local sources -----------------------------------------------------------

test_that("a local urlset is detected as a sitemap with a child count", {
  path <- write_probe_file(urlset_xml("https://a/1", "https://a/2"))
  res <- probe_url(path)

  expect_s3_class(res, "sitemapr_probe")
  expect_identical(res$detected_type, "sitemap")
  expect_identical(res$xml_root, "urlset")
  expect_identical(res$child_count, 2L)
  expect_false(res$is_compressed)
  expect_identical(nrow(res$problems), 0L)
  expect_match(res$suggested_next, "read_sitemap", fixed = TRUE)
  expect_named(
    res,
    c(
      "url", "final_url", "status_code", "content_type", "detected_type",
      "xml_root", "is_compressed", "child_count", "sample", "problems",
      "suggested_next"
    )
  )
})

test_that("a local sitemap index counts its direct children", {
  path <- write_probe_file(index_xml("https://a/s1.xml", "https://a/s2.xml"))
  res <- probe_url(path)

  expect_identical(res$detected_type, "sitemap_index")
  expect_identical(res$xml_root, "sitemapindex")
  expect_identical(res$child_count, 2L)
})

test_that("a gzipped local urlset is detected and flagged compressed", {
  raw_xml <- charToRaw(urlset_xml("https://g/1"))
  path <- withr::local_tempfile(fileext = ".xml.gz")
  con <- gzfile(path, "wb")
  writeBin(raw_xml, con)
  close(con)

  res <- probe_url(path)

  expect_identical(res$detected_type, "sitemap")
  expect_true(res$is_compressed)
  expect_identical(res$child_count, 1L)
})

test_that("a plain-text URL list is detected as a sitemap (reader parity)", {
  path <- write_probe_file("https://a/1\nhttps://a/2\nhttps://a/3\n", ".txt")
  res <- probe_url(path)

  expect_identical(res$detected_type, "sitemap")
  expect_identical(res$child_count, 3L)
  expect_true(is.na(res$xml_root))
  expect_match(res$suggested_next, "read_sitemap", fixed = TRUE)
  expect_identical(nrow(res$problems), 0L)
})

test_that("a genuinely non-sitemap (binary) local file is a parse_error", {
  # A NUL byte makes the sniffer classify this as binary, not text.
  path <- withr::local_tempfile(fileext = ".bin")
  writeBin(as.raw(c(0x00L, 0x01L, 0x02L, 0xFFL, 0x00L, 0x7FL)), path)
  res <- probe_url(path)

  expect_identical(res$detected_type, "parse_error")
  expect_identical(nrow(res$problems), 1L)
  expect_identical(res$problems$severity, "warning")
})

# ---- URL sources -------------------------------------------------------------

test_that("a fetched urlset is detected as a sitemap", {
  url <- "https://example.com/sitemap.xml"
  counter <- new.env(parent = emptyenv())
  counter$n <- 0L
  httr2::local_mocked_responses(
    counting_mock(counter, setNames(list(urlset_xml("https://a/1")), url))
  )

  res <- probe_url(url)

  expect_identical(res$detected_type, "sitemap")
  expect_identical(res$status_code, 200L)
  expect_identical(res$final_url, url)
  expect_identical(res$child_count, 1L)
  expect_identical(counter$n, 1L)
})

test_that("a sitemap index is counted WITHOUT fetching its children", {
  index_url <- "https://example.com/sitemap_index.xml"
  c1 <- "https://example.com/s1.xml"
  c2 <- "https://example.com/s2.xml"
  counter <- new.env(parent = emptyenv())
  counter$n <- 0L
  # Only the index is in the map; a child fetch would still bump the counter.
  httr2::local_mocked_responses(
    counting_mock(counter, setNames(list(index_xml(c1, c2)), index_url))
  )

  res <- probe_url(index_url)

  expect_identical(res$detected_type, "sitemap_index")
  expect_identical(res$child_count, 2L)
  # Exactly one request: the index itself. Children were counted, not fetched.
  expect_identical(counter$n, 1L)
})

test_that("a fetched feed is detected as a feed", {
  url <- "https://example.com/feed.xml"
  feed <- paste0(
    '<?xml version="1.0"?><rss version="2.0"><channel>',
    "<title>Example</title></channel></rss>"
  )
  httr2::local_mocked_responses(
    function(req) {
      httr2::response(
        status_code = 200L,
        url = req$url,
        headers = list("Content-Type" = "application/rss+xml"),
        body = charToRaw(feed)
      )
    }
  )

  res <- probe_url(url)

  expect_identical(res$detected_type, "feed")
  expect_identical(res$xml_root, "rss")
})

test_that("an HTML page is detected as html and suggests root discovery", {
  url <- "https://example.com/index.html"
  httr2::local_mocked_responses(
    function(req) {
      httr2::response(
        status_code = 200L,
        url = req$url,
        headers = list("Content-Type" = "text/html"),
        body = charToRaw("<!doctype html><html><body>hi</body></html>")
      )
    }
  )

  res <- probe_url(url)

  expect_identical(res$detected_type, "html")
  expect_match(res$suggested_next, "sitemap_tree", fixed = TRUE)
})

test_that("a robots.txt URL is detected as robots_txt", {
  url <- "https://example.com/robots.txt"
  httr2::local_mocked_responses(
    function(req) {
      httr2::response(
        status_code = 200L,
        url = req$url,
        headers = list("Content-Type" = "text/plain"),
        body = charToRaw("User-agent: *\nSitemap: https://example.com/s.xml\n")
      )
    }
  )

  res <- probe_url(url)

  expect_identical(res$detected_type, "robots_txt")
  expect_match(res$suggested_next, "sitemap_tree", fixed = TRUE)
})

test_that("a 404 is represented as not_found, not thrown", {
  url <- "https://example.com/missing.xml"
  httr2::local_mocked_responses(
    function(req) httr2::response(status_code = 404L, url = req$url)
  )

  res <- expect_no_error(suppressWarnings(probe_url(url)))

  expect_identical(res$detected_type, "not_found")
  expect_identical(res$status_code, 404L)
  expect_identical(nrow(res$problems), 1L)
})

test_that("a non-404 error status is represented as fetch_error", {
  url <- "https://example.com/boom.xml"
  httr2::local_mocked_responses(
    function(req) httr2::response(status_code = 500L, url = req$url)
  )

  res <- suppressWarnings(probe_url(url))

  expect_identical(res$detected_type, "fetch_error")
  expect_identical(res$status_code, 500L)
})

test_that("an SSRF block is represented as fetch_error, not thrown", {
  # A private host is refused by the structural SSRF guard; probe reports it.
  res <- expect_no_error(probe_url("http://127.0.0.1/sitemap.xml"))

  expect_identical(res$detected_type, "fetch_error")
  expect_identical(res$problems$category, "fetch")
})

# ---- input validation & printing ---------------------------------------------

test_that("invalid input raises sitemapr_bad_input", {
  expect_error(probe_url(character(0)), class = "sitemapr_bad_input")
  expect_error(probe_url(NA_character_), class = "sitemapr_bad_input")
  expect_error(probe_url(""), class = "sitemapr_bad_input")
  expect_error(probe_url(c("a", "b")), class = "sitemapr_bad_input")
  expect_error(probe_url(42), class = "sitemapr_bad_input")
})

test_that("the print method renders the key fields", {
  path <- write_probe_file(urlset_xml("https://a/1"))
  res <- probe_url(path)

  expect_output(print(res), "<sitemapr_probe>")
  expect_output(print(res), "detected_type")
  expect_output(print(res), "sitemap")
})
