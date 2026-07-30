# Encoding facts read off a source's bytes and its HTTP response (Layer B;
# docs/sitemap-spec.md §3). Internal only.
#
# The three signals the encoding-conflict diagnostics compare — the byte-order
# mark, the XML declaration's `encoding=`, and the HTTP `Content-Type` charset —
# are PRODUCED here and consumed by `validate_encoding()`
# (R/classification-validate.R). Keeping the producers out of that file holds
# the D.6 module to its stated contract: it reads a `source_meta()` and never
# re-sniffs the bytes itself.
#
# Every producer reports only what the source actually carries: an absent signal
# is `NA`, never a default. That matters because `validate_encoding()` treats
# two present-and-disagreeing signals as a conflict — inventing "UTF-8" for a
# response whose `Content-Type` named no charset would manufacture conflicts
# that the document does not have. (It is also what the TS port does: its
# `httpCharset` is `null` when the header omits the parameter.)

# The encoding named by a leading byte-order mark, or NA when there is none.
# Reuses the text parser's BOM table (R/parse-text.R) — the marks and their
# encodings are the same on every path, only the reaction to a non-UTF-8 mark
# differs (the text format rejects it; XML may legitimately be UTF-16).
bom_encoding_of <- function(bytes) {
  if (!is.raw(bytes)) {
    return(NA_character_)
  }
  bom <- text_detect_bom(bytes)
  if (is.null(bom)) {
    return(NA_character_)
  }
  bom$encoding
}

# The `encoding=` value of the XML declaration, or NA when the source has no
# declaration or the declaration omits the attribute.
#
# Read from an ASCII preview of the leading bytes rather than a decoded string:
# the declaration is ASCII by definition, and the preview drops the interleaved
# NULs of a UTF-16-encoded document, so its declaration is still recovered
# (`rawToChar()` would raise on those bytes). Case is preserved so the finding
# message can quote the document's own spelling.
declared_xml_encoding <- function(bytes) {
  if (!is.raw(bytes)) {
    return(NA_character_)
  }
  bom <- text_detect_bom(bytes)
  if (!is.null(bom)) {
    bytes <- bytes[-seq_along(bom$bytes)]
  }
  decl <- xml_declaration(sniff_markup_preview(bytes, 1024L, lower = FALSE))
  if (is.na(decl)) {
    return(NA_character_)
  }
  encoding_attr(decl)
}

# The `<?xml ... ?>` declaration at the front of `s` (leading whitespace
# allowed), or NA when `s` does not open with one. An unterminated declaration
# yields NA: with no `?>` in the previewed bytes there is nothing to trust.
xml_declaration <- function(s) {
  s <- sub("^[[:space:]]+", "", s)
  if (!startsWith(s, "<?xml")) {
    return(NA_character_)
  }
  end <- regexpr("?>", s, fixed = TRUE)
  if (end < 0L) {
    return(NA_character_)
  }
  substring(s, 1L, end + 1L)
}

# The value of an `encoding="..."` / `encoding='...'` attribute in `decl`, or NA
# when it carries none. An empty value (`encoding=""`) is no signal.
encoding_attr <- function(decl) {
  pattern <- "encoding[[:space:]]*=[[:space:]]*(\"[^\"]*\"|'[^']*')"
  m <- regmatches(decl, regexpr(pattern, decl, perl = TRUE))
  if (length(m) == 0L) {
    return(NA_character_)
  }
  # Drop the attribute name, the separator, and the surrounding quote pair.
  value <- sub("^encoding[[:space:]]*=[[:space:]]*.", "", m, perl = TRUE)
  value <- substring(value, 1L, nchar(value) - 1L)
  if (!nzchar(value)) {
    return(NA_character_)
  }
  value
}

# The `charset` parameter of a `Content-Type` header value, or NA when the
# header is absent or names no charset. The value may be quoted (RFC 9110 §5.6).
content_type_charset <- function(header) {
  if (is.null(header) || length(header) == 0L) {
    return(NA_character_)
  }
  header <- as.character(header)[[1L]]
  if (is.na(header)) {
    return(NA_character_)
  }
  pattern <- "charset[[:space:]]*=[[:space:]]*\"?([^\";[:space:]]+)"
  m <- regmatches(
    header,
    regexpr(pattern, header, perl = TRUE, ignore.case = TRUE)
  )
  if (length(m) == 0L) {
    return(NA_character_)
  }
  sub(pattern, "\\1", m, perl = TRUE, ignore.case = TRUE)
}

# Media types that name a compressed *container*. A `charset` parameter on one
# of these describes the container's bytes — which are binary — and asserts
# nothing about the encoding of the document inside it.
binary_container_types <- c(
  "application/gzip",
  "application/x-gzip",
  "application/gzip-compressed",
  "application/gzipped",
  "application/x-gunzip",
  "application/octet-stream",
  "application/x-tar",
  "application/tar",
  "application/x-compressed",
  "application/x-compressed-tar",
  "binary/octet-stream"
)

# Decide whether the response's HTTP charset describes the DOCUMENT whose bytes
# the encoding facts are read from, and so may be compared against that
# document's own BOM and XML declaration.
#
# When the body was not compressed the document bytes ARE the response bytes, so
# the charset always describes them. When the body was gzip, what the charset
# describes depends on what the server said the body was:
#
#   application/gzip; charset=…  the charset labels a binary container and is
#     meaningless — comparing it to the inner XML declaration emits a false
#     ENCODING_CONFLICT, so it is dropped.
#   text/xml; charset=…          the server is labelling the payload as XML
#     text, so the charset is a real claim about the sitemap and a mismatch
#     with the declaration is a real conflict worth reporting.
#
# An absent Content-Type on a compressed body says nothing either, so it drops
# too. Mirrors the sibling's `charsetForDecompressedBody()` (sitemap-validator
# e90ccdf) rule for rule, closing a cross-port divergence recorded on
# SMV-dhrpsgvo — sitemapr used to compare unconditionally.
charset_for_document <- function(charset, content_type, was_gzip) {
  if (!isTRUE(was_gzip) || is.na(charset)) {
    return(charset)
  }
  if (is.na(content_type)) {
    return(NA_character_)
  }
  if (tolower(trimws(content_type)) %in% binary_container_types) {
    return(NA_character_)
  }
  charset
}

# The classification-layer encoding findings for one source: the three facts,
# bundled into a `source_meta()` and handed to the D.6 producer. `bytes` are the
# DECOMPRESSED source bytes (a gzip's BOM and declaration live in the inflated
# stream); `http_charset` is NA for a local file, which has no response, and for
# a compressed body whose Content-Type named a binary container (see
# `charset_for_document()`).
encoding_findings <- function(bytes, http_charset, base) {
  validate_encoding(
    source_meta(
      bom_encoding = bom_encoding_of(bytes),
      declared_encoding = declared_xml_encoding(bytes),
      http_charset = http_charset,
      bytes_valid_utf8 = bytes_are_valid_utf8(bytes)
    ),
    base
  )
}

# Whether the source bytes decode as UTF-8, or NA when there are no bytes to
# judge. The last tier of the `ENCODING_NOT_UTF8` cascade, which only matters
# for a source that declares no encoding at all.
#
# NUL bytes are dropped before the test. `iconv()` raises on an embedded NUL
# rather than judging it, and dropping them cannot change the verdict: a NUL is
# itself a valid UTF-8 sequence (U+0000) and can never appear INSIDE a
# multi-byte one, whose continuation bytes are all 0x80-0xBF. So removing a NUL
# only splices together sequences that were already independent.
bytes_are_valid_utf8 <- function(bytes) {
  if (!is.raw(bytes)) {
    return(NA)
  }
  bytes <- bytes[bytes != as.raw(0L)]
  !is.na(iconv(list(bytes), "UTF-8", "UTF-8"))
}
