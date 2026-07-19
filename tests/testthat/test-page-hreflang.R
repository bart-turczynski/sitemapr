# Offline tests for the page hreflang reconciliation producer
# (R/page-hreflang.R; Layer E, Contract B/C, E.4).
#
# The set-vs-set reconciliation, the both-non-empty predicate, the ADR-005
# identity normalization, and the absent/unknown gate are exercised by
# constructing page_fetch_artifacts + sitemap-declared alternate lists directly
# (no network). The validate integration (a mismatch surfaces; inspect_pages =
# FALSE byte-identical) runs over a LOCAL sitemap with the page fetch
# httr2-mocked, so the suite is offline.

# An artifact with a usable HTML body (helpers in another test file are not
# visible here). `body` is an HTML string; `headers` a named list.
ph_art <- function(
  body,
  outcome = "usable_body",
  requested = "https://example.com/a",
  final = requested,
  headers = list("Content-Type" = "text/html; charset=UTF-8")
) {
  page_fetch_artifact(
    requested_url = requested,
    final_url = final,
    hops = list(list(url = requested, status = 200L, location = NA_character_)),
    terminal_headers = headers,
    body = charToRaw(body),
    outcome = outcome,
    request_user_agent = "inspector/test"
  )
}

# A run wrapping one artifact advertised by its requested URL.
ph_run <- function(art) {
  key <- art$requested_url
  entry <- list(fetch_url = key, advertised = key, artifact = art)
  structure(
    list(artifacts = stats::setNames(list(entry), key), coverage = list()),
    class = "page_inspection_run"
  )
}

# An `alternates` list-column entry as xml2::as_list() shapes it: an empty list
# carrying rel/hreflang/href attributes (what hreflang_link_attrs() reads).
ph_alt <- function(hreflang, href, rel = "alternate") {
  structure(list(), rel = rel, hreflang = hreflang, href = href)
}

# An HTML head declaring the given (hreflang, href) alternates.
ph_html <- function(...) {
  pairs <- list(...)
  links <- vapply(
    pairs,
    function(p) {
      sprintf(
        "<link rel=\"alternate\" hreflang=\"%s\" href=\"%s\">",
        p[[1L]],
        p[[2L]]
      )
    },
    character(1)
  )
  paste0("<html><head>", paste(links, collapse = ""), "</head></html>")
}

# One (loc, base, alt) subject set for a single-page run.
ph_subjects <- function(art, alt, loc = art$requested_url) {
  list(loc = loc, base = sitemap_subject_ref(loc), alt = list(alt))
}

# ---- extraction --------------------------------------------------------------

test_that("a page declaring alternates is `observed` with a normalized set", {
  art <- ph_art(ph_html(
    c("de", "https://example.com/de"),
    c("fr", "https://example.com/fr")
  ))
  ex <- page_hreflang_extract(art)
  expect_identical(ex$status, "observed")
  expect_length(ex$set, 2L)
})

test_that("a complete HTML body with no alternates is `absent`", {
  expect_identical(
    page_hreflang_extract(ph_art("<html><head></head></html>"))$status,
    "absent"
  )
})

test_that("a partial body with no alternates is `unknown`", {
  ex <- page_hreflang_extract(
    ph_art("<html><head></head></html>", outcome = "partial")
  )
  expect_identical(ex$status, "unknown")
})

# ---- reconciliation predicate ------------------------------------------------

test_that("agreeing page and sitemap sets emit no finding", {
  art <- ph_art(ph_html(c("de", "https://example.com/de")))
  subjects <- ph_subjects(art, list(ph_alt("de", "https://example.com/de")))
  out <- page_hreflang_findings(ph_run(art), subjects)
  expect_identical(nrow(out), 0L)
})

test_that("disagreeing non-empty sets emit PAGE_HREFLANG_MISMATCH (warning)", {
  art <- ph_art(ph_html(c("fr", "https://example.com/fr")))
  subjects <- ph_subjects(art, list(ph_alt("de", "https://example.com/de")))
  out <- page_hreflang_findings(ph_run(art), subjects)
  expect_identical(out$code, "PAGE_HREFLANG_MISMATCH")
  expect_identical(out$severity, "warning")
  expect_match(
    out$subject_ref,
    "#page-url:https://example.com/a",
    fixed = TRUE
  )
})

test_that("an empty page set vs a populated sitemap is NOT a mismatch", {
  art <- ph_art("<html><head></head></html>")
  subjects <- ph_subjects(art, list(ph_alt("de", "https://example.com/de")))
  expect_identical(nrow(page_hreflang_findings(ph_run(art), subjects)), 0L)
})

test_that("a populated page vs an empty sitemap is NOT a mismatch", {
  art <- ph_art(ph_html(c("de", "https://example.com/de")))
  subjects <- ph_subjects(art, list())
  expect_identical(nrow(page_hreflang_findings(ph_run(art), subjects)), 0L)
})

test_that("a partial body never emits a mismatch (softened)", {
  art <- ph_art(ph_html(c("fr", "https://example.com/fr")), outcome = "partial")
  subjects <- ph_subjects(art, list(ph_alt("de", "https://example.com/de")))
  expect_identical(nrow(page_hreflang_findings(ph_run(art), subjects)), 0L)
})

# ---- ADR-005 identity normalization ------------------------------------------

test_that("tag case and href fragment differences do NOT count as a mismatch", {
  # Page: DE-de + a fragment on the href; sitemap: de-de + no fragment.
  art <- ph_art(ph_html(c("DE-de", "https://example.com/de#top")))
  subjects <- ph_subjects(art, list(ph_alt("de-DE", "https://example.com/de")))
  expect_identical(nrow(page_hreflang_findings(ph_run(art), subjects)), 0L)
})

test_that("a relative page href resolves against the final URL", {
  # Page declares hreflang=de href="/de" (relative) -> resolves to /de, which
  # agrees with the sitemap's absolute /de.
  art <- ph_art(ph_html(c("de", "/de")), final = "https://example.com/a")
  subjects <- ph_subjects(art, list(ph_alt("de", "https://example.com/de")))
  expect_identical(nrow(page_hreflang_findings(ph_run(art), subjects)), 0L)
})

# ---- registry conformance ----------------------------------------------------

test_that("the emitted hreflang severity conforms to the registry", {
  # The drift guard enforces the code<->registry match at the verify gate; here
  # we pin the severity the producer must emit for a CRAN-safe unit test too.
  expect_identical(page_hreflang_severity("PAGE_HREFLANG_MISMATCH"), "warning")
})

# ---- validate integration ----------------------------------------------------

# A one-URL urlset whose <url> carries an xhtml:link alternate.
ph_local_sitemap <- function() {
  xml <- paste0(
    "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\" ",
    "xmlns:xhtml=\"http://www.w3.org/1999/xhtml\">",
    "<url><loc>https://example.com/a</loc>",
    "<xhtml:link rel=\"alternate\" hreflang=\"de\" ",
    "href=\"https://example.com/de\"/>",
    "</url></urlset>"
  )
  path <- tempfile(fileext = ".xml")
  writeLines(xml, path)
  path
}

test_that("inspect_pages surfaces a page/sitemap hreflang mismatch", {
  path <- ph_local_sitemap()
  # The page declares a DIFFERENT alternate (fr) than the sitemap (de).
  resp <- httr2::response(
    status_code = 200L,
    url = "https://example.com/a",
    headers = list("Content-Type" = "text/html; charset=UTF-8"),
    body = charToRaw(ph_html(c("fr", "https://example.com/fr")))
  )
  httr2::local_mocked_responses(list(resp))

  out <- validate_sitemap(path, inspect_pages = TRUE)
  page_rows <- out[out$layer == "page", ]
  expect_true("PAGE_HREFLANG_MISMATCH" %in% page_rows$code)
  expect_identical(ncol(out), 10L)
})

test_that("inspect_pages = FALSE stays byte-identical with alternates", {
  path <- ph_local_sitemap()
  off <- validate_sitemap(path)
  explicit_off <- validate_sitemap(path, inspect_pages = FALSE)
  expect_identical(off, explicit_off)
  expect_null(attr(off, "page_coverage"))
  expect_false("page" %in% off$layer)
})
