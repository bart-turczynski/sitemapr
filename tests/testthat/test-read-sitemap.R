# Unit tests for the read_sitemap() entry point (R/read-sitemap.R). Offline:
# local sources use tempfiles; URL sources use httr2::local_mocked_responses,
# so the real network is never hit (CRAN-safe).

urlset_xml <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls, "</urlset>"
  )
}

write_tempfile <- function(bytes, ext) {
  path <- withr::local_tempfile(fileext = ext, .local_envir = parent.frame())
  if (is.character(bytes)) bytes <- charToRaw(bytes)
  writeBin(bytes, path)
  path
}

gz_of <- function(text) {
  tf <- withr::local_tempfile(fileext = ".gz")
  con <- gzfile(tf, "wb")
  writeBin(charToRaw(text), con)
  close(con)
  readBin(tf, what = "raw", n = file.info(tf)$size)
}

# Build a mock that dispatches on the request URL via a named map of bodies.
mock_by_url <- function(map, status = 200L,
                        content_type = "application/xml") {
  function(req) {
    body <- map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    if (is.character(body)) body <- charToRaw(body)
    httr2::response(
      status_code = status, url = req$url,
      headers = list("Content-Type" = content_type), body = body
    )
  }
}

# ---- local sources -----------------------------------------------------------

test_that("a local XML urlset file yields rows and a sources attribute", {
  path <- write_tempfile(urlset_xml("https://a/1", "https://a/2"), ".xml")
  res <- read_sitemap(path)
  expect_s3_class(res, "tbl_df")
  expect_identical(res$loc, c("https://a/1", "https://a/2"))
  expect_identical(res$source_sitemap, rep(path, 2L))
  expect_false(is.null(attr(res, "sources")))
  expect_identical(attr(res, "sources")$format, "xml-urlset")
  expect_identical(nrow(attr(res, "problems")), 0L)
})

test_that("a local text sitemap file yields rows", {
  path <- write_tempfile("https://a/\nhttps://b/\n", ".txt")
  expect_identical(read_sitemap(path)$loc, c("https://a/", "https://b/"))
})

test_that("a local gzipped XML sitemap is decompressed transparently", {
  path <- write_tempfile(gz_of(urlset_xml("https://g/1")), ".xml.gz")
  res <- read_sitemap(path)
  expect_identical(res$loc, "https://g/1")
})

test_that("the columns are exactly the parse contract, with no findings code", {
  path <- write_tempfile(urlset_xml("https://a/1"), ".xml")
  res <- read_sitemap(path)
  expect_identical(
    names(res),
    c("loc", "lastmod", "changefreq", "priority", "images", "video",
      "news", "alternates", "source_sitemap")
  )
  expect_false("code" %in% names(res)) # never a findings tibble
})

# ---- URL sources -------------------------------------------------------------

test_that("a fetched urlset is parsed with provenance from the final URL", {
  url <- "https://example.com/sitemap.xml"
  httr2::local_mocked_responses(
    mock_by_url(setNames(list(urlset_xml("https://a/1", "https://a/2")), url))
  )
  res <- read_sitemap(url)
  expect_identical(res$loc, c("https://a/1", "https://a/2"))
  expect_identical(unique(res$source_sitemap), url)
  expect_identical(attr(res, "sources")$final_url, url)
})

test_that("an entry-point 500 raises a classed error naming URL and status", {
  url <- "https://example.com/sitemap.xml"
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 500L, url = req$url)
  })
  err <- tryCatch(
    suppressWarnings(read_sitemap(url)),
    error = function(e) e
  )
  expect_s3_class(err, "sitemapr_entrypoint_error")
  expect_identical(err$status, 500L)
  expect_identical(err$url, url)
})

test_that("unsupported content raises sitemapr_unsupported_format", {
  url <- "https://example.com/page.html"
  httr2::local_mocked_responses(
    mock_by_url(
      setNames(list("<html><body>hi</body></html>"), url),
      content_type = "text/html"
    )
  )
  expect_error(
    read_sitemap(url),
    class = "sitemapr_unsupported_format"
  )
})

# ---- index expansion ---------------------------------------------------------
# Recursive bounded expansion lives in R/index-expansion.R (and is unit-tested
# in test-index-expansion.R); these cases cover read_sitemap()'s integration of
# it for the common single-level index.

test_that("a sitemap index expands one level, attributing rows to children", {
  index_url <- "https://example.com/sitemap_index.xml"
  c1 <- "https://example.com/s1.xml"
  c2 <- "https://example.com/s2.xml"
  index_xml <- paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<sitemap><loc>", c1, "</loc></sitemap>",
    "<sitemap><loc>", c2, "</loc></sitemap>",
    "</sitemapindex>"
  )
  httr2::local_mocked_responses(mock_by_url(setNames(
    list(index_xml, urlset_xml("https://a/1"), urlset_xml("https://b/1")),
    c(index_url, c1, c2)
  )))

  res <- read_sitemap(index_url)
  expect_setequal(res$loc, c("https://a/1", "https://b/1"))
  expect_identical(
    res$source_sitemap[res$loc == "https://a/1"], c1
  )
  expect_identical(
    res$source_sitemap[res$loc == "https://b/1"], c2
  )
  # sources attribute records the index plus both children.
  expect_identical(nrow(attr(res, "sources")), 3L)
})

test_that("an unfetchable index child becomes a warning problem", {
  index_url <- "https://example.com/sitemap_index.xml"
  c1 <- "https://example.com/s1.xml"
  c2 <- "https://example.com/missing.xml"
  index_xml <- paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<sitemap><loc>", c1, "</loc></sitemap>",
    "<sitemap><loc>", c2, "</loc></sitemap>",
    "</sitemapindex>"
  )
  # c2 is absent from the map -> mock returns 404.
  httr2::local_mocked_responses(mock_by_url(setNames(
    list(index_xml, urlset_xml("https://a/1")),
    c(index_url, c1)
  )))

  res <- suppressWarnings(read_sitemap(index_url))
  expect_identical(res$loc, "https://a/1") # partial result
  problems <- attr(res, "problems")
  expect_identical(nrow(problems), 1L)
  expect_identical(problems$severity, "warning")
  expect_match(problems$subject_ref, "missing.xml", fixed = TRUE)
})

# ---- input validation --------------------------------------------------------

test_that("a non-scalar or empty input raises sitemapr_bad_input", {
  expect_error(read_sitemap(c("a", "b")), class = "sitemapr_bad_input")
  expect_error(read_sitemap(character(0)), class = "sitemapr_bad_input")
  expect_error(read_sitemap(NA_character_), class = "sitemapr_bad_input")
  expect_error(read_sitemap(""), class = "sitemapr_bad_input")
})

# ---- fetch body exposure -----------------------------------------------------

test_that("fetch_source attaches the raw body as an attribute", {
  url <- "https://example.com/sitemap.xml"
  body <- urlset_xml("https://a/1")
  httr2::local_mocked_responses(mock_by_url(setNames(list(body), url)))
  rec <- fetch_source(url)
  expect_identical(attr(rec, "body"), charToRaw(body))
})
