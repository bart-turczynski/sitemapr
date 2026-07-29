# Unit tests for transparent gzip decompression (R/decompress.R). Pure/offline:
# gzip streams are built in-memory or via a tempfile gzfile connection; no
# network.

# Build a real gzip stream (magic 1f 8b, as gzip(1) / a .gz file would) from a
# character payload.
gzip_stream <- function(text) {
  tf <- withr::local_tempfile(fileext = ".gz")
  con <- gzfile(tf, "wb")
  writeBin(charToRaw(text), con)
  close(con)
  readBin(tf, what = "raw", n = file.info(tf)$size)
}

test_that("a real gzip stream decompresses to the original bytes", {
  payload <- "https://example.com/a\nhttps://example.com/b\n"
  back <- gzip_decompress(gzip_stream(payload))
  expect_identical(back, charToRaw(payload))
})

test_that("the gzip stream carries the 1f 8b magic the sniffer keys on", {
  gz <- gzip_stream("x")
  expect_identical(sniff_format(gz), "gzip")
})

test_that("a gzipped XML sitemap parses identically to the uncompressed one", {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<url><loc>https://a/</loc></url>",
    "<url><loc>https://b/</loc></url>",
    "</urlset>"
  )
  from_plain <- parse_sitemap_xml(xml)$rows
  from_gz <- parse_sitemap_xml(gzip_decompress(gzip_stream(xml)))$rows
  expect_identical(from_gz, from_plain)
})

test_that("a gzipped text sitemap parses identically to the uncompressed one", {
  txt <- "https://a/\nhttps://b/\n"
  from_plain <- parse_sitemap_text(txt)
  from_gz <- parse_sitemap_text(gzip_decompress(gzip_stream(txt)))
  expect_identical(from_gz, from_plain)
})

test_that("a zlib stream (memCompress 'gzip') is also accepted", {
  payload <- charToRaw("plain zlib payload")
  zlib <- memCompress(payload, type = "gzip")
  expect_identical(gzip_decompress(zlib), payload)
})

test_that("a corrupt gzip stream raises a classed decompression error", {
  garbage <- as.raw(c(0x1F, 0x8B, 0x08, 0x00, 0x99, 0x42, 0x17))
  expect_error(
    gzip_decompress(garbage),
    class = "sitemapr_decompression_error"
  )
})

test_that("a truncated gzip stream raises a classed decompression error", {
  gz <- gzip_stream(strrep("https://example.com/p\n", 100))
  expect_error(
    gzip_decompress(head(gz, 12L)),
    class = "sitemapr_decompression_error"
  )
})

test_that("non-raw input is coerced before decompression", {
  gz <- gzip_stream("coerce me")
  expect_identical(
    gzip_decompress(as.integer(gz)),
    charToRaw("coerce me")
  )
})

# ---- inflated-size ceiling (decompression bomb) ------------------------------

# 64 MB of zeros compresses to a few hundred KB: a real expansion ratio,
# cheap to build, and small enough that the un-bounded path stays survivable
# if this ever regresses.
bomb_stream <- function(n = 64L * 1024L^2) {
  tf <- withr::local_tempfile(fileext = ".gz")
  con <- gzfile(tf, "wb")
  writeBin(raw(n), con)
  close(con)
  readBin(tf, what = "raw", n = file.info(tf)$size)
}

test_that("a stream inflating past the ceiling raises sitemapr_body_ceiling", {
  gz <- bomb_stream()
  expect_lt(length(gz), 1024L^2) # the point: tiny compressed, huge inflated
  expect_error(
    gzip_decompress(gz, max_bytes = 1024L^2),
    class = "sitemapr_body_ceiling"
  )
})

test_that("the ceiling condition carries the limit and the bytes counted", {
  cnd <- rlang::catch_cnd(gzip_decompress(bomb_stream(), max_bytes = 1024L^2))
  expect_identical(cnd$max_bytes, 1024^2)
  expect_gt(cnd$bytes_read, 1024^2)
  # Counted while streaming, so the abort fires near the ceiling rather than
  # after the whole 64 MB has been materialised.
  expect_lt(cnd$bytes_read, 2 * 1024^2)
})

test_that("a stream within the ceiling is returned unchanged", {
  payload <- strrep("https://example.com/p\n", 100L)
  expect_identical(
    gzip_decompress(gzip_stream(payload), max_bytes = 1024L^2),
    charToRaw(payload)
  )
})

test_that("the ceiling defaults to the sitemapr.max_decompressed option", {
  withr::local_options(sitemapr.max_decompressed = 1024L)
  expect_error(
    gzip_decompress(bomb_stream()),
    class = "sitemapr_body_ceiling"
  )
  withr::local_options(sitemapr.max_decompressed = 200 * 1024^2)
  expect_silent(gzip_decompress(gzip_stream("small")))
})

test_that("an over-ceiling zlib stream is caught after the fact", {
  # `gzcon()` passes a bare zlib stream through unchanged, so it cannot be
  # measured up front; the ceiling holds as a returned-size invariant instead.
  # No production path reaches this shape — every caller sniffs for 1f 8b.
  zlib <- memCompress(charToRaw(strrep("z", 4096L)), type = "gzip")
  expect_error(
    gzip_decompress(zlib, max_bytes = 1024L),
    class = "sitemapr_body_ceiling"
  )
  expect_length(gzip_decompress(zlib, max_bytes = 1024L^2), 4096L)
})

test_that("a corrupt stream raises a decompression error, not a ceiling", {
  # The guard cannot detect damage (gzcon returns short data silently), so the
  # corrupt-stream contract must survive the guard running first.
  garbage <- as.raw(c(0x1F, 0x8B, 0x08, 0x00, 0x99, 0x42, 0x17))
  expect_error(
    gzip_decompress(garbage, max_bytes = 1L),
    class = "sitemapr_decompression_error"
  )
})
