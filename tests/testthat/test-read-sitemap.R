# Unit tests for the read_sitemap() entry point (R/read-sitemap.R). Offline:
# local sources use tempfiles; URL sources use httr2::local_mocked_responses,
# so the real network is never hit (CRAN-safe).

urlset_xml <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    "</urlset>"
  )
}

write_tempfile <- function(bytes, ext) {
  path <- withr::local_tempfile(fileext = ext, .local_envir = parent.frame())
  if (is.character(bytes)) {
    bytes <- charToRaw(bytes)
  }
  writeBin(bytes, path)
  path
}

gz_of <- function(text) {
  gz_of_raw(charToRaw(text))
}

gz_of_raw <- function(bytes) {
  tf <- withr::local_tempfile(fileext = ".gz")
  con <- gzfile(tf, "wb")
  writeBin(bytes, con)
  close(con)
  readBin(tf, what = "raw", n = file.info(tf)$size)
}

# Build a mock that dispatches on the request URL via a named map of bodies.
mock_by_url <- function(map, status = 200L, content_type = "application/xml") {
  function(req) {
    body <- map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    if (is.character(body)) {
      body <- charToRaw(body)
    }
    httr2::response(
      status_code = status,
      url = req$url,
      headers = list("Content-Type" = content_type),
      body = body
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

test_that("a submitted-list read combines deduplicated local sources", {
  p1 <- write_tempfile(urlset_xml("https://a/1"), ".xml")
  p2 <- write_tempfile(urlset_xml("https://b/1"), ".xml")

  res <- read_sitemaps(c(p1, p2, p1))

  expect_identical(res$loc, c("https://a/1", "https://b/1"))
  expect_identical(res$source_sitemap, c(p1, p2))
  expect_identical(nrow(attr(res, "sources")), 2L)
  expect_identical(nrow(attr(res, "problems")), 0L)
})

test_that("a submitted-list read records partial failures as problems", {
  good <- write_tempfile(urlset_xml("https://ok/1"), ".xml")
  bad <- write_tempfile("<html><body>not a sitemap</body></html>", ".html")

  res <- read_sitemap(c(good, bad))

  expect_identical(res$loc, "https://ok/1")
  problems <- attr(res, "problems")
  expect_identical(nrow(problems), 1L)
  expect_identical(problems$category, "classification")
  expect_identical(problems$subject_ref, bad)
})

test_that("the columns are exactly the parse contract, with no findings code", {
  path <- write_tempfile(urlset_xml("https://a/1"), ".xml")
  res <- read_sitemap(path)
  expect_named(
    res,
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
  expect_false("code" %in% names(res)) # never a findings tibble
})

test_that("combining no source metadata preserves the source schema", {
  out <- combine_source_metadata(list(NULL))

  expect_s3_class(out, "data.frame")
  expect_identical(nrow(out), 0L)
  expect_named(out, names(source_metadata()))
})

test_that("read_sitemap_batch handles an empty source table", {
  empty_sources <- create_source_records(
    "https://example.com/sitemap.xml"
  )[0L, ]

  out <- read_sitemap_batch(
    empty_sources,
    user_agent = default_user_agent(),
    limits = fetch_limits(),
    index_limits = index_limits()
  )

  expect_identical(nrow(out$rows), 0L)
  expect_named(out$rows, names(empty_sitemap_rows()))
  expect_identical(nrow(out$sources), 0L)
  expect_identical(nrow(out$problems), 0L)
})

test_that("source failure problems classify decompression and fetch errors", {
  source <- create_source_records("https://example.com/sitemap.xml")
  gzip_error <- rlang::error_cnd(
    "sitemapr_decompression_error",
    message = "bad gzip"
  )
  fetch_error <- rlang::error_cnd(
    "sitemapr_timeout",
    message = "timed out"
  )

  decompression <- read_source_failure_problem(source, gzip_error)
  fetch <- read_source_failure_problem(source, fetch_error)

  expect_identical(decompression$category, "decompression")
  expect_identical(fetch$category, "fetch")
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

test_that("a gzip-wrapped tar fetched over the network is rejected", {
  # tar.gz is local-only (PRD §1): a fetched archive whose inner stream is tar
  # must abort as unsupported, never be parsed over the network.
  block <- raw(512L)
  block[258:262] <- charToRaw("ustar") # ustar magic at offset 257 (0-based)
  url <- "https://example.com/sitemap.tar.gz"
  httr2::local_mocked_responses(
    mock_by_url(
      setNames(list(gz_of_raw(block)), url),
      content_type = "application/octet-stream"
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
    "<sitemap><loc>",
    c1,
    "</loc></sitemap>",
    "<sitemap><loc>",
    c2,
    "</loc></sitemap>",
    "</sitemapindex>"
  )
  httr2::local_mocked_responses(mock_by_url(setNames(
    list(index_xml, urlset_xml("https://a/1"), urlset_xml("https://b/1")),
    c(index_url, c1, c2)
  )))

  res <- read_sitemap(index_url)
  expect_setequal(res$loc, c("https://a/1", "https://b/1"))
  expect_identical(
    res$source_sitemap[res$loc == "https://a/1"],
    c1
  )
  expect_identical(
    res$source_sitemap[res$loc == "https://b/1"],
    c2
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
    "<sitemap><loc>",
    c1,
    "</loc></sitemap>",
    "<sitemap><loc>",
    c2,
    "</loc></sitemap>",
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

test_that("an invalid input raises sitemapr_bad_input", {
  expect_error(read_sitemap(character(0)), class = "sitemapr_bad_input")
  expect_error(read_sitemap(NA_character_), class = "sitemapr_bad_input")
  expect_error(read_sitemap(""), class = "sitemapr_bad_input")
  expect_error(read_sitemap(42), class = "sitemapr_bad_input")
})

# ---- fetch body exposure -----------------------------------------------------

test_that("fetch_source attaches the raw body as an attribute", {
  url <- "https://example.com/sitemap.xml"
  body <- urlset_xml("https://a/1")
  httr2::local_mocked_responses(mock_by_url(setNames(list(body), url)))
  rec <- fetch_source(url)
  expect_identical(attr(rec, "body"), charToRaw(body))
})

# ---- request policy propagation ----------------------------------------------

# A spy policy recording every hop URL its prepare hook observes.
policy_spy <- function(sink) {
  request_policy(prepare = function(req, ctx) {
    sink$urls <- c(sink$urls, ctx$url)
    req
  })
}

test_that("read_sitemap threads the policy to the root and index children", {
  index_url <- "https://example.com/sitemap_index.xml"
  child <- "https://example.com/child.xml"
  index_xml <- paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<sitemap><loc>", child, "</loc></sitemap></sitemapindex>"
  )
  httr2::local_mocked_responses(mock_by_url(setNames(
    list(index_xml, urlset_xml("https://a/1")),
    c(index_url, child)
  )))

  sink <- new.env(parent = emptyenv())
  sink$urls <- character(0)
  read_sitemap(index_url, policy = policy_spy(sink))

  # The policy reached both the root index fetch and the recursive child fetch.
  expect_true(index_url %in% sink$urls)
  expect_true(child %in% sink$urls)
})

test_that("read_sitemap default call matches an explicit no-op policy", {
  url <- "https://example.com/sitemap.xml"
  httr2::local_mocked_responses(
    mock_by_url(setNames(list(urlset_xml("https://a/1", "https://a/2")), url))
  )
  default <- read_sitemap(url)
  explicit <- read_sitemap(url, policy = request_policy())
  expect_identical(default$loc, explicit$loc)
})
