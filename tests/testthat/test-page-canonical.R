# Offline tests for the page canonical extractor + finding producer
# (R/page-canonical.R; Layer E, Contract B/C, E.2).
#
# Extraction status, the both-channel extraction, the ADR-005 canonical-key
# comparison, and the absent-vs-unknown gate are exercised by constructing
# page_fetch_artifacts directly (no network). The validate integration (a
# canonical row surfaces; inspect_pages = FALSE byte-identical) runs over a
# LOCAL sitemap file with the page fetch httr2-mocked, so the suite is offline.

# An artifact with a usable HTML body + optional headers (helpers in another
# test file are not visible here). `body` is an HTML string; `headers` a named
# list (repeated fields as repeated names).
pc_art <- function(
  body = "<html><head></head></html>",
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

# A run wrapping one artifact advertised by exactly its requested URL.
pc_run <- function(art, advertised = art$requested_url) {
  key <- art$requested_url
  entry <- list(fetch_url = key, advertised = advertised, artifact = art)
  entries <- stats::setNames(list(entry), key)
  structure(
    list(artifacts = entries, coverage = list()),
    class = "page_inspection_run"
  )
}

canonical_link <- function(href) {
  paste0(
    "<html><head><link rel=\"canonical\" href=\"",
    href,
    "\"></head></html>"
  )
}

# ---- extraction status -------------------------------------------------------

test_that("a complete HTML body with a canonical is `observed`", {
  ex <- page_canonical_extract(pc_art(canonical_link("https://example.com/b")))
  expect_identical(ex$status, "observed")
  expect_identical(page_canonical_targets(ex), "https://example.com/b")
})

test_that("a complete HTML body with no canonical is `absent`", {
  ex <- page_canonical_extract(pc_art("<html><head></head></html>"))
  expect_identical(ex$status, "absent")
})

test_that("a partial body with no canonical is `unknown`, never absent", {
  ex <- page_canonical_extract(
    pc_art("<html><head></head></html>", outcome = "partial")
  )
  expect_identical(ex$status, "unknown")
})

test_that("a non-HTML body with no canonical is `not_applicable`", {
  ex <- page_canonical_extract(pc_art(
    "%PDF-1.7 not html",
    headers = list("Content-Type" = "application/pdf")
  ))
  expect_identical(ex$status, "not_applicable")
})

test_that("a non-usable-body outcome extracts nothing (not_applicable)", {
  art <- page_fetch_artifact(
    requested_url = "https://example.com/a",
    outcome = "http_status",
    request_user_agent = "t"
  )
  expect_identical(page_canonical_extract(art)$status, "not_applicable")
})

# ---- mismatch / missing findings ---------------------------------------------

test_that("a canonical to a different URL emits MISMATCH (warning)", {
  art <- pc_art(canonical_link("https://example.com/other"))
  out <- page_canonical_findings(pc_run(art))
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "PAGE_CANONICAL_MISMATCH")
  expect_identical(out$severity, "warning")
  expect_match(out$message, "https://example.com/other", fixed = TRUE)
  expect_match(
    out$subject_ref,
    "#page-url:https://example.com/a",
    fixed = TRUE
  )
})

test_that("a self-referential canonical emits no finding", {
  art <- pc_art(canonical_link("https://example.com/a"))
  expect_identical(nrow(page_canonical_findings(pc_run(art))), 0L)
})

test_that("a canonical differing only by fragment agrees (fragment dropped)", {
  art <- pc_art(canonical_link("https://example.com/a#section"))
  expect_identical(nrow(page_canonical_findings(pc_run(art))), 0L)
})

test_that("no on-page canonical emits PAGE_CANONICAL_MISSING (info)", {
  art <- pc_art("<html><head></head></html>")
  out <- page_canonical_findings(pc_run(art))
  expect_identical(out$code, "PAGE_CANONICAL_MISSING")
  expect_identical(out$severity, "info")
})

test_that("a partial body with no canonical emits nothing (unknown softened)", {
  art <- pc_art("<html><head></head></html>", outcome = "partial")
  expect_identical(nrow(page_canonical_findings(pc_run(art))), 0L)
})

# ---- both channels + relative resolution -------------------------------------

test_that("the HTTP Link header canonical is honored (http_link channel)", {
  art <- pc_art(
    "<html><head></head></html>",
    headers = list(
      "Content-Type" = "text/html",
      "Link" = "<https://example.com/other>; rel=\"canonical\""
    )
  )
  out <- page_canonical_findings(pc_run(art))
  expect_identical(out$code, "PAGE_CANONICAL_MISMATCH")
  expect_match(out$message, "https://example.com/other", fixed = TRUE)
})

test_that("a relative canonical resolves against the final URL", {
  # Relative /b resolves to https://example.com/b -> mismatch with loc /a.
  art <- pc_art(canonical_link("/b"), final = "https://example.com/a")
  out <- page_canonical_findings(pc_run(art))
  expect_identical(out$code, "PAGE_CANONICAL_MISMATCH")
  expect_match(out$message, "https://example.com/b", fixed = TRUE)
})

test_that("a <base href> overrides the base for a relative canonical", {
  body <- paste0(
    "<html><head><base href=\"https://example.com/sub/\">",
    "<link rel=\"canonical\" href=\"page\"></head></html>"
  )
  art <- pc_art(body, final = "https://example.com/a")
  out <- page_canonical_findings(pc_run(art))
  # Resolves against the <base>, not the final URL: /sub/page.
  expect_match(out$message, "https://example.com/sub/page", fixed = TRUE)
})

# ---- registry conformance ----------------------------------------------------

test_that("emitted canonical severities conform to the registry", {
  # The CSV lives in docs/ (not built into the package); the drift guard
  # (tools/check-findings-registry.R) enforces the code<->registry match at the
  # verify gate. Here we pin the severities the producer must emit so a drift in
  # page_canonical_severity() fails a CRAN-safe unit test too.
  expected <- c(
    PAGE_CANONICAL_MISMATCH = "warning",
    PAGE_CANONICAL_MISSING = "info"
  )
  for (code in names(expected)) {
    expect_identical(page_canonical_severity(code), unname(expected[[code]]))
  }
})

# ---- validate integration ----------------------------------------------------

pc_local_sitemap <- function(loc = "https://example.com/a") {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<url><loc>",
    loc,
    "</loc></url></urlset>"
  )
  path <- tempfile(fileext = ".xml")
  writeLines(xml, path)
  path
}

test_that("inspect_pages surfaces a canonical mismatch in the page layer", {
  path <- pc_local_sitemap("https://example.com/a")
  resp <- httr2::response(
    status_code = 200L,
    url = "https://example.com/a",
    headers = list("Content-Type" = "text/html; charset=UTF-8"),
    body = charToRaw(canonical_link("https://example.com/canonical"))
  )
  httr2::local_mocked_responses(list(resp))

  out <- validate_sitemap(path, inspect_pages = TRUE)
  page_rows <- out[out$layer == "page", ]
  expect_identical(page_rows$code, "PAGE_CANONICAL_MISMATCH")
  expect_identical(ncol(out), 10L)
})

# ---- content-type and resolution edges ---------------------------------------

test_that("a response with no Content-Type is treated as HTML", {
  # A usable body with no declared type is parsed as markup, so it can still be
  # `absent` of a canonical rather than not_applicable.
  expect_true(page_content_is_html(pc_art(headers = list())))
  expect_true(page_content_is_html(pc_art()))
  expect_false(page_content_is_html(
    pc_art(headers = list("Content-Type" = "application/pdf"))
  ))
})

test_that("an empty or blank canonical target does not resolve", {
  base <- "https://example.com/a"
  expect_identical(page_canonical_resolve("", base), NA_character_)
  expect_identical(page_canonical_resolve("   ", base), NA_character_)
  expect_identical(page_canonical_resolve(NA_character_, base), NA_character_)
})

# ---- Link header parsing -----------------------------------------------------

test_that("a Link segment with no bracketed URI is skipped", {
  # Only `<uri>; params` segments are link-values; anything else is ignored
  # rather than treated as a target.
  expect_length(
    page_link_header_canonicals(list(Link = "notalink; rel=canonical")),
    0L
  )

  # A malformed segment does not suppress a well-formed one alongside it.
  mixed <- "badseg; rel=canonical, <https://example.com/c>; rel=\"canonical\""
  expect_identical(
    page_link_header_canonicals(list(Link = mixed)),
    "https://example.com/c"
  )
})

test_that("a canonical declared alongside another rel token is honored", {
  # Regression: `rel` was substring-matched, so a valid canonical declaration
  # only counted when `canonical` came FIRST. RFC 8288 3.3 makes the token
  # order insignificant, and dropping the target manufactures a
  # PAGE_CANONICAL_MISSING on a page that declares one.
  for (rel in c("canonical alternate", "alternate canonical")) {
    header <- sprintf("<https://example.com/c>; rel=\"%s\"", rel)
    expect_identical(
      page_link_header_canonicals(list(Link = header)),
      "https://example.com/c"
    )
  }

  art <- pc_art(
    headers = list(
      "Content-Type" = "text/html",
      Link = "<https://example.com/a>; rel=\"alternate canonical\""
    )
  )
  expect_identical(page_canonical_extract(art)$status, "observed")
  # It agrees with the advertised loc, so no finding — not a false MISSING.
  expect_identical(nrow(page_canonical_findings(pc_run(art))), 0L)
})

test_that("a canonical-prefixed relation type does not invent a target", {
  # Regression: the trailing `"?` was optional and nothing anchored the token's
  # end, so `rel="canonical-ish"` was read as a canonical declaration and
  # produced a PAGE_CANONICAL_MISMATCH pointing at an unrelated link.
  header <- "<https://example.com/unrelated>; rel=\"canonical-ish\""
  expect_length(page_link_header_canonicals(list(Link = header)), 0L)

  art <- pc_art(headers = list("Content-Type" = "text/html", Link = header))
  expect_identical(page_canonical_extract(art)$status, "absent")
  out <- page_canonical_findings(pc_run(art))
  expect_identical(out$code, "PAGE_CANONICAL_MISSING")
})

test_that("every link-value of a multi-value Link header is consulted", {
  header <- paste(
    "<https://example.com/feed>; rel=\"alternate\"",
    "<https://example.com/c>; rel=\"canonical\"",
    sep = ", "
  )
  expect_identical(
    page_link_header_canonicals(list(Link = header)),
    "https://example.com/c"
  )
})

# ---- head parsing edges ------------------------------------------------------

test_that("an absent or unparseable body yields no canonical targets", {
  none <- list(base = "https://example.com/a", targets = character(0))
  expect_identical(page_html_canonicals(raw(0), "https://example.com/a"), none)

  # xml2's HTML parser accepts even binary junk, so the tryCatch guard is
  # pinned by forcing the parse to fail.
  testthat::local_mocked_bindings(
    read_html = function(...) stop("parse failed"),
    .package = "xml2"
  )
  expect_identical(
    page_html_canonicals(
      charToRaw(canonical_link("https://example.com/c")),
      "https://example.com/a"
    ),
    none
  )
})

test_that("a <base href> sets the resolution base, with a fallback", {
  usable <- page_html_canonicals(
    charToRaw(paste0(
      "<html><head><base href=\"/sub/\">",
      "<link rel=\"canonical\" href=\"c.html\">",
      "</head></html>"
    )),
    "https://example.com/a"
  )
  expect_identical(usable$base, "https://example.com/sub/")

  # An unresolvable <base href> falls back to the response final_url rather
  # than poisoning every relative target with NA.
  broken <- page_html_canonicals(
    charToRaw("<html><head><base href=\"://nonsense\"></head></html>"),
    "https://example.com/a"
  )
  expect_identical(broken$base, "https://example.com/a")
})

# ---- findings assembly -------------------------------------------------------

test_that("a run with no artifacts produces no canonical findings", {
  empty <- structure(
    list(artifacts = list(), coverage = list()),
    class = "page_inspection_run"
  )

  out <- page_canonical_findings(empty)
  expect_identical(nrow(out), 0L)
  expect_identical(out, empty_page_findings())
})

test_that("a subject loc with no fetched artifact is skipped", {
  art <- pc_art(canonical_link("https://example.com/a"))
  absent <- "https://example.com/never-fetched"
  subjects <- list(
    loc = c(art$requested_url, absent),
    base = list(
      sitemap_subject_ref(art$requested_url),
      sitemap_subject_ref(absent)
    )
  )

  # The unfetched loc is skipped rather than erroring on a NULL artifact.
  expect_identical(nrow(page_canonical_findings(pc_run(art), subjects)), 0L)
})
