# Fixture -> finding-code map for validate_sitemap() (SITE-mnbswkkr).
#
# Takes over the fixture-to-code enumeration that protocol_validation.feature
# carried as one scenario per code. Each row drives the public
# validate_sitemap() on a committed fixture (or an in-memory document) and
# asserts that a code is present, with an optional severity, or absent.
# Pairs another plain test already asserts end to end are not repeated:
# PROTOCOL_DUPLICATE_LOC, UNSUPPORTED_ROOT, UNSUPPORTED_HTML_MASQUERADE and
# UNSUPPORTED_FEED (test-validate-sitemap.R).
#
# Offline: the URL-source case serves its document through
# httr2::local_mocked_responses.

# In-memory documents, built with urlset_xml() from helper-concurrency.R.
fc_generated <- list(
  # The count cases run under a cap of 2 (fc_options), not the 50,000 default:
  # 2 URLs sit at the cap, 3 go over it.
  "count-at-cap" = function() {
    urlset_xml(sprintf("https://example.com/p%d", 1:2))
  },
  "count-over-cap" = function() {
    urlset_xml(sprintf("https://example.com/p%d", 1:3))
  },
  # Canonically equal (default port) but not byte-identical.
  "default-port-pair" = function() {
    urlset_xml("https://example.com:443/page", "https://example.com/page")
  }
)

# Options a source is validated under.
fc_options <- list(
  "count-at-cap" = list(sitemapr.max_url_count = 2L),
  "count-over-cap" = list(sitemapr.max_url_count = 2L)
)

fc_source <- function(name, env = parent.frame()) {
  gen <- fc_generated[[name]]
  if (is.null(gen)) {
    return(test_path("fixtures", name))
  }
  path <- withr::local_tempfile(fileext = ".xml", .local_envir = env)
  writeBin(charToRaw(gen()), path)
  path
}

fc_validate <- function(name, mode, env = parent.frame()) {
  opts <- fc_options[[name]]
  if (!is.null(opts)) {
    withr::local_options(opts)
  }
  validate_sitemap(fc_source(name, env), mode = mode)
}

# Strict mode. The code fires; every hit carries `severity` unless it is NA.
fc_present <- tibble::tribble(
  ~source                      , ~code                            , ~severity ,
  "url-relative.xml"           , "PROTOCOL_URL_NOT_ABSOLUTE"      , NA        ,
  "url-non-https.xml"          , "PROTOCOL_URL_NOT_ABSOLUTE"      , NA        ,
  "default-port-pair"          , "PROTOCOL_URL_EQUIVALENT"        , "warning" ,
  "url-fragment.xml"           , "PROTOCOL_URL_FRAGMENT"          , "info"    ,
  "url-invalid-escape.xml"     , "PROTOCOL_URL_INVALID_ESCAPE"    , NA        ,
  "url-iri-path.xml"           , "PROTOCOL_URL_NOT_ESCAPED"       , "info"    ,
  "url-unescaped-illegal.xml"  , "PROTOCOL_URL_NOT_ESCAPED"       , "warning" ,
  "count-over-cap"             , "PROTOCOL_URL_COUNT_EXCEEDED"    , NA        ,
  "priority-out-of-range.xml"  , "PROTOCOL_PRIORITY_OUT_OF_RANGE" , NA        ,
  "changefreq-invalid.xml"     , "PROTOCOL_CHANGEFREQ_INVALID"    , NA        ,
  "lastmod-date-only.xml"      , "PROTOCOL_LASTMOD_DATE_ONLY"     , "info"    ,
  "lastmod-invalid.xml"        , "PROTOCOL_LASTMOD_INVALID"       , NA        ,
  "hreflang-invalid-sep.xml"   , "HREFLANG_SEPARATOR_INVALID"     , NA        ,
  "hreflang-no-xdefault.xml"   , "HREFLANG_XDEFAULT_MISSING"      , NA        ,
  "hreflang-duplicate.xml"     , "HREFLANG_DUPLICATE"             , NA        ,
  "hreflang-relative-href.xml" , "HREFLANG_HREF_RELATIVE"         , NA        ,
  "text-blank-lines.txt"       , "PROTOCOL_TEXT_BLANK_LINE"       , "info"    ,
  "text-long-url.txt"          , "PROTOCOL_TEXT_URL_TOO_LONG"     , NA        ,
  "ns-unknown.xml"             , "SCHEMA_UNKNOWN_NAMESPACE"       , NA
)

# The code does not fire, in strict (TRUE) or non-strict (FALSE) mode.
fc_absent <- tibble::tribble(
  ~source                      , ~strict , ~code                            ,
  "default-port-pair"          , TRUE    , "PROTOCOL_DUPLICATE_LOC"         ,
  "count-at-cap"               , TRUE    , "PROTOCOL_URL_COUNT_EXCEEDED"    ,
  "priority-boundary.xml"      , TRUE    , "PROTOCOL_PRIORITY_OUT_OF_RANGE" ,
  "lastmod-date-only.xml"      , FALSE   , "PROTOCOL_LASTMOD_DATE_ONLY"     ,
  "hreflang-relative-href.xml" , FALSE   , "HREFLANG_HREF_RELATIVE"         ,
  "text-blank-lines.txt"       , FALSE   , "PROTOCOL_TEXT_BLANK_LINE"
)

for (i in seq_len(nrow(fc_present))) {
  local({
    case <- fc_present[i, ]
    test_that(sprintf("%s produces %s", case$source, case$code), {
      if (startsWith(case$code, "SCHEMA_")) {
        # Same guard as test-schema-validate.R: the XSD catalog ships in inst/.
        skip_if(identical(schema_dir(), ""), "package not installed")
      }
      out <- fc_validate(case$source, "strict")
      hits <- out[out$code == case$code, , drop = FALSE]
      expect_gt(nrow(hits), 0L)
      if (!is.na(case$severity)) {
        expect_true(all(hits$severity == case$severity))
      }
    })
  })
}

for (i in seq_len(nrow(fc_absent))) {
  local({
    case <- fc_absent[i, ]
    mode <- if (case$strict) "strict" else "non-strict"
    test_that(sprintf("%s (%s) has no %s", case$source, mode, case$code), {
      out <- fc_validate(case$source, mode)
      expect_false(case$code %in% out$code)
    })
  })
}

# Clean fixtures: no finding of a whole family.
test_that("a valid hreflang set produces no HREFLANG_* finding", {
  out <- fc_validate("hreflang-valid.xml", "strict")
  expect_false(any(grepl("^HREFLANG_", out$code)))
})

# valid-text.txt carries one blank line, so strict mode adds the strict-only
# blank-line info. (The scenario's "no protocol finding" step was shadowed by
# `no {word} finding is produced` and checked for a code named "protocol", so
# it never looked at the layer.)
test_that("valid-text.txt: clean non-strict, strict adds only BLANK_LINE", {
  out <- fc_validate("valid-text.txt", "non-strict")
  expect_false(any(out$layer == "protocol"))
  strict <- fc_validate("valid-text.txt", "strict")
  expect_identical(
    strict$code[strict$layer == "protocol"],
    "PROTOCOL_TEXT_BLANK_LINE"
  )
})

# The count rows above lower the cap to 2; the protocol default is 50,000.
test_that("the URL count cap defaults to 50,000", {
  withr::local_options(sitemapr.max_url_count = NULL)
  expect_identical(protocol_limits()$max_url_count, 50000L)
})

# ---- URL source (offline mock) ----------------------------------------------

test_that("a loc on another host produces PROTOCOL_URL_OUT_OF_SCOPE", {
  # The scope check needs an origin URL, which a local file does not have.
  url <- "https://example.com/sitemap.xml"
  map <- list()
  map[[url]] <- urlset_xml("https://other-domain.test/page")
  local_index_server(map)
  out <- validate_sitemap(url, mode = "strict")
  expect_true("PROTOCOL_URL_OUT_OF_SCOPE" %in% out$code)
})
