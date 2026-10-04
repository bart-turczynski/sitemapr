# Transparent gzip decompression (Layer C input; architecture.md §6, §9).
#
# Internal only. A single `.gz` source (an `.xml.gz` or `.txt.gz` sitemap) is
# decompressed back to its raw bytes before the format sniffer and the relevant
# parser run on the inner content — so a gzipped sitemap parses identically to
# its uncompressed equivalent. Pure and offline: it operates on already-fetched
# bytes, never touches the network, and signals failure as a classed condition
# (never a finding; architecture.md §3).
#
# A gzip-wrapped stream (magic `1f 8b`, as written by `gzip(1)` / `gzfile()`)
# is inflated by streaming it through `gzcon()`; see "STREAMED INFLATE" below.
# A bare zlib stream, which `gzcon()` passes through unchanged, goes to
# `memDecompress(type = "gzip")`, which despite the name accepts both shapes.
# A corrupt or truncated stream raises a sitemapr-classed decompression
# failure, so callers can distinguish it from a parse error.
#
# Inner `.gz` members of a `.tar.gz` archive reuse this same function (the
# archive slice, R/parse-archive.R, calls it per extracted member).
#
# DECOMPRESSION BOMB CEILING. `memDecompress()` inflates in one shot with no
# bound, so a small stream with a large expansion ratio would exhaust memory
# before any limit could be consulted (gzip tops out near 1032:1, and a 500 MB
# body — the fetch-layer ceiling, which bounds only the COMPRESSED bytes —
# therefore admits hundreds of GB inflated). `gzip_stream_inflate()` streams
# the stream through `gzcon()` in fixed-size chunks, aborting the moment the
# running total exceeds the ceiling, so a bomb is rejected after about one
# chunk past the ceiling rather than after it has been materialized.
#
# TRAILER CHECK. `gzcon()` silently returns short data for a corrupt or
# truncated stream (no error, no warning), so the streamed total is checked
# against the trailer: the stream holds at least a header and a trailer, and
# ISIZE equals the streamed total, mod 2^32. A failure raises the classed
# `sitemapr_decompression_error`. ISIZE describes the last member alone, so a
# multi-member or zero-padded stream is rejected, an accepted tradeoff for
# sitemaps, which are written as one member. (R < 4.4's `gzcon()` stops after
# the first member, so there two members of equal size and equal content still
# pass and inflate to the first one, as they always did.)
#
# STREAMED INFLATE. The streamed chunks are the result; the source stream never
# reaches `memDecompress()`. Handed one, `memDecompress()` loops on a deflate
# body that ends early: built without libdeflate (every R < 4.4) it doubles
# its buffer each time zlib reports Z_BUF_ERROR, which a truncated body reports
# forever, until the OOM killer stops R; with libdeflate (R >= 4.4) it retries
# without end when the body claims more than ISIZE bytes. The trailer check
# cannot rule that out: a stream crafted so the last eight bytes of a truncated
# body read as a matching trailer passes it (SITE-xeeginso).
#
# `gzcon()` checks the CRC32 trailer but only prints a mismatch to stderr, so
# the CRC is still checked by zlib: the chunks are rewrapped as stored deflate
# blocks under a fixed gzip header, followed by the source's 8-byte trailer,
# and that stream goes to `memDecompress()`. Its deflate body is complete by
# construction and its ISIZE has just been checked, so it cannot loop, and a
# CRC32 that does not match the streamed bytes makes it raise. The rewrap
# costs two copies of the inflated bytes at peak, both bounded by the ceiling.
#
# A stream crafted to forge the CRC32 too inflates to the bytes `gzcon()`
# streamed: no larger than the ceiling, and no different from what a
# valid gzip file of those bytes would give.

# Ceiling on inflated bytes, resolved from the argument then
# `getOption("sitemapr.max_decompressed")` then the default, mirroring the
# other bound constructors. 200 MB matches `archive_limits()` and leaves 4x
# headroom over the 50 MB sitemap-protocol size limit (which is a validation
# finding, not an abort).
default_max_decompressed <- function() {
  as.numeric(getOption("sitemapr.max_decompressed", 200 * 1024^2))
}

# Abort with the same condition the fetch-layer ceiling raises
# (`read_capped_body()`, R/fetch.R), so both over-size paths map to the one
# FETCH_BODY_CEILING_EXCEEDED finding code.
gzip_abort_ceiling <- function(max_bytes, bytes_read) {
  rlang::abort(
    sprintf(
      "Decompressed stream exceeded the %.0f-byte ceiling; discarded.",
      max_bytes
    ),
    class = "sitemapr_body_ceiling",
    max_bytes = max_bytes,
    bytes_read = bytes_read
  )
}

# A gzip member is at least a 10-byte header plus an 8-byte trailer (CRC32,
# then ISIZE), RFC 1952 section 2.3.
gzip_min_bytes <- 18L

# Abort for a stream the trailer check rejects, with the class and message
# style of the `memDecompress()` failure in gzip_mem_decompress().
gzip_abort_trailer <- function(detail, ...) {
  rlang::abort(
    paste("The gzip stream is corrupt or truncated:", detail),
    class = "sitemapr_decompression_error",
    ...
  )
}

# ISIZE, the last 4 bytes of a gzip stream: the inflated size mod 2^32, stored
# little-endian and unsigned. Computed in doubles from the raw bytes, so a
# value of 2^31 or more stays positive (readBin() would return it signed).
gzip_trailer_isize <- function(bytes) {
  n <- length(bytes)
  sum(as.integer(bytes[(n - 3L):n]) * 256^(0:3))
}

# A stored deflate block holds at most 65535 bytes (RFC 1951 section 3.2.4),
# so the stream is read in chunks of that size and each becomes one block.
stored_block_max <- 65535L

# One non-final stored deflate block around `chunk`: BFINAL = 0, BTYPE = 00,
# then LEN and its one's complement NLEN, little-endian.
deflate_stored_block <- function(chunk) {
  len <- length(chunk)
  nlen <- stored_block_max - len
  c(
    as.raw(c(0L, len %% 256L, len %/% 256L, nlen %% 256L, nlen %/% 256L)),
    chunk
  )
}

# A gzip header with no optional fields (RFC 1952 section 2.3): magic, CM 8
# (deflate), no flags, no mtime, no extra flags, OS 255 (unknown).
gzip_fixed_header <- as.raw(c(0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF))

# An empty final stored block, which ends the rewrapped deflate body.
deflate_final_empty_block <- as.raw(c(0x01, 0x00, 0x00, 0xFF, 0xFF))

# Inflate a gzip-wrapped stream by streaming it through `gzcon()`, aborting as
# soon as the running total exceeds `max_bytes`, check its trailer against that
# total, then have zlib check its CRC32 over the streamed bytes. Returns the
# inflated bytes, or NULL for a stream that is not gzip-wrapped.
#
# Only the gzip wrapper (magic 1f 8b) can be streamed: `gzcon()` passes a bare
# zlib stream through unchanged. Every call site reaches this function through
# a `sniff_format() == "gzip"` guard, which keys on that same magic, so the
# streamed shape is the only one reachable in practice; the bare-zlib shape is
# bounded after the fact by the caller instead.
gzip_stream_inflate <- function(bytes, max_bytes) {
  if (!sniff_starts_with(bytes, c(0x1F, 0x8B))) {
    return(NULL)
  }
  if (length(bytes) < gzip_min_bytes) {
    gzip_abort_trailer(
      sprintf(
        "%d bytes is shorter than a %d-byte gzip header and trailer.",
        length(bytes),
        gzip_min_bytes
      ),
      compressed_bytes = length(bytes)
    )
  }
  # A header gzcon() dislikes warns here; the trailer and CRC checks below
  # report the damage.
  con <- suppressWarnings(gzcon(rawConnection(bytes, "rb")))
  on.exit(close(con), add = TRUE)

  blocks <- list()
  total <- 0
  repeat {
    chunk <- suppressWarnings(tryCatch(
      readBin(con, what = "raw", n = stored_block_max),
      error = function(cnd) raw()
    ))
    if (length(chunk) == 0L) {
      break
    }
    total <- total + length(chunk)
    if (total > max_bytes) {
      gzip_abort_ceiling(max_bytes, total)
    }
    blocks[[length(blocks) + 1L]] <- deflate_stored_block(chunk)
  }

  isize <- gzip_trailer_isize(bytes)
  if (isize != total %% 2^32) {
    gzip_abort_trailer(
      sprintf(
        "its trailer records %.0f inflated bytes, but it inflates to %.0f.",
        isize,
        total
      ),
      isize = isize,
      inflated = total
    )
  }

  n <- length(bytes)
  rewrapped <- c(
    gzip_fixed_header,
    unlist(blocks, use.names = FALSE),
    deflate_final_empty_block,
    bytes[(n - 7L):n]
  )
  rm(blocks)
  gzip_mem_decompress(rewrapped)
}

# `memDecompress(type = "gzip")`, with a failure re-raised as the classed
# decompression error.
gzip_mem_decompress <- function(bytes) {
  tryCatch(
    memDecompress(bytes, type = "gzip"),
    error = function(cnd) {
      rlang::abort(
        paste(
          "The gzip stream is corrupt or truncated and could not be",
          "decompressed."
        ),
        class = "sitemapr_decompression_error",
        parent = cnd
      )
    }
  )
}

#' Decompress a single gzip stream to raw bytes
#'
#' Transparently inflates a gzip- (or zlib-) compressed sitemap stream so the
#' inner content can be sniffed and parsed. A corrupt or truncated stream raises
#' a `sitemapr_decompression_error` condition rather than returning garbage; a
#' stream that would inflate past `max_bytes` raises `sitemapr_body_ceiling`
#' and is never returned.
#'
#' @param bytes Raw vector (or coercible to raw) of the compressed stream.
#' @param max_bytes Ceiling on the inflated size in bytes. Default
#'   `getOption("sitemapr.max_decompressed", 200 * 1024^2)`.
#' @return A raw vector of the decompressed bytes.
#' @keywords internal
#' @noRd
gzip_decompress <- function(bytes, max_bytes = default_max_decompressed()) {
  if (!is.raw(bytes)) {
    bytes <- as.raw(bytes)
  }
  max_bytes <- as.numeric(max_bytes)
  out <- gzip_stream_inflate(bytes, max_bytes)
  if (!is.null(out)) {
    return(out)
  }

  # A bare zlib stream could not be streamed, so hold the ceiling as a
  # returned-size invariant instead: the memory is already spent, but an
  # over-ceiling body is still never handed back.
  out <- gzip_mem_decompress(bytes)
  if (length(out) > max_bytes) {
    gzip_abort_ceiling(max_bytes, length(out))
  }
  out
}
