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

#' Decompress a single gzip stream to raw bytes
#'
#' Transparently inflates a gzip- (or zlib-) compressed sitemap stream so the
#' inner content can be sniffed and parsed. A corrupt or truncated stream raises
#' a `sitemapr_decompression_error` condition rather than returning garbage.
#'
#' @param bytes Raw vector (or coercible to raw) of the compressed stream.
#' @return A raw vector of the decompressed bytes.
#' @keywords internal
#' @noRd
gzip_decompress <- function(bytes) {
  if (!is.raw(bytes)) {
    bytes <- as.raw(bytes)
  }
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
