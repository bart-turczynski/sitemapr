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
