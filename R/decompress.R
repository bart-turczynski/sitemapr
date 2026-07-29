# Transparent gzip decompression (Layer C input; architecture.md §6, §9).
#
# Internal only. A single `.gz` source (an `.xml.gz` or `.txt.gz` sitemap) is
# decompressed back to its raw bytes before the format sniffer and the relevant
# parser run on the inner content — so a gzipped sitemap parses identically to
# its uncompressed equivalent. Pure and offline: it operates on already-fetched
# bytes, never touches the network, and signals failure as a classed condition
# (never a finding; architecture.md §3).
#
# `memDecompress(type = "gzip")` reads the whole stream from memory in one shot.
# Despite the name it accepts both the gzip wrapper (magic `1f 8b`, as written
# by `gzip(1)` / `gzfile()`) and a bare zlib stream, which covers every `.gz`
# sitemap we sniff. A corrupt or truncated stream makes it raise; we re-raise
# that as a sitemapr-classed decompression failure so callers can distinguish it
# from a parse error.
#
# Inner `.gz` members of a `.tar.gz` archive reuse this same function (the
# archive slice, R/parse-archive.R, calls it per extracted member).
#
# DECOMPRESSION BOMB CEILING. `memDecompress()` inflates in one shot with no
# bound, so a small stream with a large expansion ratio would exhaust memory
# before any limit could be consulted (gzip tops out near 1032:1, and a 500 MB
# body — the fetch-layer ceiling, which bounds only the COMPRESSED bytes —
# therefore admits hundreds of GB inflated). `gzip_size_guard()` measures the
# inflated size FIRST by streaming the stream through `gzcon()` in fixed-size
# chunks that are counted and discarded, aborting the moment the running total
# exceeds the ceiling. Peak memory for the guard is one chunk, so a bomb is
# rejected without ever being materialised.
#
# The guard measures; `memDecompress()` still produces the result. That split is
# deliberate: `gzcon()` silently returns short data for a corrupt or truncated
# stream (no error, no warning), so it cannot be trusted to detect damage, while
# `memDecompress()` raises on exactly those inputs. Running the guard first
# keeps the corrupt-stream contract below unchanged and costs one extra inflate
# of an already-bounded stream (measured at par with `memDecompress()` itself).

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

# Measure the inflated size of a gzip-wrapped stream without materialising it,
# aborting as soon as the running total exceeds `max_bytes`.
#
# Only the gzip wrapper (magic 1f 8b) can be streamed: `gzcon()` passes a bare
# zlib stream through unchanged, which would under-measure it. Every call site
# reaches this function through a `sniff_format() == "gzip"` guard, which keys
# on that same magic, so the streamed shape is the only one reachable in
# practice; the bare-zlib shape is bounded after the fact by the caller instead.
gzip_size_guard <- function(bytes, max_bytes, chunk_size = 65536L) {
  if (!sniff_starts_with(bytes, c(0x1F, 0x8B))) {
    return(invisible(FALSE))
  }
  # A header gzcon() dislikes warns here; damage is memDecompress()'s to report.
  con <- suppressWarnings(gzcon(rawConnection(bytes, "rb")))
  on.exit(close(con), add = TRUE)

  total <- 0
  repeat {
    chunk <- suppressWarnings(tryCatch(
      readBin(con, what = "raw", n = chunk_size),
      error = function(cnd) raw()
    ))
    if (length(chunk) == 0L) {
      break
    }
    total <- total + length(chunk)
    if (total > max_bytes) {
      gzip_abort_ceiling(max_bytes, total)
    }
  }
  invisible(TRUE)
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
  streamed <- gzip_size_guard(bytes, max_bytes)

  out <- tryCatch(
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

  # A bare zlib stream could not be measured up front, so hold the ceiling as a
  # returned-size invariant instead: the memory is already spent, but an
  # over-ceiling body is still never handed back.
  if (!streamed && length(out) > max_bytes) {
    gzip_abort_ceiling(max_bytes, length(out))
  }
  out
}
