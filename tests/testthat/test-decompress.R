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
  gz <- gzip_stream(paste(rep("https://example.com/p\n", 100), collapse = ""))
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
