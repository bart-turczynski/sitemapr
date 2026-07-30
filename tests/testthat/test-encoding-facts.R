# Encoding-fact producer + wiring tests (R/encoding-facts.R; SITE-vepzywnc).
#
# The D.6 conflict logic (validate_encoding()) was already unit-tested in
# test-protocol-validate.R against a hand-built source_meta(). What was missing
# was a PRODUCER: nothing in production filled bom_encoding, declared_encoding
# or http_charset, so both ENCODING_* codes were unreachable from the public
# entry points. These tests cover the three producers and then prove
# reachability end-to-end through validate_sitemap() and audit_sitemap().
#
# Offline throughout: local fixtures, plus httr2 mocks for the HTTP-charset leg.

bom_of <- function(x) sitemapr_test_ns$bom_encoding_of(x)
decl_of <- function(x) sitemapr_test_ns$declared_xml_encoding(x)
charset_of <- function(x) sitemapr_test_ns$content_type_charset(x)

enc_fixture <- function(name) {
  test_path("fixtures", "corpus", "encoding", name)
}

enc_bytes <- function(name) {
  path <- enc_fixture(name)
  readBin(path, what = "raw", n = file.info(path)$size)
}

# A one-URL urlset with the given XML declaration prefix.
enc_urlset <- function(decl) {
  paste0(
    decl,
    "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
    "<url><loc>https://example.com/a</loc></url></urlset>"
  )
}

# Serve `body` with the given Content-Type; a NA header serves none at all.
enc_mock <- function(body, content_type) {
  function(req) {
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = if (is.na(content_type)) {
        list()
      } else {
        list("Content-Type" = content_type)
      },
      body = charToRaw(body)
    )
  }
}

enc_validate_url <- function(body, content_type, ...) {
  suppressWarnings(httr2::with_mocked_responses(
    enc_mock(body, content_type),
    validate_sitemap("https://example.com/sitemap.xml", ...)
  ))
}

# ---- bom_encoding_of() -------------------------------------------------------

test_that("a byte-order mark yields its encoding name", {
  expect_identical(bom_of(enc_bytes("utf8-bom.xml")), "UTF-8")
  expect_identical(bom_of(enc_bytes("utf16-le-bom.xml")), "UTF-16LE")
})

test_that("bytes without a BOM yield no BOM signal", {
  expect_identical(bom_of(enc_bytes("no-encoding.xml")), NA_character_)
  expect_identical(bom_of(raw(0L)), NA_character_)
})

test_that("bom_encoding_of() reports no signal for non-raw input", {
  # Defensive: every production caller passes the source bytes, but the fact
  # producers must never raise — an absent signal is always NA.
  expect_identical(bom_of("<?xml version=\"1.0\"?>"), NA_character_)
  expect_identical(bom_of(NULL), NA_character_)
})

# ---- declared_xml_encoding() -------------------------------------------------

test_that("the XML declaration's encoding is extracted, case preserved", {
  latin1 <- enc_urlset("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>")
  expect_identical(decl_of(charToRaw(latin1)), "ISO-8859-1")
  expect_identical(
    decl_of(charToRaw(enc_urlset("<?xml version='1.0' encoding='utf-8'?>"))),
    "utf-8"
  )
})

test_that("the declaration is still read past a byte-order mark", {
  expect_identical(decl_of(enc_bytes("bom-conflict.xml")), "ISO-8859-1")
})

test_that("a document with no encoding signal declares nothing", {
  expect_identical(decl_of(enc_bytes("no-encoding.xml")), NA_character_)
  expect_identical(decl_of(charToRaw(enc_urlset(""))), NA_character_)
  expect_identical(decl_of(raw(0L)), NA_character_)
  expect_identical(decl_of("not raw"), NA_character_)
})

test_that("an empty encoding value is no signal", {
  expect_identical(
    decl_of(charToRaw(enc_urlset("<?xml version=\"1.0\" encoding=\"\"?>"))),
    NA_character_
  )
})

test_that("an unterminated XML declaration is not trusted", {
  # No "?>" within the previewed bytes: the attribute may be truncated, so the
  # producer reports no signal rather than a possibly-partial name.
  expect_identical(
    decl_of(charToRaw("<?xml version=\"1.0\" encoding=\"UTF-8\"")),
    NA_character_
  )
})

test_that("a UTF-16 document's declaration survives the ASCII preview", {
  # The interleaved NULs would make rawToChar() raise; the preview drops them,
  # so the declaration of a genuinely UTF-16-encoded document is still read.
  decl <- "<?xml version=\"1.0\" encoding=\"UTF-16\"?><urlset/>"
  utf16 <- as.raw(c(
    0xFF,
    0xFE,
    as.vector(rbind(as.integer(charToRaw(decl)), 0L))
  ))
  expect_identical(bom_of(utf16), "UTF-16LE")
  expect_identical(decl_of(utf16), "UTF-16")
})

# ---- content_type_charset() --------------------------------------------------

test_that("the Content-Type charset parameter is extracted", {
  expect_identical(
    charset_of("application/xml; charset=ISO-8859-1"),
    "ISO-8859-1"
  )
  expect_identical(charset_of("text/xml;charset=\"utf-8\""), "utf-8")
  expect_identical(charset_of("text/xml; CHARSET=UTF-8"), "UTF-8")
})

test_that("a header naming no charset is no signal", {
  # The critical case: httr2::resp_encoding() answers "UTF-8" here, which would
  # make every response assert a charset it never sent.
  expect_identical(charset_of("application/xml"), NA_character_)
  expect_identical(charset_of(NA_character_), NA_character_)
  expect_identical(charset_of(NULL), NA_character_)
  expect_identical(charset_of(character(0)), NA_character_)
})

test_that("the fetch record carries only the charset the response sent", {
  rec <- suppressWarnings(httr2::with_mocked_responses(
    enc_mock(enc_urlset(""), "application/xml"),
    sitemapr_test_ns$fetch_source("https://example.com/sitemap.xml")
  ))
  expect_identical(rec$charset, NA_character_)

  rec2 <- suppressWarnings(httr2::with_mocked_responses(
    enc_mock(enc_urlset(""), "application/xml; charset=ISO-8859-1"),
    sitemapr_test_ns$fetch_source("https://example.com/sitemap.xml")
  ))
  expect_identical(rec2$charset, "ISO-8859-1")
})

# ---- reachability from the public entry points -------------------------------

test_that("a BOM/declaration conflict fires from validate_sitemap()", {
  out <- suppressWarnings(validate_sitemap(enc_fixture("bom-conflict.xml")))
  expect_true("ENCODING_BOM_DECLARATION_CONFLICT" %in% out$code)
  row <- out[out$code == "ENCODING_BOM_DECLARATION_CONFLICT", ]
  expect_identical(row$layer, "classification")
  expect_identical(row$subject_type, "source")
  # Strict mode elevates this one code from its non-strict `info`.
  expect_identical(row$severity, "warning")

  lax <- suppressWarnings(
    validate_sitemap(enc_fixture("bom-conflict.xml"), mode = "non-strict")
  )
  expect_identical(
    lax$severity[lax$code == "ENCODING_BOM_DECLARATION_CONFLICT"],
    "info"
  )
})

test_that("the canonical UTF-16 spelling fires no conflict (SITE-zarjabyz)", {
  # encoding="UTF-16" plus a UTF-16 BOM is the conformant spelling of a UTF-16
  # entity, and it used to raise ENCODING_BOM_DECLARATION_CONFLICT end to end.
  # Built here rather than added under fixtures/corpus/, which is
  # byte-identical to the sibling port's fixtures/ and must not diverge
  # unilaterally; the want is recorded on SITE-ppojfsed.
  path <- withr::local_tempfile(fileext = ".xml")
  doc <- enc_urlset("<?xml version=\"1.0\" encoding=\"UTF-16\"?>")
  utf16 <- iconv(doc, "UTF-8", "UTF-16LE", toRaw = TRUE)[[1]]
  writeBin(c(as.raw(c(0xFF, 0xFE)), utf16), path)
  out <- suppressWarnings(validate_sitemap(path))

  # zarjabyz's claim, unchanged: the two signals AGREE, so there is no conflict.
  expect_false("ENCODING_BOM_DECLARATION_CONFLICT" %in% out$code)
  # What it is NOT is UTF-8, which the protocol requires (SITE-kqnnnvyr). The
  # two statements are compatible: a conformantly-declared UTF-16 document is
  # still a non-conformant sitemap.
  expect_identical(
    sort(out$code),
    c("ENCODING_BOM_DETECTED", "ENCODING_NOT_UTF8")
  )
  expect_identical(out$severity[out$code == "ENCODING_NOT_UTF8"], "error")
  # The document still decodes: these findings judge it, they do not reject it.
  expect_identical(
    suppressWarnings(read_sitemap(path))$loc,
    "https://example.com/a"
  )
})

test_that("a source with no encoding signal at all produces no finding", {
  for (name in c("declared-utf8-no-bom.xml", "no-encoding.xml")) {
    out <- suppressWarnings(validate_sitemap(enc_fixture(name)))
    expect_false(any(startsWith(out$code, "ENCODING_")), info = name)
  }
})

test_that("a UTF-8 BOM is reported but is not a UTF-8 violation", {
  # ENCODING_BOM_DETECTED is a fact, not a fault: a UTF-8 BOM is tolerated
  # (sitemap-spec.md §12.5), so it must not drag ENCODING_NOT_UTF8 along.
  out <- suppressWarnings(validate_sitemap(enc_fixture("utf8-bom.xml")))

  expect_identical(out$code, "ENCODING_BOM_DETECTED")
  expect_identical(out$severity, "info")
})

test_that("a non-UTF-8 declaration is a violation even with ASCII bytes", {
  # declared-iso8859-no-bom.xml declares ISO-8859-1 over bytes that are pure
  # ASCII. The rule is a LABEL test, so it fires — matching the sibling's
  # isUtf8EncodingLabel() tier, which also does not look at the bytes.
  out <- suppressWarnings(
    validate_sitemap(enc_fixture("declared-iso8859-no-bom.xml"))
  )

  expect_identical(out$code, "ENCODING_NOT_UTF8")
  expect_identical(out$severity, "error")
  expect_match(out$message, "ISO-8859-1", fixed = TRUE)
})

test_that("the cascade reports the highest-priority signal that offends", {
  # bom-conflict.xml is a UTF-8 BOM over a declared ISO-8859-1. The BOM is
  # clean, so the reason names the DECLARATION, not the mark.
  out <- suppressWarnings(validate_sitemap(enc_fixture("bom-conflict.xml")))
  msg <- out$message[out$code == "ENCODING_NOT_UTF8"]

  expect_match(msg, "XML declaration", fixed = TRUE)
  expect_no_match(msg, "byte-order mark", fixed = TRUE)
})

test_that("bytes that decode as UTF-8 are not flagged on the byte tier", {
  expect_true(sitemapr_test_call("bytes_are_valid_utf8", charToRaw("héllo")))
  expect_false(
    sitemapr_test_call("bytes_are_valid_utf8", as.raw(c(0x68, 0xFF, 0x69)))
  )
  # A NUL is valid UTF-8 and is stripped before the test rather than raising.
  expect_true(
    sitemapr_test_call("bytes_are_valid_utf8", as.raw(c(0x3C, 0x00, 0x3F)))
  )
  expect_identical(sitemapr_test_call("bytes_are_valid_utf8", "not raw"), NA)
})

test_that("invalid bytes with no declared encoding reach the byte tier", {
  # The only route to the last tier: no BOM, no declaration, no charset, so the
  # resolution defaults to UTF-8 and only the bytes can contradict it.
  meta <- sitemapr_test_call("source_meta", bytes_valid_utf8 = FALSE)
  out <- sitemapr_test_call("validate_encoding", meta, "https://s.xml")

  expect_identical(out$code, "ENCODING_NOT_UTF8")
  expect_match(out$message, "content bytes are not valid UTF-8", fixed = TRUE)
})

test_that("an HTTP charset disagreeing with the declaration fires", {
  out <- enc_validate_url(
    enc_urlset("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>"),
    "application/xml; charset=UTF-8"
  )
  row <- out[out$code == "ENCODING_CONFLICT", ]

  expect_identical(nrow(row), 1L)
  expect_identical(row$severity, "info")
  expect_match(row$message, "HTTP charset=UTF-8", fixed = TRUE)
  # The declaration is also a UTF-8 violation in its own right; the conflict
  # and the violation are separate claims about the same document.
  expect_true("ENCODING_NOT_UTF8" %in% out$code)
})

test_that("a response naming no charset invents no conflict", {
  body <- enc_urlset("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>")

  for (ct in list("application/xml", NA_character_)) {
    out <- enc_validate_url(body, ct)
    # No charset means no second signal, so no conflict is manufactured. The
    # declaration's own ISO-8859-1 violation still stands on its own.
    expect_false("ENCODING_CONFLICT" %in% out$code)
    expect_identical(out$code, "ENCODING_NOT_UTF8")
  }
})

test_that("the audit projection produces the same encoding findings", {
  # audit_sitemap() shares one fetch between its two projections; the encoding
  # part must ride along identically or the equivalence bar breaks.
  body <- enc_urlset("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>")
  ct <- "application/xml; charset=UTF-8"
  validated <- enc_validate_url(body, ct)
  audited <- suppressWarnings(httr2::with_mocked_responses(
    enc_mock(body, ct),
    audit_findings(audit_sitemap("https://example.com/sitemap.xml"))
  ))
  expect_identical(audited$code, validated$code)
  expect_identical(audited$message, validated$message)
})

test_that("a source with no document bytes emits no encoding finding", {
  # The malformed-gzip branch never inflated any bytes, so there is nothing to
  # read a BOM or declaration from.
  bad_gzip <- test_path("fixtures", "corpus", "compressed", "invalid.gz")
  out <- suppressWarnings(validate_sitemap(bad_gzip))
  expect_identical(out$code, "UNSUPPORTED_MALFORMED_GZIP")
})

# ---- charset_for_document() -------------------------------------------------
#
# A `charset` on a compressed body describes whatever the Content-Type says the
# body is. On a binary container it says nothing about the document inside, so
# comparing it to the inner XML declaration invented an ENCODING_CONFLICT
# (SITE-ppojfsed). Mirrors the sibling's charsetForDecompressedBody().

test_that("an uncompressed body always keeps its HTTP charset", {
  # The document bytes ARE the response bytes, so the charset describes them
  # whatever the media type is called.
  expect_identical(
    charset_for_document("iso-8859-1", "application/octet-stream", FALSE),
    "iso-8859-1"
  )
  expect_identical(
    charset_for_document("utf-8", "text/xml", FALSE),
    "utf-8"
  )
})

test_that("a compressed body drops a charset on a binary container", {
  for (ct in binary_container_types) {
    expect_identical(
      charset_for_document("iso-8859-1", ct, TRUE),
      NA_character_
    )
  }
  # Case and surrounding space are not significant in a media type.
  expect_identical(
    charset_for_document("iso-8859-1", "  APPLICATION/GZIP  ", TRUE),
    NA_character_
  )
})

test_that("a compressed body keeps a charset on an XML or text type", {
  expect_identical(
    charset_for_document("iso-8859-1", "text/xml", TRUE),
    "iso-8859-1"
  )
  expect_identical(
    charset_for_document("iso-8859-1", "application/xml", TRUE),
    "iso-8859-1"
  )
})

test_that("a compressed body with no Content-Type drops the charset", {
  # An absent type asserts nothing about what the bytes are.
  expect_identical(
    charset_for_document("iso-8859-1", NA_character_, TRUE),
    NA_character_
  )
})

test_that("an absent charset stays absent whatever the type", {
  expect_identical(
    charset_for_document(NA_character_, "text/xml", TRUE),
    NA_character_
  )
  expect_identical(
    charset_for_document(NA_character_, "application/gzip", FALSE),
    NA_character_
  )
})

# ---- the gzip charset false positive, end to end ----------------------------

# Serve `body` gzipped, with the given Content-Type (NA serves none).
enc_gzip_mock <- function(body, content_type) {
  path <- withr::local_tempfile(fileext = ".gz", .local_envir = parent.frame())
  con <- gzfile(path, "wb")
  writeBin(charToRaw(body), con)
  close(con)
  gz <- readBin(path, "raw", file.info(path)$size)
  function(req) {
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = if (is.na(content_type)) {
        list()
      } else {
        list("Content-Type" = content_type)
      },
      body = gz
    )
  }
}

enc_validate_gzip <- function(body, content_type) {
  suppressWarnings(httr2::with_mocked_responses(
    enc_gzip_mock(body, content_type),
    validate_sitemap("https://example.com/sitemap.xml.gz")
  ))
}

test_that("a gzip container charset invents no encoding conflict", {
  # A UTF-8 sitemap, correctly declared, gzipped, served with a charset on the
  # CONTAINER type. Before the fix this reported ENCODING_CONFLICT against a
  # perfectly conformant document.
  body <- enc_urlset("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  out <- enc_validate_gzip(body, "application/gzip; charset=iso-8859-1")
  expect_false("ENCODING_CONFLICT" %in% out$code)
  expect_identical(nrow(out), 0L)

  out <- enc_validate_gzip(body, "application/octet-stream; charset=iso-8859-1")
  expect_identical(nrow(out), 0L)

  out <- enc_validate_gzip(body, NA_character_)
  expect_identical(nrow(out), 0L)
})

test_that("a gzip served as XML still reports a real encoding conflict", {
  # The narrowing must not silence the case where the charset IS a claim about
  # the sitemap — that would trade a false positive for a false negative.
  body <- enc_urlset("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>")
  out <- enc_validate_gzip(body, "text/xml; charset=UTF-8")
  expect_true("ENCODING_CONFLICT" %in% out$code)

  out <- enc_validate_gzip(body, "application/xml; charset=UTF-8")
  expect_true("ENCODING_CONFLICT" %in% out$code)
})

test_that("audit and validate agree on a gzipped source's charset", {
  # The rule lives in one shared helper, but the two projections call it from
  # different call sites — this is the net for the second one.
  body <- enc_urlset("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  ct <- "application/gzip; charset=iso-8859-1"
  validated <- enc_validate_gzip(body, ct)
  audited <- suppressWarnings(httr2::with_mocked_responses(
    enc_gzip_mock(body, ct),
    audit_findings(audit_sitemap("https://example.com/sitemap.xml.gz"))
  ))
  expect_identical(audited$code, validated$code)
})
