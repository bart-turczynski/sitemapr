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
    base = "https://disallow.example/sitemap.xml"
  ))

  expect_identical(nrow(f), 1L)
  expect_identical(f$code, "ROBOTS_DISALLOWED")
  expect_identical(f$severity, "warning")
  expect_identical(f$layer, "robots")
  expect_identical(f$subject_type, "page-url")
  expect_identical(
    f$subject_ref,
    paste0(
      "https://disallow.example/sitemap.xml",
      "#page-url:https%3A%2F%2Fdisallow.example%2Fprivate%2Fpage"
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
    base = "https://s.xml"
  ))
  expect_identical(nrow(f), 0L)
})

test_that("an unfetchable robots.txt yields ROBOTS_INDETERMINATE info", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots(
    "https://boom.example/page",
    user_agent = "*",
    base = "https://boom.example/sitemap.xml"
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
    base = "https://s.xml"
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
    base = "https://disallow.example/sitemap.xml"
  ))
  expect_identical(nrow(f), 1L)
})

test_that("empty loc input yields an empty findings tibble", {
  f <- validate_robots(character(0), user_agent = "*", base = "https://s.xml")
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

test_that("the gated contract carries a matcher capability table", {
  skip_if_not_installed("robotstxtr")
  # Read off the public contract object, as the per-engine consumer
  # (R/page-robots-trap.R) does -- no internal reach-in.
  expect_false(is.null(robotstxtr_engine_contract()$matcher_capability))
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

test_that("a stale build reporting no schema at all is named 'unknown'", {
  skip_if_not_installed("robotstxtr")
  # A build older still than the one above: right contract id, no capability,
  # and no `schema_revision` to quote back. The gate must still abort, naming
  # the schema it could not read rather than interpolating an empty string.
  local_mocked_bindings(
    robotstxtr_engine_contract_raw = function() {
      list(contract_id = robotstxtr_contract_id())
    }
  )
  cnd <- tryCatch(
    robotstxtr_engine_contract(),
    sitemapr_robotstxtr_contract = function(cnd) cnd
  )
  expect_s3_class(cnd, "sitemapr_robotstxtr_contract")
  expect_match(conditionMessage(cnd), "schema 'unknown'", fixed = TRUE)
})

test_that("an install without the contract accessor aborts loudly", {
  skip_if_not_installed("robotstxtr")
  # The oldest failure shape: a robotstxtr that does not expose
  # robots_engine_contract_v1() at all. Stood in by swapping the namespace the
  # gate reads, so no such build has to be installed to exercise it.
  local_mocked_bindings(
    robotstxtr_namespace = function() new.env(parent = emptyenv())
  )
  cnd <- tryCatch(
    robotstxtr_engine_contract_raw(),
    sitemapr_robotstxtr_contract = function(cnd) cnd
  )
  expect_s3_class(cnd, "sitemapr_robotstxtr_contract")
  # The message names the missing accessor, the required version, and the fix.
  expect_match(
    conditionMessage(cnd),
    "robots_engine_contract_v1()",
    fixed = TRUE
  )
  expect_match(conditionMessage(cnd), "0.2.0", fixed = TRUE)
  expect_match(conditionMessage(cnd), "pak::pak", fixed = TRUE)
})

# ---- document-level check: the sitemap itself (§0.6, SITE-zfggbgsj) ---------

test_that("a disallowed sitemap document yields ROBOTS_SITEMAP_DISALLOWED", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots_sitemap(
    "https://disallow.example/private/sitemap.xml",
    user_agent = "*",
    base = "https://disallow.example/private/sitemap.xml"
  ))

  expect_identical(nrow(f), 1L)
  expect_identical(f$code, "ROBOTS_SITEMAP_DISALLOWED")
  expect_identical(f$severity, "warning")
  expect_identical(f$layer, "robots")
  # Source-scoped: the document itself, so the ref carries no fragment.
  expect_identical(f$subject_type, "source")
  expect_identical(
    f$subject_ref,
    "https://disallow.example/private/sitemap.xml"
  )
  expect_match(f$evidence[[1L]]$excerpt, "disallow: /private")
  expect_identical(f$evidence[[1L]]$line, 2L)
})

test_that("an allowed sitemap document yields no row", {
  skip_if_not_installed("robotstxtr")
  f <- with_robots(validate_robots_sitemap(
    "https://allow.example/sitemap.xml",
    user_agent = "*",
    base = "https://allow.example/sitemap.xml"
  ))
  expect_identical(nrow(f), 0L)
})

test_that("an undecidable robots.txt yields no document-level row", {
  skip_if_not_installed("robotstxtr")
  # There is deliberately no source-scoped analog of ROBOTS_INDETERMINATE.
  f <- with_robots(validate_robots_sitemap(
    "https://boom.example/sitemap.xml",
    user_agent = "*",
    base = "https://boom.example/sitemap.xml"
  ))
  expect_identical(nrow(f), 0L)
})

test_that("a non-http(s) sitemap source is skipped (no robots.txt governs)", {
  skip_if_not_installed("robotstxtr")
  # A local file path never reaches the fetcher, so no mock is needed.
  f <- validate_robots_sitemap(
    "/var/tmp/sitemap.xml",
    user_agent = "*",
    base = "/var/tmp/sitemap.xml"
  )
  expect_identical(nrow(f), 0L)
})

test_that("a facts object with nothing evaluated yields no document row", {
  skip_if_not_installed("robotstxtr")
  # The document check short-circuits on non-consultable facts before it ever
  # reaches for the legacy view, so a NULL (robots evaluation off) and a facts
  # object carrying no urls both yield the empty producer shape, not an error.
  expect_identical(nrow(robots_sitemap_findings_from_facts(NULL)), 0L)
  expect_identical(
    nrow(robots_sitemap_findings_from_facts(
      structure(
        list(urls = character(0)),
        class = "sitemapr_robots_facts"
      )
    )),
    0L
  )
})

test_that("a non-legacy robots context is rejected, not silently empty", {
  skip_if_not_installed("robotstxtr")
  facts <- with_robots(robots_evaluate_facts(
    "https://disallow.example/private/sitemap.xml",
    context = robots_context_preset("rfc9309")
  ))
  expect_error(
    robots_sitemap_findings_from_facts(facts, base = "https://s.xml"),
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
    "https://disallow.example/private/sitemap.xml"
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

# ---- vectorized derivation column fallback (SITE-wlmodqza) -------------------

test_that("a results table missing a branch's columns reads as NA", {
  # The per-row builders only touched a column inside the branch that needed
  # it, so a table carrying one branch's columns was valid. The vectorized
  # pass reads every column, so the absent ones must fall back to NA rather
  # than error.
  rows <- data.frame(
    url = c("https://e.com/a", "https://e.com/b"),
    stringsAsFactors = FALSE
  )

  expect_identical(
    robots_result_col(rows, "fetch_outcome"),
    c(NA_character_, NA_character_)
  )
  expect_identical(
    robots_result_col(rows, "matched_line", NA_integer_),
    c(NA_integer_, NA_integer_)
  )
  # A present column is returned untouched.
  rows$fetch_outcome <- c("timeout", "ok")
  expect_identical(robots_result_col(rows, "fetch_outcome"), c("timeout", "ok"))
})

test_that("indeterminate-only results derive without matcher columns", {
  facts <- list(
    urls = "https://e.com/a",
    decision = "undetermined",
    legacy = list(
      results = data.frame(
        url = "https://e.com/a",
        allowed = NA,
        fetch_outcome = "timeout",
        stringsAsFactors = FALSE
      )
    )
  )

  out <- robots_findings_from_facts(facts, base = "https://s.xml")

  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "ROBOTS_INDETERMINATE")
  expect_identical(out$severity, "info")
  expect_match(out$message, "fetch outcome: timeout", fixed = TRUE)
})

# --- The engine-failure degrade (SITE-wgifofwc) ------------------------------
#
# A robots.txt carrying a NUL byte makes an old wholesale-installed robotstxtr
# abort in rawToChar(). One malformed robots.txt on a crawled origin must not
# abort the whole validation run, so the robots layer degrades and every other
# layer proceeds. Fixed upstream, but robotstxtr is Suggests and installed
# wholesale, so an already-installed build cannot be repaired by a version pin.
mock_sitemap_and_nul_robots <- function(req) {
  path <- httr2::url_parse(req$url)$path
  if (identical(basename(path), "robots.txt")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list(`content-type` = "text/plain"),
      body = c(
        charToRaw("User-agent: *\n"),
        as.raw(0),
        charToRaw("Disallow: /tmp\n")
      )
    ))
  }
  # A relative <loc>, so the non-robots layers have something to report: a run
  # that yields their findings proves it continued past the robots degrade
  # rather than merely returning early with an empty tibble.
  httr2::response(
    status_code = 200L,
    url = req$url,
    headers = list(`content-type` = "application/xml"),
    body = charToRaw(paste0(
      '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      "<url><loc>not-a-url</loc></url></urlset>"
    ))
  )
}

test_that("a NUL-bearing robots.txt degrades instead of aborting the run", {
  skip_if_not_installed("robotstxtr")
  run <- function() {
    httr2::with_mocked_responses(
      mock_sitemap_and_nul_robots,
      validate_sitemap(
        "https://nul.example/sitemap.xml",
        mode = "non-strict",
        check_robots = TRUE
      )
    )
  }

  # The engine's abort surfaces as a classed warning, not an error.
  expect_warning(f <- run(), class = "sitemapr_robots_engine_failed")

  # Validation still completed, and the other layers still reported.
  expect_s3_class(f, "tbl_df")
  expect_identical(
    sort(f$code),
    c("PROTOCOL_URL_NOT_ABSOLUTE", "SCHEMA_INVALID")
  )
  # The robots layer contributed nothing rather than a half-decided verdict.
  expect_false(any(startsWith(f$code, "ROBOTS_")))
})

test_that("the engine-failure warning quotes the cause and the upgrade hint", {
  skip_if_not_installed("robotstxtr")
  cnd <- simpleError("embedded nul in string: 'User-agent: *'")

  w <- tryCatch(
    robots_engine_failed_warn(cnd),
    warning = function(w) w
  )

  expect_s3_class(w, "sitemapr_robots_engine_failed")
  expect_match(conditionMessage(w), "embedded nul in string", fixed = TRUE)
  expect_match(conditionMessage(w), "pak::pak(", fixed = TRUE)
})
