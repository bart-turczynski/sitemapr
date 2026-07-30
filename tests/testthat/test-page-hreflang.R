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

# ---- the `Link` header channel -----------------------------------------------

# HTML content-type headers plus a `Link` field declaring alternates.
ph_link_headers <- function(value) {
  list("Content-Type" = "text/html; charset=UTF-8", Link = value)
}

test_that("alternates declared ONLY in the Link header are observed", {
  # Regression: the header channel was ignored outright, so a header-only page
  # read as `absent` and a real page/sitemap disagreement went unreported.
  art <- ph_art(
    "<html><head></head></html>",
    headers = ph_link_headers(
      "<https://example.com/de>; rel=\"alternate\"; hreflang=\"de\""
    )
  )
  ex <- page_hreflang_extract(art)
  expect_identical(ex$status, "observed")
  expect_identical(ex$set, paste("de", "https://example.com/de", sep = "\t"))

  subjects <- ph_subjects(art, list(ph_alt("fr", "https://example.com/fr")))
  out <- page_hreflang_findings(ph_run(art), subjects)
  expect_identical(out$code, "PAGE_HREFLANG_MISMATCH")
})

test_that("the two channels union rather than one overriding the other", {
  art <- ph_art(
    ph_html(c("de", "https://example.com/de")),
    headers = ph_link_headers(
      "<https://example.com/fr>; rel=\"alternate\"; hreflang=\"fr\""
    )
  )
  expect_length(page_hreflang_extract(art)$set, 2L)

  # The union agreeing with the sitemap emits nothing; either channel alone
  # would have disagreed.
  subjects <- ph_subjects(
    art,
    list(
      ph_alt("de", "https://example.com/de"),
      ph_alt("fr", "https://example.com/fr")
    )
  )
  expect_identical(nrow(page_hreflang_findings(ph_run(art), subjects)), 0L)
})

test_that("an alternate declared in BOTH channels collapses to one entry", {
  art <- ph_art(
    ph_html(c("de", "https://example.com/de")),
    headers = ph_link_headers(
      "<https://example.com/de>; rel=\"alternate\"; hreflang=\"DE\""
    )
  )
  expect_length(page_hreflang_extract(art)$set, 1L)
})

test_that("a repeated hreflang parameter names one target twice", {
  # RFC 8288 3.4 — each occurrence declares another language for the same URI.
  links <- page_hreflang_header_links(list(
    Link = paste(
      "<https://example.com/de>; rel=alternate;",
      "hreflang=de; hreflang=de-AT"
    )
  ))
  expect_length(links, 2L)
  expect_identical(
    vapply(links, function(l) l$tag, character(1)),
    c("de", "de-AT")
  )
  expect_identical(links[[2L]]$href, "https://example.com/de")
})

test_that("a Link header without rel=alternate declares no alternates", {
  expect_identical(
    page_hreflang_header_links(list(
      Link = "<https://example.com/x>; rel=\"canonical\"; hreflang=\"de\""
    )),
    list()
  )
  # rel=alternate carrying no hreflang is an alternate representation, not a
  # localized one.
  expect_identical(
    page_hreflang_header_links(list(
      Link = "<https://example.com/feed>; rel=\"alternate\""
    )),
    list()
  )
})

test_that("a relative header href resolves against the final URL", {
  # A <base href> in the body governs the body's links only, never a header's.
  art <- ph_art(
    "<html><head><base href=\"https://other.test/x/\"></head></html>",
    headers = ph_link_headers("</de>; rel=\"alternate\"; hreflang=\"de\"")
  )
  expect_identical(
    page_hreflang_extract(art)$set,
    paste("de", "https://example.com/de", sep = "\t")
  )
})

test_that("a non-HTML resource can declare alternates in the header alone", {
  # The header form is the only channel available to a non-HTML file.
  art <- ph_art(
    "%PDF-1.4",
    headers = list(
      "Content-Type" = "application/pdf",
      Link = "<https://example.com/de>; rel=\"alternate\"; hreflang=\"de\""
    )
  )
  expect_identical(page_hreflang_extract(art)$status, "observed")
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
    "#page-url:https%3A%2F%2Fexample.com%2Fa",
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

# ---- head parsing edge cases -------------------------------------------------

test_that("an absent or unparseable body yields no links", {
  expect_identical(
    page_hreflang_html_links(raw(0), "https://example.com/a"),
    list(base = "https://example.com/a", links = list())
  )

  # xml2's HTML parser is famously lenient, so the tryCatch guard is pinned by
  # forcing the parse to fail rather than by feeding it malformed markup.
  testthat::local_mocked_bindings(
    read_html = function(...) stop("parse failed"),
    .package = "xml2"
  )
  expect_identical(
    page_hreflang_html_links(
      charToRaw(ph_html(c("de", "https://example.com/de"))),
      "https://example.com/a"
    ),
    list(base = "https://example.com/a", links = list())
  )
})

test_that("a <base href> sets the resolution base for relative alternates", {
  art <- ph_art(paste0(
    "<html><head><base href=\"/sub/\">",
    "<link rel=\"alternate\" hreflang=\"de\" href=\"de.html\">",
    "</head></html>"
  ))
  html <- page_hreflang_html_links(art$body, art$final_url)

  expect_identical(html$base, "https://example.com/sub/")
  # The relative alternate resolves against <base>, not against final_url.
  set <- page_hreflang_norm_set(html$links, html$base)
  expect_match(set, "example.com/sub/de.html")
})

test_that("an unresolvable <base href> falls back to the final URL", {
  html <- page_hreflang_html_links(
    charToRaw("<html><head><base href=\"://nonsense\"></head></html>"),
    "https://example.com/a"
  )

  expect_identical(html$base, "https://example.com/a")
})

test_that("a blank hreflang tag drops the alternate", {
  # A tag that trims to nothing has no locale identity, so it cannot join the
  # comparable set.
  set <- page_hreflang_norm_set(
    list(
      list(tag = "  ", href = "https://example.com/de"),
      list(tag = "fr", href = "https://example.com/fr")
    ),
    "https://example.com/a"
  )

  expect_length(set, 1L)
  expect_match(set, "^fr\t")
})

# ---- sitemap-declared set ----------------------------------------------------

test_that("sitemap alternates missing href or hreflang are dropped", {
  loc <- "https://example.com/"
  expect_length(page_hreflang_declared_set(list(ph_alt("de", NULL)), loc), 0L)
  no_tag <- ph_alt(NULL, "https://example.com/de")
  expect_length(page_hreflang_declared_set(list(no_tag), loc), 0L)
})

test_that("a sitemap alternate with a non-alternate rel is dropped", {
  loc <- "https://example.com/"
  stylesheet <- ph_alt("de", "https://example.com/de", rel = "stylesheet")
  expect_length(page_hreflang_declared_set(list(stylesheet), loc), 0L)

  # An ABSENT rel is permitted (the attribute is optional); only a present rel
  # that is not "alternate" disqualifies the link.
  expect_length(
    page_hreflang_declared_set(
      list(ph_alt("de", "https://example.com/de", rel = NULL)),
      loc
    ),
    1L
  )
})

# ---- findings assembly -------------------------------------------------------

test_that("a run with no artifacts produces no hreflang findings", {
  empty <- structure(
    list(artifacts = list(), coverage = list()),
    class = "page_inspection_run"
  )

  out <- page_hreflang_findings(empty)
  expect_identical(nrow(out), 0L)
  expect_identical(out, empty_page_findings())
})

test_that("NULL subjects self-anchor each advertised loc", {
  # The direct-producer path passes no subjects: each loc anchors itself with
  # no sitemap-declared alternates, so no mismatch can fire.
  art <- ph_art(ph_html(c("de", "https://example.com/de")))

  expect_identical(nrow(page_hreflang_findings(ph_run(art))), 0L)
})

test_that("a subject loc with no fetched artifact is skipped", {
  art <- ph_art(ph_html(c("de", "https://example.com/de")))
  absent <- "https://example.com/never-fetched"
  subjects <- list(
    loc = c(art$requested_url, absent),
    base = list(
      sitemap_subject_ref(art$requested_url),
      sitemap_subject_ref(absent)
    ),
    alt = list(NULL, NULL)
  )

  # The unfetched loc is skipped rather than erroring on a NULL artifact.
  expect_identical(nrow(page_hreflang_findings(ph_run(art), subjects)), 0L)
})
