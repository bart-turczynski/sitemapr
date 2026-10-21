# Fixture -> finding-code map for validate_sitemap() (SITE-mnbswkkr).
#
# Takes over the fixture-to-code enumeration that protocol_validation.feature
# carried as one scenario per code. Each row drives the public
# validate_sitemap() on a committed fixture (or an in-memory document) and
# asserts that a code is present, with an optional severity, or absent.
# Pairs another plain test already asserts end to end are not repeated:
# PROTOCOL_DUPLICATE_LOC, UNSUPPORTED_ROOT and UNSUPPORTED_HTML_MASQUERADE
# (test-validate-sitemap.R).
#
# Offline: the two URL-source cases serve their documents through
# httr2::local_mocked_responses.

fc_ns <- "http://www.sitemaps.org/schemas/sitemap/0.9"

fc_urlset <- function(locs) {
  paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<urlset xmlns=\"",
    fc_ns,
    "\">",
    paste0("<url><loc>", locs, "</loc></url>", collapse = ""),
    "</urlset>"
  )
}

# In-memory documents, so the 50k-entry count cases are never committed.
fc_generated <- list(
  "count-at-cap" = function() {
    fc_urlset(sprintf("https://example.com/p%d", seq_len(50000L)))
  },
  "count-over-cap" = function() {
    fc_urlset(sprintf("https://example.com/p%d", seq_len(50001L)))
  },
  # Canonically equal (default port) but not byte-identical.
  "default-port-pair" = function() {
    fc_urlset(c("https://example.com:443/page", "https://example.com/page"))
  }
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
  "text-long-url.txt"          , "PROTOCOL_TEXT_URL_TOO_LONG"     , NA
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

# valid-text.txt carries one blank line, so strict mode adds only the
# strict-only blank-line info. (The scenario's "no protocol finding" step was
# shadowed by `no {word} finding is produced` and checked for a code named
# "protocol", so it never looked at the layer.)
test_that("a valid text sitemap produces no protocol-layer finding", {
  out <- fc_validate("valid-text.txt", "non-strict")
  expect_false(any(out$layer == "protocol"))
  strict <- fc_validate("valid-text.txt", "strict")
  expect_identical(
    strict$code[strict$layer == "protocol"],
    "PROTOCOL_TEXT_BLANK_LINE"
  )
})

# ---- URL sources (offline mocks) ------------------------------------------

fc_mock_by_url <- function(map) {
  function(req) {
    body <- map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/xml; charset=UTF-8"),
      body = charToRaw(body)
    )
  }
}

test_that("a loc on another host produces PROTOCOL_URL_OUT_OF_SCOPE", {
  # The scope check needs an origin URL, which a local file does not have.
  url <- "https://example.com/sitemap.xml"
  map <- stats::setNames(list(fc_urlset("https://other-domain.test/page")), url)
  httr2::local_mocked_responses(fc_mock_by_url(map))
  out <- validate_sitemap(url, mode = "strict")
  expect_true("PROTOCOL_URL_OUT_OF_SCOPE" %in% out$code)
})

test_that("an index child in an unsupported feed dialect is UNSUPPORTED_FEED", {
  # RSS 2.0 and Atom parse into rows; a <feed> in a non-Atom namespace does
  # not. Index expansion only runs for a URL source.
  index_url <- "https://example.com/sitemap.xml"
  map <- list()
  map[[index_url]] <- paste(
    readLines(test_path("fixtures", "index-rss-child.xml"), warn = FALSE),
    collapse = "\n"
  )
  map[["https://example.com/feed.xml"]] <- paste0(
    "<feed xmlns=\"http://example.com/not-atom\">",
    "<entry><link href=\"https://example.com/x\"/></entry></feed>\n"
  )
  httr2::local_mocked_responses(fc_mock_by_url(map))
  out <- validate_sitemap(index_url, mode = "strict")
  sev <- out$severity[out$code == "UNSUPPORTED_FEED"]
  expect_gt(length(sev), 0L)
  expect_false(any(sev == "fatal"))
})

# ---- Discovery request order (from discovery.feature) ----------------------

test_that("sitemap_tree requests the guessed paths in catalog order", {
  root <- "https://example.com"
  log <- new.env(parent = emptyenv())
  log$urls <- character(0)
  httr2::local_mocked_responses(function(req) {
    log$urls <- c(log$urls, req$url)
    httr2::response(status_code = 404L, url = req$url)
  })
  tree <- sitemap_tree(root, limits = discovery_limits(), use_robots = FALSE)
  expect_true(any(endsWith(tree$sitemap_url, "/sitemap.xml")))
  expect_true(any(endsWith(tree$sitemap_url, "/sitemap_index.xml")))
  expect_identical(log$urls, discovery_candidates(root)$candidate_url)
})
