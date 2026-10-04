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

# ---- crafted streams (SITE-xeeginso) -----------------------------------------

# Evaluate `expr` in a forked child and give up after `seconds`. A regression
# here hangs R (>= 4.4) or exhausts its memory (< 4.4) inside C code that
# setTimeLimit() cannot interrupt, so only a separate process gives the test a
# real wall-clock bound and keeps such a failure from killing the whole suite.
in_child_within <- function(expr, seconds = 10) {
  skip_on_os("windows") # no fork()
  job <- parallel::mcparallel(expr, silent = TRUE)
  res <- parallel::mccollect(job, wait = FALSE, timeout = seconds)
  if (is.null(res)) {
    tools::pskill(job$pid, tools::SIGKILL)
    parallel::mccollect(job, wait = FALSE)
    stop(sprintf("Still running after %d seconds; killed.", seconds))
  }
  if (is.null(res[[1]])) {
    stop("The child process died without a result.")
  }
  res[[1]]
}

# A gzip header, then a non-final stored block that claims 100 bytes but is cut
# after 20, whose last 4 bytes spell 20. gzcon() streams those 20 bytes and
# ISIZE reads 20, so the trailer check passes; memDecompress() handed this
# stream loops until the OOM killer stops R (< 4.4) or forever (>= 4.4).
crafted_stream <- function() {
  c(
    as.raw(c(0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0x03)),
    as.raw(c(0x00, 100, 0, 0x9B, 0xFF)),
    charToRaw(strrep("A", 16L)),
    as.raw(c(20, 0, 0, 0))
  )
}

test_that("a self-consistent truncated stream fails without hanging", {
  crafted <- crafted_stream()
  expect_length(crafted, 35L)
  cnd <- in_child_within(rlang::catch_cnd(gzip_decompress(crafted)))
  expect_s3_class(cnd, "sitemapr_decompression_error")
})

test_that("a stream whose CRC32 was altered raises a decompression error", {
  # gzcon() only prints a CRC mismatch to stderr; the check that raises is
  # zlib's, run over the rebuilt stream that carries the source trailer.
  payload <- strrep("https://example.com/p\n", 100)
  gz <- gzip_stream(payload)
  n <- length(gz)
  gz[n - 7L] <- as.raw(bitwXor(as.integer(gz[n - 7L]), 1L))
  utils::capture.output(
    cnd <- rlang::catch_cnd(gzip_decompress(gz)),
    type = "message"
  )
  expect_s3_class(cnd, "sitemapr_decompression_error")
  expect_false(is.null(cnd$parent))
})

test_that("a stream spanning many stored blocks decompresses identically", {
  # More than one 65535-byte block, and a length that is not a multiple of it.
  payload <- strrep("https://example.com/some/path\n", 10000L)
  expect_gt(nchar(payload), 3 * 65535)
  expect_identical(gzip_decompress(gzip_stream(payload)), charToRaw(payload))
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
  # after the whole 64 MB has been materialized.
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

# ---- trailer check (truncated or mismatched gzip) ---------------------------

# Before `memDecompress()` sees a gzip-wrapped stream, the guard checks its
# trailer: at least 18 bytes (10-byte header, 8-byte CRC32 + ISIZE trailer),
# and ISIZE (the last 4 bytes, little-endian, unsigned) equal to the count the
# guard streamed, mod 2^32. A failure raises `sitemapr_decompression_error`
# from the guard itself, so the condition carries the trailer fields and no
# parent: `memDecompress()` never ran. On R < 4.4 (no libdeflate) a truncated
# stream makes `memDecompress()` double its buffer until the OOM killer stops
# R, so the trailer check is the only thing between such a stream and a crash.

# Overwrite a gzip stream's ISIZE (its last 4 bytes) with `value`.
set_isize <- function(gz, value) {
  n <- length(gz)
  gz[(n - 3L):n] <- as.raw(floor(value / 256^(0:3)) %% 256)
  gz
}

test_that("a stream shorter than header plus trailer fails before inflating", {
  gz <- gzip_stream(strrep("https://example.com/p\n", 100))
  cnd <- rlang::catch_cnd(gzip_decompress(head(gz, 12L)))
  expect_s3_class(cnd, "sitemapr_decompression_error")
  expect_null(cnd$parent)
  expect_identical(cnd$compressed_bytes, 12L)
})

test_that("a stream cut inside the deflate body fails before inflating", {
  payload <- strrep("https://example.com/p\n", 100)
  gz <- gzip_stream(payload)
  cut <- head(gz, length(gz) %/% 2L)
  expect_gte(length(cut), 18L)
  cnd <- rlang::catch_cnd(gzip_decompress(cut))
  expect_s3_class(cnd, "sitemapr_decompression_error")
  expect_null(cnd$parent)
  expect_lt(cnd$inflated, nchar(payload))
  expect_false(identical(cnd$isize, cnd$inflated))
})

test_that("a stream whose ISIZE was altered fails before inflating", {
  payload <- strrep("https://example.com/p\n", 100)
  gz <- set_isize(gzip_stream(payload), nchar(payload) + 1)
  cnd <- rlang::catch_cnd(gzip_decompress(gz))
  expect_s3_class(cnd, "sitemapr_decompression_error")
  expect_null(cnd$parent)
  expect_identical(cnd$isize, nchar(payload) + 1)
  expect_identical(cnd$inflated, as.numeric(nchar(payload)))
})

test_that("a valid stream still decompresses identically", {
  payload <- strrep("https://example.com/p\n", 1000L)
  expect_identical(gzip_decompress(gzip_stream(payload)), charToRaw(payload))
  # An empty payload has ISIZE 0 and inflates to nothing.
  expect_identical(gzip_decompress(gzip_stream("")), raw())
})

test_that("a multi-member gzip stream now errors (accepted tradeoff)", {
  # RFC 1952 allows concatenated members and gzip(1) inflates them all, but
  # ISIZE describes only the last member, so the trailer check cannot vouch
  # for the whole stream and rejects it; sitemaps are written as one member.
  # The members differ in size on purpose: R < 4.4's gzcon() stops after the
  # first member, so two equal-size members would match the last ISIZE there
  # and inflate to the first member alone, as they did before the check.
  two <- c(gzip_stream("aaa\n"), gzip_stream("bbbbbb\n"))
  cnd <- rlang::catch_cnd(gzip_decompress(two))
  expect_s3_class(cnd, "sitemapr_decompression_error")
  expect_null(cnd$parent)
})

# The cases below hang `memDecompress()` on R >= 4.4 without the check: its
# libdeflate path allocates ISIZE bytes, and when that is too small it retries
# with the same ISIZE forever. Kept apart from the pins above for that reason.

test_that("a stream whose ISIZE was lowered fails before inflating", {
  payload <- strrep("https://example.com/p\n", 100)
  gz <- set_isize(gzip_stream(payload), nchar(payload) - 1)
  cnd <- rlang::catch_cnd(gzip_decompress(gz))
  expect_s3_class(cnd, "sitemapr_decompression_error")
  expect_null(cnd$parent)
  expect_identical(cnd$isize, nchar(payload) - 1)
})

test_that("a zero-padded gzip stream now errors (accepted tradeoff)", {
  # Trailing zeros, as some writers pad to a block size, push the real trailer
  # away from the end, so the last 4 bytes read as ISIZE 0.
  gz <- c(gzip_stream("https://example.com/\n"), raw(8L))
  cnd <- rlang::catch_cnd(gzip_decompress(gz))
  expect_s3_class(cnd, "sitemapr_decompression_error")
  expect_null(cnd$parent)
  expect_identical(cnd$isize, 0)
})

test_that("ISIZE is read unsigned, so a high bit stays a large count", {
  payload <- "https://example.com/\n"
  gz <- set_isize(gzip_stream(payload), 2^31 + nchar(payload))
  cnd <- rlang::catch_cnd(gzip_decompress(gz))
  expect_s3_class(cnd, "sitemapr_decompression_error")
  expect_identical(cnd$isize, 2^31 + nchar(payload))
})
