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
      "url",
      "final_url",
      "status_code",
      "content_type",
      "detected_type",
      "xml_root",
      "is_compressed",
      "child_count",
      "sample",
      "problems",
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

# ---- unrecognized and malformed bodies ---------------------------------------

test_that("well-formed but unrecognized XML is classified as xml_other", {
  path <- write_probe_file("<catalog><item id='1'/></catalog>")
  res <- probe_url(path)

  expect_identical(res$detected_type, "xml_other")
  expect_identical(res$xml_root, "catalog")
  # An unrecognized root has no child contract, so nothing is counted.
  expect_identical(res$child_count, NA_integer_)
  expect_identical(res$problems$message, character(0))
  expect_match(res$suggested_next, "inspect the document manually")
})

test_that("a malformed XML body downgrades to parse_error", {
  # Sniffs as a urlset on its opening tag, but the document never closes.
  truncated <- sub("</urlset>", "", urlset_xml("https://a/1"), fixed = TRUE)
  res <- probe_url(write_probe_file(truncated))

  expect_identical(res$detected_type, "parse_error")
  expect_identical(res$xml_root, NA_character_)
  expect_identical(nrow(res$problems), 1L)
  expect_match(res$problems$message, "not well-formed")
  expect_match(res$suggested_next, "not a recognized sitemap format")
})

test_that("an undecompressable gzip body is parse_error, still compressed", {
  # A valid gzip magic + header followed by garbage: sniffs as gzip, then
  # fails to inflate.
  corrupt <- as.raw(c(0x1f, 0x8b, 0x08, 0x00, 1, 2, 3, 4, 5, 6, 7, 8, 9))
  path <- withr::local_tempfile(fileext = ".gz")
  writeBin(corrupt, path)
  res <- probe_url(path)

  expect_identical(res$detected_type, "parse_error")
  # The compression is still reported: detection succeeded, inflation did not.
  expect_true(res$is_compressed)
  expect_identical(nrow(res$problems), 1L)
  expect_match(res$problems$message, "could not be decompressed")
})

# ---- body-sample helpers -----------------------------------------------------

test_that("an absent or unprintable body yields no excerpt", {
  expect_identical(probe_text_excerpt(NULL), NA_character_)
  expect_identical(probe_text_excerpt(raw(0)), NA_character_)
  # Control bytes are stripped, leaving nothing to show.
  expect_identical(probe_text_excerpt(as.raw(c(1, 2, 3))), NA_character_)
})

test_that("a long excerpt is truncated to max_chars with an ellipsis", {
  long <- paste(rep("abcdefghij", 80L), collapse = " ")
  out <- probe_text_excerpt(charToRaw(long))

  expect_identical(nchar(out), 503L)
  expect_match(out, "\\.\\.\\.$")
  expect_identical(substr(out, 1L, 10L), "abcdefghij")

  # An explicit smaller budget is honoured.
  expect_identical(nchar(probe_text_excerpt(charToRaw(long), 20L)), 23L)
})

test_that("an absent body yields no text URL count", {
  expect_identical(probe_text_url_count(NULL), NA_integer_)
  expect_identical(probe_text_url_count(raw(0)), NA_integer_)
})

test_that("a non-robots body at a non-robots URL is not robots.txt", {
  # No directives to read, and the path is not /robots.txt.
  expect_false(probe_looks_like_robots("https://e/list.txt", raw(0)))
  expect_false(probe_looks_like_robots("https://e/list.txt", as.raw(1:3)))
  # The path alone is sufficient, even with an unreadable body.
  expect_true(probe_looks_like_robots("https://e/robots.txt", raw(0)))
})

test_that("print shows final_url only when it differs from the request URL", {
  body <- charToRaw(urlset_xml("https://example.com/"))
  httr2::local_mocked_responses(function(req) {
    httr2::response(
      status_code = 200L,
      url = "https://example.com/final.xml",
      headers = list(`content-type` = "application/xml"),
      body = body
    )
  })
  redirected <- probe_url("https://example.com/start.xml")

  expect_identical(redirected$final_url, "https://example.com/final.xml")
  expect_output(print(redirected), "final_url")

  # A local probe has final_url == url, so the line is suppressed.
  direct <- probe_url(write_probe_file(urlset_xml("https://a/1")))
  expect_false(any(grepl(
    "final_url",
    capture.output(print(direct)),
    fixed = TRUE
  )))
})
