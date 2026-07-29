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

test_that("agreeing encoding signals produce no finding", {
  for (name in c(
    "utf8-bom.xml",
    "declared-utf8-no-bom.xml",
    "declared-iso8859-no-bom.xml",
    "no-encoding.xml"
  )) {
    out <- suppressWarnings(validate_sitemap(enc_fixture(name)))
    expect_false(any(startsWith(out$code, "ENCODING_")), info = name)
  }
})

test_that("an HTTP charset disagreeing with the declaration fires", {
  out <- enc_validate_url(
    enc_urlset("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>"),
    "application/xml; charset=UTF-8"
  )
  expect_identical(out$code, "ENCODING_CONFLICT")
  expect_identical(out$severity, "info")
  expect_match(out$message, "HTTP charset=UTF-8", fixed = TRUE)
})

test_that("a response naming no charset invents no conflict", {
  body <- enc_urlset("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>")
  expect_identical(nrow(enc_validate_url(body, "application/xml")), 0L)
  expect_identical(nrow(enc_validate_url(body, NA_character_)), 0L)
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
