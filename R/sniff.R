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
#   "empty", "gzip", "tar", "xml-urlset", "xml-sitemapindex", "feed", "xml",
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
  if (
    sniff_starts_with(bytes, c(0xFE, 0xFF)) ||
      sniff_starts_with(bytes, c(0xFF, 0xFE))
  ) {
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

# Strip a single `<! ... >` declaration (e.g. `<!DOCTYPE ...>`) from the front
# of `s`, accounting for a DOCTYPE internal subset in brackets whose own
# declarations may contain ">". A naive "consume to the first >" stops inside
# the subset and strands "]>...<root>", e.g. for
# `<!DOCTYPE urlset [ <!ENTITY xxe SYSTEM "..."> ]>`. When a "[" opens before
# the closing ">", skip from "[" to the matching "]" and then to the next ">".
# Returns the same list shape as strip_one_prologue_token().
strip_declaration <- function(s) {
  gt <- regexpr(">", s, fixed = TRUE)
  if (gt < 0L) {
    return(list(done = TRUE, s = ""))
  }
  open <- regexpr("[", s, fixed = TRUE)
  has_subset <- open > 0L && open < gt
  if (!has_subset) {
    return(list(done = FALSE, s = substring(s, gt + 1L)))
  }
  close <- regexpr("]", substring(s, open + 1L), fixed = TRUE)
  if (close < 0L) {
    return(list(done = TRUE, s = "")) # unterminated internal subset
  }
  close_abs <- open + close
  after_gt <- regexpr(">", substring(s, close_abs + 1L), fixed = TRUE)
  if (after_gt < 0L) {
    return(list(done = TRUE, s = "")) # subset closed but no trailing ">"
  }
  list(done = FALSE, s = substring(s, close_abs + after_gt + 1L))
}

# Consume one XML prologue construct from the front of `s`: a comment
# <!-- ... -->, a processing instruction / declaration <? ... ?>, or the
# DOCTYPE / other <! ... > markup. `s` must already have its leading whitespace
# stripped and be non-empty. Returns a list:
#   $done  TRUE when stripping should stop — either the front is the root
#          element (returned in $s) or an unterminated construct was hit
#          ($s == "");
#          FALSE when one construct was consumed and the loop should continue.
#   $s     the remaining string.
strip_one_prologue_token <- function(s) {
  if (startsWith(s, "<!--")) {
    end <- regexpr("-->", s, fixed = TRUE)
    if (end < 0L) {
      return(list(done = TRUE, s = "")) # unterminated comment
    }
    return(list(done = FALSE, s = substring(s, end + 3L)))
  }
  if (startsWith(s, "<?")) {
    end <- regexpr("?>", s, fixed = TRUE)
    if (end < 0L) {
      return(list(done = TRUE, s = ""))
    }
    return(list(done = FALSE, s = substring(s, end + 2L)))
  }
  if (startsWith(s, "<!")) {
    return(strip_declaration(s))
  }
  list(done = TRUE, s = s) # root element reached
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
    step <- strip_one_prologue_token(s)
    if (step$done) {
      return(step$s)
    }
    s <- step$s
  }
}

# Classify a markup root element (prologue already stripped) into a format name,
# or NA_character_ when nothing matches. Order matters: sitemap roots win over
# feed roots, which win over the HTML / generic-XML catch-alls. An optional
# namespace prefix like "ns:urlset" is allowed, plus attributes/namespaces after
# the element name.
sniff_classify_root <- function(root) {
  ns <- "([a-z0-9_.-]+:)?"
  tail <- "([[:space:]>/]|$)"
  # Ordered dispatch: the first matching pattern wins. Sitemap roots are listed
  # before feed roots so a urlset / sitemapindex always wins; the generic-XML
  # catch-all is last. (HTML, with several markers, is matched separately.)
  # RSS (`<rss>`) and Atom (`<feed>`) share the one "feed" classification.
  patterns <- c(
    "xml-urlset" = paste0("^<", ns, "urlset", tail),
    "xml-sitemapindex" = paste0("^<", ns, "sitemapindex", tail),
    "feed" = paste0("^<", ns, "(rss|feed)", tail),
    "xml" = paste0("^<", ns, "[a-z][a-z0-9_.-]*", tail)
  )
  # HTML markers, checked before the generic-XML catch-all so markup like
  # <html>/<head>/<body> is "html", but after the sitemap/feed roots so an XML
  # sitemap is never mistaken for HTML.
  html_tags <- "^<(head|body|title|meta|table|div|span|p|a|ul|ol|li)"
  is_html <- startsWith(root, "<!doctype html") ||
    grepl(paste0("^<html", tail), root) ||
    grepl(paste0(html_tags, tail), root)
  for (i in seq_along(patterns)) {
    if (names(patterns)[i] == "xml" && is_html) {
      return("html")
    }
    if (grepl(patterns[[i]], root)) {
      return(names(patterns)[i])
    }
  }
  NA_character_
}

# Detect a markup format from raw bytes — an XML sitemap root, a feed, HTML, or
# generic XML — or NA_character_ when the bytes are not recognisable markup.
# Strips a leading BOM, builds a lowercase ASCII preview, drops the XML
# prologue, then classifies the root element. A bare `<!doctype html ...>` with
# no separate root (one the prologue stripping would have eaten) is also HTML.
sniff_classify_markup <- function(bytes) {
  bom <- sniff_bom_length(bytes)
  if (bom > 0L) {
    bytes <- bytes[-seq_len(bom)]
  }
  preview <- sniff_markup_preview(bytes)
  trimmed <- sub("^[[:space:]]+", "", preview)
  if (startsWith(trimmed, "<")) {
    fmt <- sniff_classify_root(sniff_strip_prologue(trimmed))
    if (!is.na(fmt)) {
      return(fmt)
    }
  }
  if (startsWith(trimmed, "<!doctype html")) {
    return("html")
  }
  NA_character_
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

  # 4. XML vs HTML.
  markup <- sniff_classify_markup(bytes)
  if (!is.na(markup)) {
    return(markup)
  }

  # 5. text vs binary.
  if (sniff_is_text(bytes)) {
    return("text")
  }
  "binary"
}
