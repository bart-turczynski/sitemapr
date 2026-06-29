# Unit tests for validate_sitemap() (Layer F entry point; SITE-ynxpeikq).
#
# Offline only: local fixtures for every branch, plus an in-memory text fixture
# for the over-long-line case. No real network is touched.

# The 10-column findings contract, in order.
contract_cols <- c(
  "code",
  "severity",
  "layer",
  "subject_type",
  "subject_ref",
  "message",
  "evidence",
  "mode",
  "is_strict_only",
  "remediation_hint"
)

fixture <- function(name) test_path("fixtures", name)

test_that("a valid urlset yields zero findings", {
  out <- validate_sitemap(fixture("valid-minimal.xml"))
  expect_s3_class(out, "tbl_df")
  expect_identical(names(out), contract_cols)
  expect_identical(nrow(out), 0L)
})

test_that("every branch returns the full 10-column contract", {
  out <- validate_sitemap(fixture("urlset-duplicate-loc.xml"))
  expect_identical(names(out), contract_cols)
})

test_that("a duplicate loc yields a PROTOCOL_DUPLICATE_LOC finding", {
  out <- validate_sitemap(fixture("urlset-duplicate-loc.xml"))
  expect_true("PROTOCOL_DUPLICATE_LOC" %in% out$code)
  row <- out[out$code == "PROTOCOL_DUPLICATE_LOC", ]
  expect_identical(row$layer, "protocol")
  expect_identical(row$severity, "warning")
})

test_that("a schema-invalid urlset is an error in strict mode", {
  out <- validate_sitemap(fixture("schema-invalid-urlset.xml"), mode = "strict")
  schema <- out[out$code == "SCHEMA_INVALID", ]
  expect_gt(nrow(schema), 0L)
  expect_true(all(schema$severity == "error"))
})

test_that("a schema-invalid urlset is downgraded to warning in non-strict", {
  out <- validate_sitemap(
    fixture("schema-invalid-urlset.xml"),
    mode = "non-strict"
  )
  schema <- out[out$code == "SCHEMA_INVALID", ]
  expect_gt(nrow(schema), 0L)
  expect_true(all(schema$severity == "warning"))
})

test_that("an unsupported root yields UNSUPPORTED_ROOT", {
  out <- validate_sitemap(fixture("unsupported-root.xml"))
  expect_true("UNSUPPORTED_ROOT" %in% out$code)
  row <- out[out$code == "UNSUPPORTED_ROOT", ]
  expect_identical(row$layer, "classification")
})

test_that("a long text-sitemap line yields PROTOCOL_TEXT_URL_TOO_LONG", {
  long_url <- paste0(
    "https://example.com/",
    paste(rep("a", 2100L), collapse = "")
  )
  path <- withr::local_tempfile(fileext = ".txt")
  writeLines(c("https://example.com/", long_url), path)

  out <- validate_sitemap(path)
  expect_true("PROTOCOL_TEXT_URL_TOO_LONG" %in% out$code)
})

test_that("a sitemapindex feed child yields UNSUPPORTED_FEED (offline)", {
  root <- "https://example.com/sitemap.xml"
  child <- "https://example.com/feed.xml"
  index_body <- paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n",
    "  <sitemap><loc>",
    child,
    "</loc></sitemap>\n",
    "</sitemapindex>\n"
  )
  rss_body <- paste0(
    "<?xml version=\"1.0\"?>\n",
    "<rss version=\"2.0\"><channel><title>Feed</title></channel></rss>\n"
  )
  map <- list()
  map[[root]] <- index_body
  map[[child]] <- rss_body

  httr2::local_mocked_responses(function(req) {
    body <- map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404, url = req$url))
    }
    httr2::response(
      status_code = 200,
      url = req$url,
      headers = list("Content-Type" = "application/xml; charset=UTF-8"),
      body = charToRaw(body)
    )
  })

  out <- validate_sitemap(root)
  expect_identical(names(out), contract_cols)
  expect_true("UNSUPPORTED_FEED" %in% out$code)
  row <- out[out$code == "UNSUPPORTED_FEED", ]
  expect_identical(nrow(row), 1L)
  expect_identical(row$layer, "classification")
  expect_identical(row$subject_type, "index-child")
})

test_that("validation is deterministic for a fixture and mode", {
  a <- validate_sitemap(fixture("urlset-duplicate-loc.xml"), mode = "strict")
  b <- validate_sitemap(fixture("urlset-duplicate-loc.xml"), mode = "strict")
  expect_identical(a, b)
})

# An httr2 mock dispatching on request URL via a named body map; unknown URLs
# 404. Mirrors the feed-child test's local helper, served as application/xml.
mock_by_url <- function(map) {
  function(req) {
    body <- map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/xml; charset=UTF-8"),
      body = charToRaw(body)
    )
  }
}

urlset_body <- function(...) {
  locs <- vapply(
    c(...),
    function(u) sprintf("<url><loc>%s</loc></url>", u),
    character(1)
  )
  paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
    paste(locs, collapse = ""),
    "</urlset>"
  )
}

index_body <- function(...) {
  locs <- vapply(
    c(...),
    function(u) sprintf("<sitemap><loc>%s</loc></sitemap>", u),
    character(1)
  )
  paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
    paste(locs, collapse = ""),
    "</sitemapindex>"
  )
}

test_that("a non-scalar / empty / NA `x` raises sitemapr_bad_input", {
  expect_error(validate_sitemap(character(0)), class = "sitemapr_bad_input")
  expect_error(validate_sitemap(NA_character_), class = "sitemapr_bad_input")
  expect_error(validate_sitemap(""), class = "sitemapr_bad_input")
  expect_error(validate_sitemap(c("a", "b")), class = "sitemapr_bad_input")
  expect_error(validate_sitemap(42), class = "sitemapr_bad_input")
})

test_that("a 404 source raises sitemapr_entrypoint_error, never a finding", {
  httr2::local_mocked_responses(function(req) {
    httr2::response(status_code = 404L, url = req$url)
  })
  suppressWarnings(
    expect_error(
      validate_sitemap("https://example.com/missing.xml"),
      class = "sitemapr_entrypoint_error"
    )
  )
})

test_that("an HTML masquerade source yields UNSUPPORTED_HTML_MASQUERADE", {
  out <- validate_sitemap(fixture("html-masquerade.html"))
  expect_identical(names(out), contract_cols)
  expect_true("UNSUPPORTED_HTML_MASQUERADE" %in% out$code)
  row <- out[out$code == "UNSUPPORTED_HTML_MASQUERADE", ]
  expect_identical(row$layer, "classification")
})

test_that("a gzip-compressed urlset is transparently decompressed", {
  # Real gzip-container bytes (1f 8b magic). memCompress(., "gzip") emits a raw
  # zlib stream the sniffer does not recognize, so gzfile() is used instead.
  tf <- withr::local_tempfile()
  con <- gzfile(tf, "wb")
  writeBin(charToRaw(urlset_body("https://example.com/page/1")), con)
  close(con)
  gz <- readBin(tf, what = "raw", n = file.info(tf)$size)
  httr2::local_mocked_responses(function(req) {
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/gzip"),
      body = gz
    )
  })
  out <- validate_sitemap("https://example.com/sitemap.xml.gz")
  expect_identical(names(out), contract_cols)
  expect_identical(nrow(out), 0L)
})

test_that("a local sitemapindex is schema-checked without expansion", {
  # A local file has no origin URL, so children are never fetched: the index
  # branch returns the schema part only (no INDEX_* or protocol findings).
  out <- validate_sitemap(fixture("valid-index.xml"))
  expect_identical(names(out), contract_cols)
  expect_false(any(startsWith(out$code, "INDEX_")))
})

test_that("an index cycle yields an INDEX_CYCLE_DETECTED error finding", {
  root <- "https://example.com/index-a.xml"
  b <- "https://example.com/index-b.xml"
  map <- list()
  map[[root]] <- index_body(b)
  map[[b]] <- index_body(root)

  httr2::local_mocked_responses(mock_by_url(map))
  out <- validate_sitemap(root)
  expect_identical(names(out), contract_cols)
  expect_true("INDEX_CYCLE_DETECTED" %in% out$code)
  row <- out[out$code == "INDEX_CYCLE_DETECTED", ]
  expect_identical(row$layer, "index-expansion")
  expect_identical(row$severity, "error")
  expect_identical(row$subject_type, "index-child")
})

test_that("a nested index warns SITEMAP_INDEX_NESTED and expands leaf rows", {
  root <- "https://example.com/index.xml"
  nested <- "https://example.com/nested-index.xml"
  leaf <- "https://example.com/leaf.xml"
  map <- list()
  map[[root]] <- index_body(nested)
  map[[nested]] <- index_body(leaf)
  # A leaf urlset with a duplicate loc so the protocol layer over the expanded
  # rows fires a recognizable finding (exercises the index protocol branch).
  map[[leaf]] <- urlset_body(
    "https://example.com/p1",
    "https://example.com/p1"
  )

  httr2::local_mocked_responses(mock_by_url(map))
  out <- validate_sitemap(root)
  expect_identical(names(out), contract_cols)

  nested_row <- out[out$code == "SITEMAP_INDEX_NESTED", ]
  expect_gt(nrow(nested_row), 0L)
  expect_true(all(nested_row$severity == "warning"))
  # The expanded leaf rows reached the protocol producer.
  expect_true("PROTOCOL_DUPLICATE_LOC" %in% out$code)
})

test_that("an over-deep index chain yields INDEX_DEPTH_EXCEEDED", {
  root <- "https://example.com/d0.xml"
  d1 <- "https://example.com/d1.xml"
  d2 <- "https://example.com/d2.xml"
  map <- list()
  map[[root]] <- index_body(d1)
  map[[d1]] <- index_body(d2)
  map[[d2]] <- urlset_body("https://example.com/p1")

  httr2::local_mocked_responses(mock_by_url(map))
  out <- validate_sitemap(
    root,
    index_limits = sitemapr:::index_limits(
      max_depth = 1L
    )
  )
  expect_identical(names(out), contract_cols)
  expect_true("INDEX_DEPTH_EXCEEDED" %in% out$code)
  expect_true(all(out$severity[out$code == "INDEX_DEPTH_EXCEEDED"] == "error"))
})

test_that("an over-wide index yields INDEX_CHILD_COUNT_EXCEEDED", {
  root <- "https://example.com/wide.xml"
  a <- "https://example.com/a.xml"
  b <- "https://example.com/b.xml"
  map <- list()
  map[[root]] <- index_body(a, b)
  map[[a]] <- urlset_body("https://example.com/p1")
  map[[b]] <- urlset_body("https://example.com/p2")

  httr2::local_mocked_responses(mock_by_url(map))
  out <- validate_sitemap(
    root,
    index_limits = sitemapr:::index_limits(
      max_children = 1L
    )
  )
  expect_identical(names(out), contract_cols)
  expect_true("INDEX_CHILD_COUNT_EXCEEDED" %in% out$code)
})

# --- Internal helper guards (empty/NULL inputs) ----------------------------
# These map/feed helpers are only reached with non-empty inputs by the public
# entry point, but each documents an empty-input contract (a zero-row tibble /
# an empty character vector). Exercise that guard directly.

test_that("index_findings_from_problems is an empty tibble for no problems", {
  base <- "sitemap://example.com/sitemap.xml"
  empty_probs <- tibble::tibble(
    category = character(0),
    message = character(0),
    subject_ref = character(0)
  )
  for (problems in list(NULL, empty_probs)) {
    out <- sitemapr:::index_findings_from_problems(problems, base)
    expect_s3_class(out, "tbl_df")
    expect_identical(nrow(out), 0L)
  }
})

test_that("index_feed_children is an empty character vector for no sources", {
  empty_sources <- tibble::tibble(
    format = character(0),
    final_url = character(0)
  )
  for (sources in list(NULL, empty_sources)) {
    out <- sitemapr:::index_feed_children(sources)
    expect_identical(out, character(0))
  }
})
