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

# The classification-layer encoding findings for one source: the three facts,
# bundled into a `source_meta()` and handed to the D.6 producer. `bytes` are the
# DECOMPRESSED source bytes (a gzip's BOM and declaration live in the inflated
# stream); `http_charset` is NA for a local file, which has no response.
encoding_findings <- function(bytes, http_charset, base) {
  validate_encoding(
    source_meta(
      bom_encoding = bom_encoding_of(bytes),
      declared_encoding = declared_xml_encoding(bytes),
      http_charset = http_charset
    ),
    base
  )
}
