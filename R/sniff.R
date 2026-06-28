# Byte-level format sniffer (Layer B, architecture.md §3).
#
# Pure, side-effect-free, no-network, no-parse. The fetch engine calls
# `sniff_format()` on the RAW response body bytes (the kind returned by
# `httr2::resp_body_raw()` / `readBin(..., what = "raw")`) to classify a source
# by its CONTENT, independent of file extension or Content-Type header.
#
# This is a LIGHTWEIGHT leading-bytes scan, NOT a parser. It never pulls in
# `xml2` and never attempts a full XML parse. Full root-element / namespace
# extraction is a downstream slice's job; here we only peek at the first element
# name enough to distinguish the sitemap roots from other XML/HTML.
#
# The returned value is ONE string from this closed set:
#   "empty", "gzip", "tar", "xml-urlset", "xml-sitemapindex", "xml",
#   "html", "text", "binary"
# The feature `fetch_classification.feature` pins "xml-urlset" and "gzip" as
# non-negotiable; the remaining names follow docs/architecture.md / docs/PRD.md.
#
# Detection order (first match wins):
#   1. empty   — zero bytes (whitespace-only is NOT empty; it is text).
#   2. gzip    — leading magic 1f 8b. A .tar.gz is gzip-wrapped, so it correctly
#                sniffs as "gzip" (outer layer); only an uncompressed tar is
#                "tar".
#   3. tar     — ASCII "ustar" at byte offset 257 (POSIX tar header).
#   4. xml/html — skip BOM + whitespace + XML decl/comments/PIs/DOCTYPE, then
#                read the first element name; sitemap roots are checked BEFORE
#                the generic HTML markers because both start with "<".
#   5. text vs binary — printable-ratio heuristic (see sniff_is_text()).

# ---- helpers: low-level byte access ------------------------------------------

# TRUE when the raw vector begins with the given integer byte sequence.
sniff_starts_with <- function(bytes, magic) {
  n <- length(magic)
  if (length(bytes) < n) {
    return(FALSE)
  }
  all(as.integer(bytes[seq_len(n)]) == magic)
}

# Number of leading bytes that make up a byte-order mark, or 0L if none.
# Recognises UTF-8 (EF BB BF) and UTF-16 BE/LE (FE FF / FF FE).
sniff_bom_length <- function(bytes) {
  if (sniff_starts_with(bytes, c(0xEF, 0xBB, 0xBF))) {
    return(3L)
  }
  if (sniff_starts_with(bytes, c(0xFE, 0xFF)) ||
        sniff_starts_with(bytes, c(0xFF, 0xFE))) {
    return(2L)
  }
  0L
}

# ---- helpers: tar ------------------------------------------------------------

# POSIX (ustar) tar puts the magic "ustar" at offset 257 (0-based) in the first
# 512-byte header block. We need at least offset+5 bytes to read it.
sniff_is_tar <- function(bytes) {
  if (length(bytes) < 262L) {
    return(FALSE)
  }
  magic <- rawToChar(bytes[258:262])
  identical(magic, "ustar")
}

# ---- helpers: text vs binary -------------------------------------------------

# Decide whether the bytes look like decodable text.
#
# Rule (documented threshold): a single NUL byte (0x00) means binary outright.
# Otherwise count "control" bytes — C0 controls below 0x20 that are NOT the
# common text whitespace (TAB 0x09, LF 0x0a, CR 0x0d, FF 0x0c) plus the DEL
# byte 0x7f. If such control bytes are more than 10% of the (sampled) content,
# treat it as binary; otherwise text. High bytes (>= 0x80) are NOT counted as
# control: they are valid UTF-8 continuation/lead bytes and legitimate text.
# Only the first 4096 bytes are sampled — enough to classify cheaply.
sniff_is_text <- function(bytes) {
  n <- length(bytes)
  if (n == 0L) {
    return(FALSE)
  }
  sample_n <- min(n, 4096L)
  sample <- as.integer(bytes[seq_len(sample_n)])
  if (any(sample == 0L)) {
    return(FALSE)
  }
  allowed_ws <- c(0x09L, 0x0AL, 0x0CL, 0x0DL)
  is_control <- (sample < 0x20L & !(sample %in% allowed_ws)) | sample == 0x7FL
  mean(is_control) <= 0.10
}

# ---- helpers: XML / HTML markup ----------------------------------------------

# From the leading bytes (BOM already stripped), produce a short lowercase ASCII
# preview string suitable for markup probing. Non-ASCII bytes are dropped; this
# is only used to look for "<", element names, and HTML keywords, all ASCII.
sniff_markup_preview <- function(bytes, max_bytes = 4096L) {
  take <- min(length(bytes), max_bytes)
  if (take == 0L) {
    return("")
  }
  ints <- as.integer(bytes[seq_len(take)])
  ascii <- ints[ints >= 0x09L & ints <= 0x7EL]
  if (length(ascii) == 0L) {
    return("")
  }
  tolower(rawToChar(as.raw(ascii)))
}

# Drop leading whitespace and any sequence of XML prologue constructs that may
# precede the root element: the <?xml ...?> declaration, processing instructions
# <? ... ?>, comments <!-- ... -->, and the DOCTYPE / other <! ... > markup.
# Returns the remaining string starting at (or before) the root element.
sniff_strip_prologue <- function(s) {
  repeat {
    s <- sub("^[[:space:]]+", "", s)
    if (!nzchar(s)) {
      return(s)
    }
    if (startsWith(s, "<!--")) {
      end <- regexpr("-->", s, fixed = TRUE)
      if (end < 0L) {
        return("") # unterminated comment: nothing usable follows
      }
      s <- substring(s, end + 3L)
      next
    }
    if (startsWith(s, "<?")) {
      end <- regexpr("?>", s, fixed = TRUE)
      if (end < 0L) {
        return("")
      }
      s <- substring(s, end + 2L)
      next
    }
    # <!DOCTYPE ...> or other declaration-style markup (but NOT a comment, which
    # is handled above). Consume up to the next ">".
    if (startsWith(s, "<!")) {
      end <- regexpr(">", s, fixed = TRUE)
      if (end < 0L) {
        return("")
      }
      s <- substring(s, end + 1L)
      next
    }
    return(s)
  }
}

# ---- main entry point --------------------------------------------------------

# Classify raw bytes into exactly one format string from the closed set above.
# `bytes` is a raw vector. NULL or a length-0 raw vector classifies as "empty".
sniff_format <- function(bytes) {
  if (is.null(bytes)) {
    return("empty")
  }
  if (!is.raw(bytes)) {
    bytes <- as.raw(bytes)
  }
  if (length(bytes) == 0L) {
    return("empty")
  }

  # 2. gzip (covers .gz and .tar.gz — the outer layer).
  if (sniff_starts_with(bytes, c(0x1F, 0x8B))) {
    return("gzip")
  }

  # 3. uncompressed POSIX tar.
  if (sniff_is_tar(bytes)) {
    return("tar")
  }

  # 4. XML vs HTML — skip BOM, then probe markup.
  body <- bytes
  bom <- sniff_bom_length(body)
  if (bom > 0L) {
    body <- body[-seq_len(bom)]
  }
  preview <- sniff_markup_preview(body)
  trimmed <- sub("^[[:space:]]+", "", preview)

  if (startsWith(trimmed, "<")) {
    root <- sniff_strip_prologue(trimmed)

    # Sitemap roots first (both start with "<"; an optional ns prefix like
    # "ns:urlset" is allowed, plus attributes/namespaces after the name).
    if (grepl("^<([a-z0-9_.-]+:)?urlset([[:space:]>/]|$)", root)) {
      return("xml-urlset")
    }
    if (grepl("^<([a-z0-9_.-]+:)?sitemapindex([[:space:]>/]|$)", root)) {
      return("xml-sitemapindex")
    }

    # HTML markers. Check after the sitemap roots so an XML sitemap is never
    # mistaken for HTML.
    html_tags <- "^<(head|body|title|meta|table|div|span|p|a|ul|ol|li)"
    if (startsWith(root, "<!doctype html") ||
          grepl("^<html([[:space:]>/]|$)", root) ||
          grepl(paste0(html_tags, "([[:space:]>/]|$)"), root)) {
      return("html")
    }

    # Any other recognisable XML root element.
    if (grepl("^<([a-z0-9_.-]+:)?[a-z][a-z0-9_.-]*([[:space:]>/]|$)", root)) {
      return("xml")
    }
  }

  # A bare <!doctype html ...> with no separate root (handled above as part of
  # prologue stripping would have eaten it); also catch a leading doctype that
  # `trimmed` exposes directly.
  if (startsWith(trimmed, "<!doctype html")) {
    return("html")
  }

  # 5. text vs binary.
  if (sniff_is_text(bytes)) {
    return("text")
  }
  "binary"
}
