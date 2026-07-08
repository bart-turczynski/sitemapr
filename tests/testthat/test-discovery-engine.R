# Unit tests for the discovery engine (R/discovery.R, discover_candidates()).
# Offline: candidate fetches go through httr2::local_mocked_responses, so the
# real network is never hit (CRAN-safe).

urlset_doc <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    "</urlset>"
  )
}

# A mock dispatcher over a named URL->status map. Bodies default to a small
# urlset for 200s. Every requested URL is recorded in `log_env$urls`.
mock_server <- function(status_map, log_env, body_map = list()) {
  function(req) {
    log_env$urls <- c(log_env$urls, req$url)
    status <- status_map[[req$url]]
    if (is.null(status)) {
      status <- 404L
    }
    body <- body_map[[req$url]]
    if (is.null(body)) {
      body <- urlset_doc("https://x/1")
    }
    httr2::response(
      status_code = status,
      url = req$url,
      headers = list("Content-Type" = "application/xml"),
      body = charToRaw(body)
    )
  }
}

test_that("a 200 promotes a candidate to accepted with a catalog reason", {
  log_env <- new.env()
  httr2::local_mocked_responses(
    mock_server(list("https://example.com/sitemap.xml" = 200L), log_env)
  )
  res <- discover_candidates("https://example.com")
  row <- res[res$candidate_url == "https://example.com/sitemap.xml", ]
  expect_identical(row$status, "accepted")
  expect_identical(row$reason, "catalog-generic")
  expect_identical(row$http_status, 200L)
})

test_that("a CMS hit records the CMS source in the reason", {
  log_env <- new.env()
  httr2::local_mocked_responses(
    mock_server(list("https://example.com/wp-sitemap.xml" = 200L), log_env)
  )
  res <- discover_candidates("https://example.com")
  row <- res[res$candidate_url == "https://example.com/wp-sitemap.xml", ]
  expect_identical(row$status, "accepted")
  expect_identical(row$reason, "catalog-wordpress")
})

test_that("a 404 produces a rejected not-found candidate, never an error", {
  log_env <- new.env()
  httr2::local_mocked_responses(mock_server(list(), log_env)) # all 404
  expect_no_error(res <- discover_candidates("https://example.com"))
  expect_true(all(res$status == "rejected"))
  expect_true(all(res$reason == "not-found"))
})

test_that("the expected non-2xx warning is suppressed during discovery", {
  log_env <- new.env()
  httr2::local_mocked_responses(mock_server(list(), log_env))
  expect_no_warning(discover_candidates("https://example.com"))
})

test_that("a non-404 HTTP error rejects with an http-<status> reason", {
  log_env <- new.env()
  httr2::local_mocked_responses(
    mock_server(list("https://example.com/sitemap.xml" = 500L), log_env)
  )
  res <- discover_candidates("https://example.com")
  row <- res[res$candidate_url == "https://example.com/sitemap.xml", ]
  expect_identical(row$status, "rejected")
  expect_identical(row$reason, "http-500")
})

test_that("a mixed server yields both accepted and rejected rows", {
  log_env <- new.env()
  httr2::local_mocked_responses(
    mock_server(list("https://example.com/sitemap.xml" = 200L), log_env)
  )
  res <- discover_candidates("https://example.com")
  expect_true(any(res$status == "accepted"))
  expect_true(any(res$status == "rejected"))
})

test_that("every candidate row carries guessed-path provenance", {
  log_env <- new.env()
  httr2::local_mocked_responses(mock_server(list(), log_env))
  res <- discover_candidates("https://example.com")
  expect_true(all(res$provenance == "guessed-path"))
})

test_that("the records attribute is parallel; accepted records carry a body", {
  log_env <- new.env()
  httr2::local_mocked_responses(
    mock_server(list("https://example.com/sitemap.xml" = 200L), log_env)
  )
  res <- discover_candidates("https://example.com")
  records <- attr(res, "records")
  expect_length(records, nrow(res))
  acc_idx <- which(res$candidate_url == "https://example.com/sitemap.xml")
  expect_false(is.null(attr(records[[acc_idx]], "body")))
})

test_that("robots.txt is requested during discovery by default", {
  log_env <- new.env()
  httr2::local_mocked_responses(mock_server(list(), log_env))
  discover_candidates("https://example.com")
  expect_true(any(grepl("/robots.txt", log_env$urls, fixed = TRUE)))
})

test_that("use_robots = FALSE suppresses the robots.txt request", {
  log_env <- new.env()
  httr2::local_mocked_responses(mock_server(list(), log_env))
  discover_candidates("https://example.com", use_robots = FALSE)
  expect_false(any(grepl("/robots.txt", log_env$urls, fixed = TRUE)))
})

test_that("an SSRF block becomes a rejected 'blocked' candidate", {
  testthat::local_mocked_bindings(
    fetch_source = function(...) {
      rlang::abort("blocked", class = "sitemapr_ssrf_blocked")
    }
  )
  res <- discover_candidates("https://example.com")
  expect_true(all(res$status == "rejected"))
  expect_true(all(res$reason == "blocked"))
  expect_true(all(is.na(res$http_status)))
})

test_that("a transport abort becomes a rejected unreachable candidate", {
  testthat::local_mocked_bindings(
    fetch_source = function(...) {
      rlang::abort("timed out", class = "sitemapr_timeout")
    }
  )
  res <- discover_candidates("https://example.com")
  expect_true(all(res$status == "rejected"))
  expect_true(all(res$reason == "unreachable"))
})

test_that("classify_candidate marks a statusless errored record unreachable", {
  # A fetch record that carries an error_class but no HTTP status (e.g. a
  # connection-level failure surfaced as a record rather than an abort) is a
  # rejected, unreachable candidate.
  rec <- list(error_class = "sitemapr_timeout", status = NA_integer_)
  out <- classify_candidate("generic", "robots", rec)
  expect_identical(out$status, "rejected")
  expect_identical(out$reason, "unreachable")
  expect_true(is.na(out$http_status))
})

test_that("discover_candidates caps candidates before fetch", {
  log_env <- new.env()
  httr2::local_mocked_responses(mock_server(list(), log_env))

  res <- discover_candidates(
    "https://example.com",
    limits = discovery_limits(max_candidates = 2L),
    use_robots = FALSE
  )

  expect_identical(nrow(res), 2L)
  expect_length(log_env$urls, 2L)
  expect_identical(
    res$candidate_url,
    c(
      "https://example.com/sitemap.xml",
      "https://example.com/sitemap_index.xml"
    )
  )
})
