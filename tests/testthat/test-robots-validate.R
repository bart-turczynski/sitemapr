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
  local_mocked_bindings(robotstxtr_available = function() TRUE)
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
