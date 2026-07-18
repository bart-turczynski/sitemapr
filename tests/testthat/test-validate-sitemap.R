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
  expect_named(out, contract_cols)
  expect_identical(nrow(out), 0L)
})

test_that("every branch returns the full 10-column contract", {
  out <- validate_sitemap(fixture("urlset-duplicate-loc.xml"))
  expect_named(out, contract_cols)
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
    strrep("a", 2100L)
  )
  path <- withr::local_tempfile(fileext = ".txt")
  writeLines(c("https://example.com/", long_url), path)

  out <- validate_sitemap(path)
  expect_true("PROTOCOL_TEXT_URL_TOO_LONG" %in% out$code)
})

# Serve an index whose single child <loc> is fetched offline and its body
# supplied by the test; returns the mock function.
vs_feed_index_mock <- function(
  child_body,
  child = "https://example.com/feed.xml"
) {
  root <- "https://example.com/sitemap.xml"
  index_body <- paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n",
    "  <sitemap><loc>",
    child,
    "</loc></sitemap>\n",
    "</sitemapindex>\n"
  )
  map <- list()
  map[[root]] <- index_body
  map[[child]] <- child_body
  function(req) {
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
  }
}

test_that("a sitemapindex RSS 2.0 child parses into rows (offline)", {
  # A supported feed dialect is no longer UNSUPPORTED_FEED: it parses into rows
  # that reach the protocol layer. The item's non-absolute link surfaces a
  # PROTOCOL_URL_NOT_ABSOLUTE finding attributed to the feed child, proving the
  # rows flowed through.
  rss_body <- paste0(
    "<?xml version=\"1.0\"?>\n",
    "<rss version=\"2.0\"><channel><title>Feed</title>",
    "<item><link>not-an-absolute-url</link></item>",
    "</channel></rss>\n"
  )
  httr2::local_mocked_responses(vs_feed_index_mock(rss_body))

  out <- validate_sitemap("https://example.com/sitemap.xml")
  expect_named(out, contract_cols)
  expect_false("UNSUPPORTED_FEED" %in% out$code)
  expect_true("PROTOCOL_URL_NOT_ABSOLUTE" %in% out$code)
})

test_that("a sitemapindex unsupported feed child yields UNSUPPORTED_FEED", {
  # A <feed> in a non-Atom namespace sniffs as "feed" but parse_feed() rejects
  # it: this is the only path that still emits UNSUPPORTED_FEED.
  bad_feed <- paste0(
    "<feed xmlns=\"http://example.com/not-atom\">",
    "<entry><link href=\"https://example.com/x\"/></entry></feed>"
  )
  httr2::local_mocked_responses(vs_feed_index_mock(bad_feed))

  out <- validate_sitemap("https://example.com/sitemap.xml")
  expect_named(out, contract_cols)
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

test_that("a submitted-list validation combines deduplicated source findings", {
  out <- validate_sitemaps(c(
    fixture("urlset-duplicate-loc.xml"),
    fixture("priority-out-of-range.xml"),
    fixture("urlset-duplicate-loc.xml")
  ))

  expect_named(out, contract_cols)
  expect_true("PROTOCOL_DUPLICATE_LOC" %in% out$code)
  expect_true("PROTOCOL_PRIORITY_OUT_OF_RANGE" %in% out$code)
  duplicate_rows <- out[out$code == "PROTOCOL_DUPLICATE_LOC", ]
  expect_identical(nrow(duplicate_rows), 1L)
})

test_that("a submitted-list validation records source failures as findings", {
  missing <- file.path(tempdir(), "sitemapr-missing-submitted-list.xml")
  if (file.exists(missing)) {
    unlink(missing)
  }

  out <- validate_sitemap(c(fixture("valid-minimal.xml"), missing))

  expect_named(out, contract_cols)
  expect_identical(out$code, "FETCH_FAILED")
  expect_identical(out$layer, "fetch")
  expect_match(out$subject_ref, "sitemapr-missing-submitted-list.xml")
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

test_that("an invalid `x` raises sitemapr_bad_input", {
  expect_error(validate_sitemap(character(0)), class = "sitemapr_bad_input")
  expect_error(validate_sitemap(NA_character_), class = "sitemapr_bad_input")
  expect_error(validate_sitemap(""), class = "sitemapr_bad_input")
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
  expect_named(out, contract_cols)
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
  expect_named(out, contract_cols)
  expect_identical(nrow(out), 0L)
})

test_that("a local sitemapindex is schema-checked without expansion", {
  # A local file has no origin URL, so children are never fetched: the index
  # branch returns the schema part only (no INDEX_* or protocol findings).
  out <- validate_sitemap(fixture("valid-index.xml"))
  expect_named(out, contract_cols)
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
  expect_named(out, contract_cols)
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
  expect_named(out, contract_cols)

  nested_row <- out[out$code == "SITEMAP_INDEX_NESTED", ]
  expect_gt(nrow(nested_row), 0L)
  expect_true(all(nested_row$severity == "warning"))
  # The expanded leaf rows reached the protocol producer.
  expect_true("PROTOCOL_DUPLICATE_LOC" %in% out$code)
})

test_that("expanded index leaf rows are scoped to their source sitemap", {
  root <- "https://example.com/sitemap/sitemap.xml"
  leaf <- "https://example.com/sitemap.xml"
  map <- list()
  map[[root]] <- index_body(leaf)
  map[[leaf]] <- urlset_body("https://example.com/page")

  httr2::local_mocked_responses(mock_by_url(map))
  out <- validate_sitemap(root)

  expect_named(out, contract_cols)
  expect_false("PROTOCOL_URL_OUT_OF_SCOPE" %in% out$code)
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
    index_limits = sitemapr_test_call(
      "index_limits",
      max_depth = 1L
    )
  )
  expect_named(out, contract_cols)
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
    index_limits = sitemapr_test_call(
      "index_limits",
      max_children = 1L
    )
  )
  expect_named(out, contract_cols)
  expect_true("INDEX_CHILD_COUNT_EXCEEDED" %in% out$code)
})

test_that("an over-budget sitemap total yields INDEX_TOTAL_SITEMAPS_EXCEEDED", {
  root <- "https://example.com/root.xml"
  a <- "https://example.com/a.xml"
  b <- "https://example.com/b.xml"
  map <- list()
  map[[root]] <- index_body(a, b)
  map[[a]] <- urlset_body("https://example.com/p1")
  map[[b]] <- urlset_body("https://example.com/p2")

  httr2::local_mocked_responses(mock_by_url(map))
  out <- validate_sitemap(
    root,
    index_limits = sitemapr_test_call(
      "index_limits",
      max_total_sitemaps = 1
    )
  )
  expect_named(out, contract_cols)
  expect_true("INDEX_TOTAL_SITEMAPS_EXCEEDED" %in% out$code)
  row <- out[out$code == "INDEX_TOTAL_SITEMAPS_EXCEEDED", ]
  expect_identical(row$layer, "index-expansion")
  expect_true(all(row$severity == "error"))
})

test_that("an over-budget URL total yields INDEX_TOTAL_URLS_EXCEEDED", {
  root <- "https://example.com/root.xml"
  a <- "https://example.com/a.xml"
  b <- "https://example.com/b.xml"
  map <- list()
  map[[root]] <- index_body(a, b)
  map[[a]] <- urlset_body("https://example.com/p1")
  map[[b]] <- urlset_body("https://example.com/p2")

  httr2::local_mocked_responses(mock_by_url(map))
  out <- validate_sitemap(
    root,
    index_limits = sitemapr_test_call(
      "index_limits",
      max_total_urls = 1
    )
  )
  expect_named(out, contract_cols)
  expect_true("INDEX_TOTAL_URLS_EXCEEDED" %in% out$code)
  row <- out[out$code == "INDEX_TOTAL_URLS_EXCEEDED", ]
  expect_identical(row$layer, "index-expansion")
  expect_true(all(row$severity == "error"))
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
    out <- sitemapr_test_call("index_findings_from_problems", problems, base)
    expect_s3_class(out, "tbl_df")
    expect_identical(nrow(out), 0L)
  }
})

test_that("index_feed_children is an empty character vector for no problems", {
  empty_problems <- tibble::tibble(
    category = character(0),
    subject_ref = character(0)
  )
  for (problems in list(NULL, empty_problems)) {
    out <- sitemapr_test_call("index_feed_children", problems)
    expect_identical(out, character(0))
  }
})

test_that("index_feed_children returns only feed-category problem subjects", {
  problems <- tibble::tibble(
    category = c("fetch", "feed", "index-expansion"),
    subject_ref = c(
      "https://example.com/a.xml",
      "https://example.com/feed.xml",
      "https://example.com/b.xml"
    )
  )
  out <- sitemapr_test_call("index_feed_children", problems)
  expect_identical(out, "https://example.com/feed.xml")
})

test_that("validation_target handles a raw character target", {
  out <- sitemapr_test_ns$validation_target(fixture("valid-minimal.xml"))

  expect_identical(out$target, fixture("valid-minimal.xml"))
  expect_true(out$is_local)
  expect_identical(out$source, fixture("valid-minimal.xml"))
})

test_that("archive gzip errors are mapped inside archive validation", {
  src <- list(
    path = fixture("valid-minimal.xml"),
    base = "sitemap://archive.tar.gz",
    final_url = NA_character_,
    byte_size = 10,
    fetched_at = NA
  )
  testthat::local_mocked_bindings(
    parse_sitemap_archive = function(...) {
      rlang::abort("bad gzip", class = "sitemapr_decompression_error")
    }
  )

  parts <- sitemapr_test_ns$validate_archive_parts(src)

  expect_length(parts, 1L)
  expect_identical(parts[[1L]]$code, "UNSUPPORTED_MALFORMED_GZIP")
  expect_identical(parts[[1L]]$layer, "decompression")
})

test_that("archive byte limits re-propagate instead of mapping to findings", {
  cnd <- structure(
    list(message = "archive byte limit", call = NULL, limit = "byte_count"),
    class = c("sitemapr_archive_limit", "error", "condition")
  )
  src <- list(base = "sitemap://archive.tar.gz")

  expect_error(
    sitemapr_test_ns$archive_limit_part(cnd, src),
    class = "sitemapr_archive_limit"
  )
})

test_that("batched validation source failures classify timeout and body cap", {
  source <- sitemapr_test_ns$create_source_records(
    "https://ex.com/sitemap.xml",
    as = "sitemap"
  )
  timeout <- structure(
    list(message = "timed out", call = NULL),
    class = c("sitemapr_timeout", "error", "condition")
  )
  body_cap <- structure(
    list(message = "too large", call = NULL),
    class = c("sitemapr_body_ceiling", "error", "condition")
  )

  expect_identical(
    sitemapr_test_ns$validate_failure_finding(source, timeout)$code,
    "FETCH_TIMEOUT"
  )
  expect_identical(
    sitemapr_test_ns$validate_failure_finding(source, body_cap)$code,
    "FETCH_BODY_CEILING_EXCEEDED"
  )
})

test_that("combining empty findings returns the empty contract", {
  out <- sitemapr_test_ns$combine_findings_contracts(list(
    sitemapr_test_ns$empty_findings_contract()
  ))

  expect_named(out, contract_cols)
  expect_identical(nrow(out), 0L)
})

# --- Decompression-layer findings (SITE-vtbolmya) --------------------------
# validate_sitemap() promotes the decompression conditions that the parse API
# raises (gzip_decompress() / parse_sitemap_archive()) into findings. A minimal
# in-memory ustar writer builds .tar.gz fixtures so member names / bodies are
# controlled exactly (including a truncated tar the real tar() would not emit).

test_that("decompression member findings scope archive members by fragment", {
  out <- sitemapr_test_call(
    "decompression_member_finding",
    code = "DECOMPRESS_NOT_SITEMAP",
    base = "sitemap://archive.tar.gz",
    message = "Skipped archive member.",
    member_path = "README.md"
  )

  expect_identical(out$subject_type, "archive-member")
  expect_identical(
    out$subject_ref,
    "sitemap://archive.tar.gz#archive-member:README.md"
  )
  expect_identical(out$evidence[[1L]]$excerpt, "README.md")
})

test_that("warning archive problems are not decompression findings", {
  problems <- sitemapr_test_ns$parse_problems(
    severity = "warning",
    category = "archive",
    subject_ref = "sitemap://archive.tar.gz#archive-member:../evil.xml",
    message = "Skipped unsafe archive member."
  )

  out <- sitemapr_test_call("decompression_findings_from_problems", problems)

  expect_s3_class(out, "tbl_df")
  expect_identical(nrow(out), 0L)
})

vs_tar_header <- function(name, size, typeflag = "0") {
  h <- raw(512L)
  put <- function(h, off, s) {
    b <- charToRaw(s)
    h[(off + 1L):(off + length(b))] <- b
    h
  }
  h <- put(h, 0L, name)
  h <- put(h, 124L, sprintf("%011o", size))
  h <- put(h, 148L, "        ")
  h <- put(h, 156L, typeflag)
  h <- put(h, 257L, "ustar")
  put(h, 263L, "00")
}

vs_pad_block <- function(x) {
  r <- length(x) %% 512L
  if (r == 0L) x else c(x, raw(512L - r))
}

vs_urlset <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    "</urlset>"
  )
}

# entries: list(list(name=, content=<chr>)) -> gzipped ustar tempfile path.
vs_write_tar_gz <- function(entries) {
  path <- withr::local_tempfile(
    fileext = ".tar.gz",
    .local_envir = parent.frame()
  )
  blocks <- raw(0L)
  for (e in entries) {
    body <- charToRaw(e$content)
    blocks <- c(blocks, vs_tar_header(e$name, length(body)), vs_pad_block(body))
  }
  blocks <- c(blocks, raw(1024L))
  con <- gzfile(path, "wb")
  writeBin(blocks, con)
  close(con)
  path
}

test_that("a corrupt gzip source yields UNSUPPORTED_MALFORMED_GZIP", {
  path <- withr::local_tempfile(fileext = ".xml.gz")
  # 1f 8b magic (sniffs as gzip) followed by garbage that fails to inflate.
  writeBin(as.raw(c(0x1F, 0x8B, 0x08, 0x00, 0x99, 0x42, 0x17)), path)

  out <- validate_sitemap(path)
  expect_named(out, contract_cols)
  row <- out[out$code == "UNSUPPORTED_MALFORMED_GZIP", ]
  expect_identical(nrow(row), 1L)
  expect_identical(row$layer, "decompression")
  expect_identical(row$subject_type, "source")
  expect_identical(row$severity, "error")
})

test_that("a truncated tar archive yields UNSUPPORTED_MALFORMED_ARCHIVE", {
  # A header claiming a 5000-byte body, but no body bytes follow, gzipped.
  bad_tar <- c(vs_tar_header("big.xml", 5000L), raw(512L))
  path <- withr::local_tempfile(fileext = ".tar.gz")
  con <- gzfile(path, "wb")
  writeBin(bad_tar, con)
  close(con)

  out <- validate_sitemap(path)
  expect_named(out, contract_cols)
  row <- out[out$code == "UNSUPPORTED_MALFORMED_ARCHIVE", ]
  expect_identical(nrow(row), 1L)
  expect_identical(row$layer, "decompression")
  expect_identical(row$subject_type, "archive-member")
  expect_identical(row$severity, "error")
})

test_that("exceeding the archive file cap yields DECOMPRESS_TOO_MANY_FILES", {
  withr::local_options(sitemapr.archive.max_files = 2L)
  path <- vs_write_tar_gz(list(
    list(name = "a.xml", content = vs_urlset("https://a/1")),
    list(name = "b.xml", content = vs_urlset("https://b/1")),
    list(name = "c.xml", content = vs_urlset("https://c/1"))
  ))

  out <- validate_sitemap(path)
  expect_named(out, contract_cols)
  row <- out[out$code == "DECOMPRESS_TOO_MANY_FILES", ]
  expect_identical(nrow(row), 1L)
  expect_identical(row$layer, "decompression")
  expect_identical(row$subject_type, "source")
  expect_identical(row$severity, "error")
})

test_that("a non-sitemap archive member yields DECOMPRESS_NOT_SITEMAP", {
  path <- vs_write_tar_gz(list(
    list(name = "sitemap.xml", content = vs_urlset("https://a/1")),
    list(name = "README.md", content = "# hello\nsome prose\n")
  ))

  out <- validate_sitemap(path)
  expect_named(out, contract_cols)
  row <- out[out$code == "DECOMPRESS_NOT_SITEMAP", ]
  expect_identical(nrow(row), 1L)
  expect_identical(row$layer, "decompression")
  expect_identical(row$subject_type, "archive-member")
  expect_identical(row$severity, "info")
  expect_match(row$subject_ref, "#archive-member:README.md", fixed = TRUE)
})

test_that("a clean archive yields no decompression findings", {
  path <- vs_write_tar_gz(list(
    list(name = "a.xml", content = vs_urlset("https://a/1", "https://a/2")),
    list(name = "b.xml", content = vs_urlset("https://b/1"))
  ))

  out <- validate_sitemap(path)
  expect_named(out, contract_cols)
  expect_false(any(out$layer == "decompression"))
})

# ---- request policy propagation ----------------------------------------------

test_that("validate_sitemap threads the policy to root and index children", {
  root <- "https://example.com/sitemap_index.xml"
  child <- "https://example.com/child.xml"
  httr2::local_mocked_responses(mock_by_url(list(
    "https://example.com/sitemap_index.xml" = index_body(child),
    "https://example.com/child.xml" = urlset_body("https://example.com/1")
  )))

  sink <- new.env(parent = emptyenv())
  sink$urls <- character(0)
  policy <- request_policy(prepare = function(req, ctx) {
    sink$urls <- c(sink$urls, ctx$url)
    req
  })
  validate_sitemap(root, policy = policy)

  expect_true(root %in% sink$urls)
  expect_true(child %in% sink$urls)
})

# ---- engine-aware entry point (ADR-009 §5/§6) --------------------------------

# The four additive schema-v2 columns, in order, appended after contract_cols.
ruleset_additive_cols <- c(
  "ruleset",
  "ruleset_revision",
  "context",
  "provenance"
)

test_that("the baseline ruleset returns the exact 10-column schema v1", {
  out <- validate_sitemap_ruleset(
    fixture("urlset-duplicate-loc.xml"),
    "sitemaps.org"
  )
  expect_named(out, contract_cols)
})

test_that("the baseline ruleset matches validate_sitemap() byte-for-byte", {
  base <- validate_sitemap(fixture("urlset-duplicate-loc.xml"))
  ruleset <- validate_sitemap_ruleset(
    fixture("urlset-duplicate-loc.xml"),
    "sitemaps.org"
  )
  expect_identical(ruleset, base)
})

test_that("an engine ruleset appends the four additive columns", {
  out <- validate_sitemap_ruleset(
    fixture("urlset-duplicate-loc.xml"),
    "google"
  )
  expect_named(out, c(contract_cols, ruleset_additive_cols))
  expect_gt(nrow(out), 0L)
  expect_true(all(out$ruleset == "google"))
  expect_true(all(out$ruleset_revision == ruleset_revision("google")))
  expect_true(all(out$provenance == "inherited_protocol"))
})

test_that("the additive context column is a named-list list-column", {
  out <- validate_sitemap_ruleset(
    fixture("urlset-duplicate-loc.xml"),
    "google",
    context = ruleset_context(submission_channel = "search_console_api")
  )
  expect_type(out$context, "list")
  ctx <- out$context[[1L]]
  expect_named(
    ctx,
    c(
      "submission_channel",
      "discovery_provenance",
      "property_scope",
      "authority_evidence"
    )
  )
  expect_identical(ctx$submission_channel, "search_console_api")
})

test_that("an engine ruleset with no findings keeps the 14-column schema", {
  out <- validate_sitemap_ruleset(fixture("valid-minimal.xml"), "bing")
  expect_named(out, c(contract_cols, ruleset_additive_cols))
  expect_identical(nrow(out), 0L)
})

test_that("validation is deterministic on the engine path", {
  a <- validate_sitemap_ruleset(fixture("urlset-duplicate-loc.xml"), "yandex")
  b <- validate_sitemap_ruleset(fixture("urlset-duplicate-loc.xml"), "yandex")
  expect_identical(a, b)
})

test_that("the batch ruleset wrapper stamps the additive columns", {
  out <- validate_sitemaps_ruleset(
    c(
      fixture("urlset-duplicate-loc.xml"),
      fixture("priority-out-of-range.xml")
    ),
    "google"
  )
  expect_named(out, c(contract_cols, ruleset_additive_cols))
  expect_true(all(out$ruleset == "google"))
  expect_true("PROTOCOL_DUPLICATE_LOC" %in% out$code)
  expect_true("PROTOCOL_PRIORITY_OUT_OF_RANGE" %in% out$code)
})
