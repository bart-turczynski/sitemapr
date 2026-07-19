# Offline tests for the page-transport finding producer + coverage metadata
# (R/page-findings.R; Layer E, Contract D / E.1f).
#
# The outcome->code mapping, precedence, one-finding-per-URL, and registry
# severities are exercised by constructing page_fetch_artifacts directly (no
# network). The validate integration (byte-identical off; coverage attr on) is
# exercised over a LOCAL sitemap file with the page fetches httr2-mocked, so the
# suite is CRAN-safe.

# Local httr2 mock builders (helpers in another test file are not visible here).
pf_mock_status <- function(status, url) {
  httr2::response(status_code = as.integer(status), url = url)
}
pf_mock_ok <- function(url) {
  httr2::response(
    status_code = 200L,
    url = url,
    headers = list("Content-Type" = "text/html; charset=UTF-8"),
    body = charToRaw("<html><head></head></html>")
  )
}

# One hop record shaped like page_hop_record().
pf_hop <- function(url, status, location = NA_character_) {
  list(url = url, status = as.integer(status), location = location)
}

# A page_fetch_artifact for one outcome. `hops` defaults to a single terminal
# 200 hop; pass an explicit trail for redirect / status cases.
pf_art <- function(
  outcome,
  requested = "https://example.com/a",
  final = requested,
  hops = list(pf_hop(requested, 200L))
) {
  page_fetch_artifact(
    requested_url = requested,
    final_url = final,
    hops = hops,
    outcome = outcome,
    request_user_agent = "inspector/test"
  )
}

# A page_inspection_run wrapping artifacts keyed by their requested URL, each
# advertised by exactly that URL unless `advertised` overrides it.
pf_run <- function(arts, advertised = NULL, coverage = list()) {
  entries <- list()
  for (i in seq_along(arts)) {
    art <- arts[[i]]
    key <- art$requested_url
    adv <- if (is.null(advertised)) key else advertised[[i]]
    entries[[key]] <- list(fetch_url = key, advertised = adv, artifact = art)
  }
  structure(
    list(artifacts = entries, coverage = coverage),
    class = "page_inspection_run"
  )
}

# A terminal-status http_status artifact (a single hop carrying `status`).
pf_status_art <- function(status, url = "https://example.com/a") {
  pf_art("http_status", requested = url, hops = list(pf_hop(url, status)))
}

# Findings for a single artifact, self-anchored (default subjects).
pf_findings_for <- function(art) {
  page_transport_findings(pf_run(list(art)))
}

# ---- outcome -> code mapping -------------------------------------------------

test_that("http_status maps to PAGE_STATUS_ERROR at error severity", {
  art <- pf_status_art(404L)
  f <- pf_findings_for(art)
  expect_identical(nrow(f), 1L)
  expect_identical(f$code, "PAGE_STATUS_ERROR")
  expect_identical(f$severity, "error")
  expect_identical(f$layer, "page")
  expect_identical(f$subject_type, "page-url")
  # Baseline reads the status off the excerpt (no context column survives).
  expect_identical(f$evidence[[1L]]$excerpt, "HTTP 404")
})

test_that("a resolved redirect (2xx, final != requested) maps to REDIRECT", {
  art <- pf_art(
    "usable_body",
    requested = "https://example.com/a",
    final = "https://example.com/b",
    hops = list(
      pf_hop("https://example.com/a", 301L, "https://example.com/b"),
      pf_hop("https://example.com/b", 200L)
    )
  )
  f <- pf_findings_for(art)
  expect_identical(f$code, "PAGE_STATUS_REDIRECT")
  expect_identical(f$severity, "warning")
  expect_match(f$message, "redirects to https://example.com/b")
})

test_that("a same-canonical redirect is NOT a mismatch (no finding)", {
  # Only default port / host case changed -> canonical-identical: no row.
  art <- pf_art(
    "usable_body",
    requested = "https://example.com/a",
    final = "https://EXAMPLE.com:443/a"
  )
  expect_identical(nrow(pf_findings_for(art)), 0L)
})

test_that("redirect_over_budget maps to PAGE_REDIRECT_CHAIN at info", {
  art <- pf_art(
    "redirect_over_budget",
    final = NA_character_,
    hops = list(
      pf_hop("https://example.com/a", 301L, "https://example.com/b"),
      pf_hop("https://example.com/b", 301L, "https://example.com/c")
    )
  )
  f <- pf_findings_for(art)
  expect_identical(f$code, "PAGE_REDIRECT_CHAIN")
  expect_identical(f$severity, "info")
})

test_that("transport_fail / incomplete / http_protocol_error -> FETCH_FAILED", {
  for (outcome in c("transport_fail", "incomplete", "http_protocol_error")) {
    art <- pf_art(outcome, final = NA_character_, hops = list())
    f <- pf_findings_for(art)
    expect_identical(f$code, "PAGE_FETCH_FAILED")
    expect_identical(f$severity, "error")
    expect_identical(f$evidence[[1L]]$excerpt, outcome)
  }
})

test_that("safety_refused maps generically to PAGE_SSRF_BLOCKED", {
  art <- pf_art("safety_refused", final = NA_character_, hops = list())
  f <- pf_findings_for(art)
  expect_identical(f$code, "PAGE_SSRF_BLOCKED")
  expect_identical(f$severity, "error")
})

test_that("usable_body / partial / not_applicable emit no transport finding", {
  for (outcome in c("usable_body", "partial", "not_applicable")) {
    art <- pf_art(outcome)
    expect_identical(nrow(pf_findings_for(art)), 0L)
  }
})

# ---- precedence: safety_refused > http_status > redirect ---------------------

test_that("a safety refusal on a redirecting fetch stays SSRF (precedence)", {
  # final_url differs, but the outcome is safety_refused -> SSRF wins.
  art <- pf_art(
    "safety_refused",
    requested = "https://example.com/a",
    final = "https://evil.example/b",
    hops = list(pf_hop("https://example.com/a", 301L, "https://evil.example/b"))
  )
  expect_identical(pf_findings_for(art)$code, "PAGE_SSRF_BLOCKED")
})

test_that("a terminal error after a redirect stays STATUS_ERROR (precedence)", {
  art <- pf_art(
    "http_status",
    requested = "https://example.com/a",
    final = "https://example.com/b",
    hops = list(
      pf_hop("https://example.com/a", 302L, "https://example.com/b"),
      pf_hop("https://example.com/b", 404L)
    )
  )
  expect_identical(pf_findings_for(art)$code, "PAGE_STATUS_ERROR")
})

# ---- at most one finding per URL, per advertising subject_ref ----------------

test_that("one artifact yields at most one transport finding per URL", {
  art <- pf_status_art(500L)
  expect_identical(nrow(pf_findings_for(art)), 1L)
})

test_that("a URL advertised by several sitemaps anchors one finding each", {
  art <- pf_status_art(404L)
  run <- pf_run(list(art))
  subjects <- list(
    loc = c("https://example.com/a", "https://example.com/a"),
    base = c("sitemap://one.example/s.xml", "sitemap://two.example/s.xml")
  )
  f <- page_transport_findings(run, subjects = subjects)
  expect_identical(nrow(f), 2L)
  expect_setequal(
    f$subject_ref,
    c(
      "sitemap://one.example/s.xml#page-url:https://example.com/a",
      "sitemap://two.example/s.xml#page-url:https://example.com/a"
    )
  )
})

# ---- registry-conformant severities ------------------------------------------

test_that("every emitted transport severity conforms to the registry", {
  # The registry rows 76-80 pin these severities (findings-registry.csv). The
  # CSV lives in docs/ (not built into the package), and the drift guard
  # (tools/check-findings-registry.R) enforces the code<->registry match at the
  # verify gate; here we pin the severities the producer must emit so a drift in
  # page_code_severity() fails a CRAN-safe unit test too.
  expected <- c(
    PAGE_FETCH_FAILED = "error",
    PAGE_SSRF_BLOCKED = "error",
    PAGE_STATUS_ERROR = "error",
    PAGE_STATUS_REDIRECT = "warning",
    PAGE_REDIRECT_CHAIN = "info"
  )
  for (code in names(expected)) {
    expect_identical(page_code_severity(code), unname(expected[[code]]))
  }
})

# ---- engine-mode structured context merge ------------------------------------

test_that("page context merges under an engine ruleset, drops on baseline", {
  art <- pf_status_art(404L)
  part <- page_transport_findings(pf_run(list(art)))

  baseline <- assemble_findings(list(part), "strict", ruleset = NULL)
  expect_false("context" %in% names(baseline))

  spec <- list(
    ruleset = "google",
    ruleset_revision = "test",
    context = list(submission_channel = "unknown")
  )
  engine <- assemble_findings(list(part), "strict", ruleset = spec)
  expect_true("context" %in% names(engine))
  ctx <- engine$context[[1L]]
  expect_identical(ctx$page_status, 404L)
  expect_identical(ctx$page_outcome, "http_status")
  # The uniform ruleset axis is preserved alongside the page context.
  expect_identical(ctx$submission_channel, "unknown")
})

# ---- coverage attribute shape ------------------------------------------------

test_that("page_coverage_attr is versioned + batch-wide over coverage", {
  cov <- list(
    eligible = 3L,
    deduplicated = 2L,
    selected = 2L,
    attempted = 2L,
    completed = 1L,
    partial = 0L,
    caps_hit = character(0)
  )
  a <- page_coverage_attr(cov)
  expect_identical(a$schema_version, page_coverage_schema_version())
  expect_identical(a$scope, "batch")
  expect_identical(a$eligible, 3L)
  expect_identical(a$deduplicated, 2L)
  expect_identical(a$caps_hit, character(0))
})

# ---- validate integration ----------------------------------------------------

# Write a one-URL local urlset advertising `loc`.
pf_local_sitemap <- function(loc = "https://example.com/a") {
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

test_that("inspect_pages = FALSE is byte-identical and has no coverage attr", {
  path <- pf_local_sitemap()
  off <- validate_sitemap(path)
  explicit_off <- validate_sitemap(path, inspect_pages = FALSE)
  expect_identical(off, explicit_off)
  expect_null(attr(off, "page_coverage"))
  expect_identical(ncol(off), 10L)
  expect_false("page" %in% off$layer)
})

test_that("inspect_pages = TRUE fetches, stamps coverage, emits page rows", {
  path <- pf_local_sitemap("https://example.com/a")
  httr2::local_mocked_responses(
    list(pf_mock_status(404L, "https://example.com/a"))
  )

  out <- validate_sitemap(path, inspect_pages = TRUE)
  cov <- attr(out, "page_coverage")
  expect_false(is.null(cov))
  expect_identical(cov$schema_version, page_coverage_schema_version())
  expect_identical(cov$scope, "batch")
  expect_identical(cov$eligible, 1L)

  page_rows <- out[out$layer == "page", ]
  expect_identical(nrow(page_rows), 1L)
  expect_identical(page_rows$code, "PAGE_STATUS_ERROR")
  # Anchored to the advertising sitemap's page-url subject_ref.
  expect_match(
    page_rows$subject_ref,
    "#page-url:https://example.com/a",
    fixed = TRUE
  )
  # Still the pinned ten columns (coverage rides an attribute, not a column).
  expect_identical(ncol(out), 10L)
})

test_that("inspect_pages = TRUE with an all-clean page emits no page rows", {
  path <- pf_local_sitemap("https://example.com/a")
  httr2::local_mocked_responses(list(pf_mock_ok("https://example.com/a")))

  out <- validate_sitemap(path, inspect_pages = TRUE)
  expect_false("page" %in% out$layer)
  # Coverage is still present: the run happened, it was simply clean.
  cov <- attr(out, "page_coverage")
  expect_identical(cov$completed, 1L)
})
