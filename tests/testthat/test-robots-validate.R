# Tests for the robots.txt allow/disallow finding-producer
# (R/robots-validate.R) and its wiring into validate_sitemap()
# (check_robots = TRUE). The robotstxtr engine's HTTP fetch is mocked with
# httr2::with_mocked_responses so every test runs OFFLINE: the mock serves a
# robots.txt body (or a status) keyed on the request host, exercising the four
# fetch outcomes (rule match, allow-all body, 404 missing, 5xx failure).

# A mocked robots.txt transport. Each origin's /robots.txt gets a deterministic
# response keyed on its host: `disallow.example` blocks `/private`,
# `allow.example` serves a body that allows everything, `missing.example` 404s
# (allow-all), and `boom.example` 500s (indeterminate).
mock_robots <- function(req) {
  host <- httr2::url_parse(req$url)$hostname
  if (identical(host, "disallow.example")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      body = charToRaw("User-agent: *\nDisallow: /private\n")
    ))
  }
  if (identical(host, "allow.example")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      body = charToRaw("User-agent: *\nDisallow: /other\n")
    ))
  }
  if (identical(host, "missing.example")) {
    return(httr2::response(status_code = 404L, url = req$url, body = raw(0)))
  }
  httr2::response(status_code = 503L, url = req$url, body = raw(0))
}

with_robots <- function(code) {
  httr2::with_mocked_responses(mock_robots, code)
}

test_that("a disallowed URL yields a ROBOTS_DISALLOWED warning with evidence", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots(
    "https://disallow.example/private/page",
    user_agent = "*",
    base = "sitemap://disallow.example/sitemap.xml"
  ))

  expect_identical(nrow(f), 1L)
  expect_identical(f$code, "ROBOTS_DISALLOWED")
  expect_identical(f$severity, "warning")
  expect_identical(f$layer, "robots")
  expect_identical(f$subject_type, "page-url")
  expect_identical(
    f$subject_ref,
    paste0(
      "sitemap://disallow.example/sitemap.xml",
      "#page-url:https://disallow.example/private/page"
    )
  )
  # Evidence carries the matched robots.txt rule + line.
  expect_match(f$evidence[[1L]]$excerpt, "disallow: /private")
  expect_identical(f$evidence[[1L]]$line, 2L)
})

test_that("an allowed URL and a 404 (allow-all) robots.txt yield no rows", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots(
    c("https://allow.example/ok", "https://missing.example/anything"),
    user_agent = "*",
    base = "sitemap://s.xml"
  ))
  expect_identical(nrow(f), 0L)
})

test_that("an unfetchable robots.txt yields ROBOTS_INDETERMINATE info", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots(
    "https://boom.example/page",
    user_agent = "*",
    base = "sitemap://boom.example/sitemap.xml"
  ))
  expect_identical(nrow(f), 1L)
  expect_identical(f$code, "ROBOTS_INDETERMINATE")
  expect_identical(f$severity, "info")
  expect_identical(f$layer, "robots")
})

test_that("non-absolute and non-http locs are skipped (not tested)", {
  skip_if_not_installed("robotstxtr")
  # No mock needed: relative / non-http locs never reach the fetcher.
  f <- validate_robots(
    c("/relative/path", "ftp://host/x", "mailto:a@b.com", NA_character_, ""),
    user_agent = "*",
    base = "sitemap://s.xml"
  )
  expect_identical(nrow(f), 0L)
})

test_that("duplicate locs are checked once", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots(
    c(
      "https://disallow.example/private/a",
      "https://disallow.example/private/a"
    ),
    user_agent = "*",
    base = "sitemap://disallow.example/sitemap.xml"
  ))
  expect_identical(nrow(f), 1L)
})

test_that("empty loc input yields an empty findings tibble", {
  f <- validate_robots(character(0), user_agent = "*", base = "sitemap://s.xml")
  expect_identical(nrow(f), 0L)
  expect_identical(f$layer, character(0))
})

# --- resolve_robots_ua(): the optional-dependency guard -------------------

test_that("resolve_robots_ua returns NULL when the check is off", {
  expect_null(resolve_robots_ua(FALSE, "*"))
})

test_that("resolve_robots_ua returns the UA when robotstxtr is available", {
  # The contract gate is stubbed too, so the test stays hermetic: it asserts
  # the UA passthrough, not whether the sibling happens to be installed.
  local_mocked_bindings(
    robotstxtr_available = function() TRUE,
    robotstxtr_engine_contract = function() NULL
  )
  expect_identical(resolve_robots_ua(TRUE, "Googlebot"), "Googlebot")
})

test_that("resolve_robots_ua warns (classed) and skips when engine absent", {
  local_mocked_bindings(robotstxtr_available = function() FALSE)
  expect_warning(
    ua <- resolve_robots_ua(TRUE, "*"),
    class = "sitemapr_robots_unavailable"
  )
  expect_null(ua)
  # The message names the install command.
  w <- tryCatch(
    resolve_robots_ua(TRUE, "*"),
    sitemapr_robots_unavailable = function(cnd) cnd
  )
  expect_match(conditionMessage(w), "pak::pak", fixed = TRUE)
})

# --- Integration through validate_sitemap(check_robots = TRUE) ------------

# A local urlset file advertising URLs across the mocked origins. A local source
# needs no sitemap fetch, so with_mocked_responses only intercepts the
# per-origin robots.txt requests the robots check makes.
write_urlset <- function(locs) {
  body <- paste0("<url><loc>", locs, "</loc></url>", collapse = "")
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    body,
    "</urlset>"
  )
  path <- withr::local_tempfile(fileext = ".xml", .local_envir = parent.frame())
  writeLines(xml, path)
  path
}

test_that("validate_sitemap(check_robots = TRUE) emits robots-layer findings", {
  skip_if_not_installed("robotstxtr")
  path <- write_urlset(c(
    "https://disallow.example/private/x",
    "https://allow.example/ok",
    "https://boom.example/y"
  ))

  f <- with_robots(
    validate_sitemap(path, mode = "non-strict", check_robots = TRUE)
  )

  robots <- f[f$layer == "robots", , drop = FALSE]
  expect_setequal(robots$code, c("ROBOTS_DISALLOWED", "ROBOTS_INDETERMINATE"))
  expect_true(all(robots$subject_type == "page-url"))
})

test_that("the default call runs no robots check (no robots-layer rows)", {
  path <- write_urlset("https://disallow.example/private/x")
  f <- validate_sitemap(path, mode = "non-strict")
  expect_identical(sum(f$layer == "robots"), 0L)
})

# ---- engine-contract gate (SITE-ykagmqdd) ------------------------------------

test_that("the pinned contract id matches the installed robotstxtr", {
  skip_if_not_installed("robotstxtr")
  contract <- robotstxtr_engine_contract()
  expect_identical(contract$contract_id, robotstxtr_contract_id())
  # The gate returns the whole public contract object, not just the id.
  expect_s3_class(contract, "robots_engine_contract_v1")
})

test_that("a contract id that has moved on aborts loudly", {
  skip_if_not_installed("robotstxtr")
  local_mocked_bindings(
    robotstxtr_contract_id = function() "robotstxtr.engine-aware/v99"
  )
  expect_error(
    robotstxtr_engine_contract(),
    class = "sitemapr_robotstxtr_contract"
  )
  # The message names both sides of the mismatch and the fix.
  cnd <- tryCatch(
    robotstxtr_engine_contract(),
    sitemapr_robotstxtr_contract = function(cnd) cnd
  )
  expect_match(conditionMessage(cnd), "v99", fixed = TRUE)
  expect_match(conditionMessage(cnd), "pak::pak", fixed = TRUE)
})

test_that("an incompatible engine aborts rather than skipping silently", {
  skip_if_not_installed("robotstxtr")
  local_mocked_bindings(
    robotstxtr_contract_id = function() "robotstxtr.engine-aware/v99"
  )
  # Contrast with the ABSENT engine, which warns and degrades gracefully: a
  # present-but-wrong engine must not silently produce robots findings.
  expect_error(
    resolve_robots_ua(TRUE, "*"),
    class = "sitemapr_robotstxtr_contract"
  )
})

test_that("matcher capability is read through the public accessor", {
  skip_if_not_installed("robotstxtr")
  cap <- robotstxtr_matcher_capability()
  expect_false(is.null(cap))
  # Matches what the public contract object carries (no internal reach-in).
  expect_identical(cap, robotstxtr_engine_contract()$matcher_capability)
})

test_that("a stale build with the right id but no capability aborts", {
  skip_if_not_installed("robotstxtr")
  # Reproduces the pre-#43 robotstxtr: SAME contract id, older schema, and no
  # matcher_capability. The contract id alone cannot discriminate this, so the
  # gate must catch it on the capability field.
  local_mocked_bindings(
    robotstxtr_engine_contract_raw = function() {
      list(
        contract_id = robotstxtr_contract_id(),
        schema_revision = "2026-07-17.1"
      )
    }
  )
  cnd <- tryCatch(
    robotstxtr_engine_contract(),
    sitemapr_robotstxtr_contract = function(cnd) cnd
  )
  expect_s3_class(cnd, "sitemapr_robotstxtr_contract")
  # The message names the stale schema and the one sitemapr needs.
  expect_match(conditionMessage(cnd), "2026-07-17.1", fixed = TRUE)
  expect_match(
    conditionMessage(cnd),
    robotstxtr_contract_schema(),
    fixed = TRUE
  )
})

# ---- document-level check: the sitemap itself (§0.6, SITE-zfggbgsj) ---------

test_that("a disallowed sitemap document yields ROBOTS_SITEMAP_DISALLOWED", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots_sitemap(
    "https://disallow.example/private/sitemap.xml",
    user_agent = "*",
    base = "sitemap://disallow.example/private/sitemap.xml"
  ))

  expect_identical(nrow(f), 1L)
  expect_identical(f$code, "ROBOTS_SITEMAP_DISALLOWED")
  expect_identical(f$severity, "warning")
  expect_identical(f$layer, "robots")
  # Source-scoped: the document itself, so the ref carries no fragment.
  expect_identical(f$subject_type, "source")
  expect_identical(
    f$subject_ref,
    "sitemap://disallow.example/private/sitemap.xml"
  )
  expect_match(f$evidence[[1L]]$excerpt, "disallow: /private")
  expect_identical(f$evidence[[1L]]$line, 2L)
})

test_that("an allowed sitemap document yields no row", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots_sitemap(
    "https://allow.example/sitemap.xml",
    user_agent = "*",
    base = "sitemap://allow.example/sitemap.xml"
  ))
  expect_identical(nrow(f), 0L)
})

test_that("an undecidable robots.txt yields no document-level row", {
  skip_if_not_installed("robotstxtr")
  # There is deliberately no source-scoped analog of ROBOTS_INDETERMINATE.
  f <- with_robots(validate_robots_sitemap(
    "https://boom.example/sitemap.xml",
    user_agent = "*",
    base = "sitemap://boom.example/sitemap.xml"
  ))
  expect_identical(nrow(f), 0L)
})

test_that("a non-http(s) sitemap source is skipped (no robots.txt governs)", {
  skip_if_not_installed("robotstxtr")
  # A local file path never reaches the fetcher, so no mock is needed.
  f <- validate_robots_sitemap(
    "/var/tmp/sitemap.xml",
    user_agent = "*",
    base = "sitemap:///var/tmp/sitemap.xml"
  )
  expect_identical(nrow(f), 0L)
})

test_that("a non-legacy robots context is rejected, not silently empty", {
  skip_if_not_installed("robotstxtr")
  facts <- with_robots(robots_evaluate_facts(
    "https://disallow.example/private/sitemap.xml",
    context = robots_context_preset("rfc9309")
  ))
  expect_error(
    robots_sitemap_findings_from_facts(facts, base = "sitemap://s.xml"),
    class = "sitemapr_robots_findings_unsupported"
  )
})

# A transport mock that serves a urlset for any `/sitemap.xml` path and defers
# to mock_robots for the robots.txt requests, so the document-level check can be
# exercised end-to-end through validate_sitemap() on a REMOTE sitemap.
mock_sitemap_and_robots <- function(req) {
  path <- httr2::url_parse(req$url)$path
  if (identical(basename(path), "sitemap.xml")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list(`content-type` = "application/xml"),
      body = charToRaw(paste0(
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
        "<url><loc>https://allow.example/ok</loc></url></urlset>"
      ))
    ))
  }
  mock_robots(req)
}

test_that("validate_sitemap flags a sitemap its own robots.txt disallows", {
  skip_if_not_installed("robotstxtr")
  f <- httr2::with_mocked_responses(
    mock_sitemap_and_robots,
    validate_sitemap(
      "https://disallow.example/private/sitemap.xml",
      mode = "non-strict",
      check_robots = TRUE
    )
  )

  doc <- f[f$code == "ROBOTS_SITEMAP_DISALLOWED", , drop = FALSE]
  expect_identical(nrow(doc), 1L)
  expect_identical(doc$subject_type, "source")
  expect_identical(
    doc$subject_ref,
    "sitemap://disallow.example/private/sitemap.xml"
  )
})

test_that("the document check stays off on a default call", {
  skip_if_not_installed("robotstxtr")
  f <- httr2::with_mocked_responses(
    mock_sitemap_and_robots,
    validate_sitemap(
      "https://disallow.example/private/sitemap.xml",
      mode = "non-strict"
    )
  )
  expect_identical(sum(f$code == "ROBOTS_SITEMAP_DISALLOWED"), 0L)
})
