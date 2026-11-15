# audit_sitemap(from = "root"): discovery findings (ADR-012; SITE-utjicjfu,
# SITE-zczpxmow). Offline: every fetch goes through
# httr2::local_mocked_responses.

root_urlset <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    "</urlset>"
  )
}

# A mock serving `body_map` (URL -> character or raw body). A URL in `status`
# answers with that status; one in `redirect` with a 301 to its value; one in
# `fail` raises a transport error and one in `timeout` an httr2 timeout; any
# other URL is a 404. Every request URL is recorded in `seen$urls`.
root_mock <- function(
  body_map,
  status = list(),
  fail = character(0),
  seen,
  redirect = list(),
  timeout = character(0)
) {
  seen$urls <- character(0)
  function(req) {
    seen$urls <- c(seen$urls, req$url)
    if (req$url %in% fail) {
      stop("connection refused")
    }
    if (req$url %in% timeout) {
      rlang::abort(
        "Timeout was reached",
        class = c("httr2_timeout", "httr2_failure", "httr2_error")
      )
    }
    to <- redirect[[req$url]]
    if (!is.null(to)) {
      return(httr2::response(
        status_code = 301L,
        url = req$url,
        headers = list(Location = to)
      ))
    }
    code <- status[[req$url]]
    if (!is.null(code)) {
      return(httr2::response(status_code = code, url = req$url))
    }
    body <- body_map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    if (is.character(body)) {
      body <- charToRaw(body)
    }
    ct <- if (grepl("robots\\.txt$", req$url)) "text/plain" else "text/xml"
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = ct),
      body = body
    )
  }
}

robots_url <- "https://ex.com/robots.txt"
bad_gzip <- as.raw(c(0x1F, 0x8B, 0x08, 0x00, 0x01, 0x02, 0x03, 0x04))
html_page <- "<!doctype html><html><body>Not here</body></html>"

source_findings <- function(audit, url) {
  f <- audit_findings(audit)
  f[f$subject_ref == sitemap_subject_ref(url), , drop = FALSE]
}

# ---- robots-declared sitemaps (SITE-utjicjfu) --------------------------------

test_that("a working declared sitemap yields no failure finding", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/robots.txt" = "Sitemap: https://ex.com/s.xml",
      "https://ex.com/s.xml" = root_urlset("https://ex.com/a")
    ),
    seen = seen
  ))
  audit <- audit_sitemap("https://ex.com", from = "root")
  f <- audit_findings(audit)
  expect_false(any(f$layer %in% c("fetch", "classification", "discovery")))
  expect_identical(audit_urls(audit)$loc, "https://ex.com/a")
  # Discovery's fetch is reused: the declared sitemap is requested once.
  expect_identical(sum(seen$urls == "https://ex.com/s.xml"), 1L)
})

test_that("a declared sitemap that 404s is FETCH_FAILED naming robots.txt", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list("https://ex.com/robots.txt" = "Sitemap: https://ex.com/gone.xml"),
    seen = seen
  ))
  audit <- audit_sitemap("https://ex.com", from = "root")
  f <- source_findings(audit, "https://ex.com/gone.xml")
  expect_identical(f$code, "FETCH_FAILED")
  expect_identical(f$severity, "fatal")
  expect_identical(f$layer, "fetch")
  expect_identical(f$subject_type, "source")
  expect_match(f$message, robots_url, fixed = TRUE)
  expect_match(f$message, "HTTP 404", fixed = TRUE)
  expect_match(f$evidence[[1L]]$excerpt, robots_url, fixed = TRUE)
})

test_that("a declared sitemap that is unreachable or 5xx is FETCH_FAILED", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/robots.txt" = paste(
        "Sitemap: https://ex.com/down.xml",
        "Sitemap: https://ex.com/err.xml",
        sep = "\n"
      )
    ),
    status = list("https://ex.com/err.xml" = 503L),
    fail = "https://ex.com/down.xml",
    seen = seen
  ))
  audit <- audit_sitemap(
    "https://ex.com",
    from = "root",
    use_known_paths = FALSE
  )
  down <- source_findings(audit, "https://ex.com/down.xml")
  err <- source_findings(audit, "https://ex.com/err.xml")
  expect_identical(down$code, "FETCH_FAILED")
  expect_match(down$message, "unreachable", fixed = TRUE)
  expect_identical(err$code, "FETCH_FAILED")
  expect_match(err$message, "HTTP 503", fixed = TRUE)
})

test_that("a declared HTML, wrong-root or corrupt-gzip body is reported", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/robots.txt" = paste(
        "Sitemap: https://ex.com/page.xml",
        "Sitemap: https://ex.com/other.xml",
        "Sitemap: https://ex.com/broken.xml.gz",
        sep = "\n"
      ),
      "https://ex.com/page.xml" = html_page,
      "https://ex.com/other.xml" = "<catalog><item/></catalog>",
      "https://ex.com/broken.xml.gz" = bad_gzip
    ),
    seen = seen
  ))
  audit <- audit_sitemap(
    "https://ex.com",
    from = "root",
    use_known_paths = FALSE
  )
  cases <- c(
    "https://ex.com/page.xml" = "UNSUPPORTED_HTML_MASQUERADE",
    "https://ex.com/other.xml" = "UNSUPPORTED_ROOT",
    "https://ex.com/broken.xml.gz" = "UNSUPPORTED_MALFORMED_GZIP"
  )
  for (url in names(cases)) {
    f <- source_findings(audit, url)
    f <- f[f$code == cases[[url]], , drop = FALSE]
    expect_identical(nrow(f), 1L, label = url)
    expect_match(f$message, paste0("Declared in ", robots_url), fixed = TRUE)
  }
})

# ---- guessed paths -----------------------------------------------------------

test_that("a soft-404 HTML or plain-text guess is a tree row, not a finding", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/sitemap.xml" = html_page,
      "https://ex.com/sitemap.txt" = "Not found"
    ),
    seen = seen
  ))
  audit <- audit_sitemap("https://ex.com", from = "root", use_robots = FALSE)
  expect_identical(nrow(audit_findings(audit)), 0L)
  tree <- audit_tree(audit)
  row <- tree[tree$sitemap_url == "https://ex.com/sitemap.xml", ]
  expect_identical(row$status, "accepted")
  expect_identical(row$provenance, "guessed-path")
})

test_that("a recognized guess is audited, broken or not", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/sitemap.xml" = root_urlset("https://ex.com/a"),
      "https://ex.com/sitemap.xml.gz" = bad_gzip,
      "https://ex.com/sitemap.txt" = "https://ex.com/t\n"
    ),
    seen = seen
  ))
  audit <- audit_sitemap("https://ex.com", from = "root", use_robots = FALSE)
  expect_setequal(
    audit_urls(audit)$loc,
    c("https://ex.com/a", "https://ex.com/t")
  )
  gz <- source_findings(audit, "https://ex.com/sitemap.xml.gz")
  expect_identical(gz$code, "UNSUPPORTED_MALFORMED_GZIP")
  # Not declared, so nothing names a robots.txt.
  expect_false(grepl("Declared in", gz$message, fixed = TRUE))
})

test_that("a guess that 404s is never a finding", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(list(), seen = seen))
  audit <- audit_sitemap("https://ex.com", from = "root")
  expect_identical(nrow(audit_findings(audit)), 0L)
  expect_true(all(audit_tree(audit)$status == "rejected"))
  # No robots.txt was read, so the discovery checks are not claimed as run.
  expect_false("discovery" %in% findings_layers_run(audit_findings(audit)))
})

test_that("a robots.txt that was read marks discovery as run", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/robots.txt" = "Sitemap: https://ex.com/s.xml",
      "https://ex.com/s.xml" = root_urlset("https://ex.com/a")
    ),
    seen = seen
  ))
  audit <- audit_sitemap("https://ex.com", from = "root")
  expect_true("discovery" %in% findings_layers_run(audit_findings(audit)))
  off <- audit_sitemap("https://ex.com", from = "root", use_robots = FALSE)
  expect_false("discovery" %in% findings_layers_run(audit_findings(off)))
})

# ---- cross-host declarations (SITE-zczpxmow) ---------------------------------

test_that("a declared sitemap on another host yields the info finding", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/robots.txt" = paste(
        "Sitemap: https://cdn.other.net/s.xml",
        "Sitemap: https://ex.com/s.xml",
        sep = "\n"
      ),
      "https://cdn.other.net/s.xml" = root_urlset("https://cdn.other.net/a"),
      "https://ex.com/s.xml" = root_urlset("https://ex.com/a")
    ),
    seen = seen
  ))
  audit <- audit_sitemap(
    "https://ex.com",
    from = "root",
    use_known_paths = FALSE
  )
  f <- audit_findings(audit)
  cross <- f[f$code == "DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST", , drop = FALSE]
  expect_identical(nrow(cross), 1L)
  expect_identical(cross$severity, "info")
  expect_identical(cross$layer, "discovery")
  expect_identical(cross$subject_type, "source")
  expect_identical(
    cross$subject_ref,
    sitemap_subject_ref("https://cdn.other.net/s.xml")
  )
  excerpt <- cross$evidence[[1L]]$excerpt
  expect_match(excerpt, "cdn.other.net", fixed = TRUE)
  expect_match(excerpt, "robots.txt host ex.com", fixed = TRUE)
  expect_match(excerpt, robots_url, fixed = TRUE)
})

test_that("a failing cross-host declaration yields both findings", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list("https://ex.com/robots.txt" = "Sitemap: https://other.net/s.xml"),
    seen = seen
  ))
  audit <- audit_sitemap(
    "https://ex.com",
    from = "root",
    use_known_paths = FALSE
  )
  expect_setequal(
    audit_findings(audit)$code,
    c("FETCH_FAILED", "DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST")
  )
})

test_that("a guessed path is never a cross-host declaration", {
  # Guesses are built on the site's own origin, so only declarations can be
  # cross-host; a same-host declaration yields no info finding.
  expect_null(audit_cross_host_finding(
    "https://EX.com/s.xml",
    "ex.com",
    robots_url
  ))
})

# ---- supplied robots.txt text ------------------------------------------------

test_that("supplied robots_txt findings name the supplied text", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list("https://other.net/s.xml" = root_urlset("https://other.net/a")),
    seen = seen
  ))
  audit <- audit_sitemap(
    "https://ex.com",
    from = "root",
    robots_txt = paste(
      "Sitemap: https://other.net/s.xml",
      "Sitemap: https://ex.com/missing.xml",
      sep = "\n"
    ),
    use_known_paths = FALSE
  )
  expect_false(robots_url %in% seen$urls)
  f <- audit_findings(audit)
  expect_setequal(
    f$code,
    c("DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST", "FETCH_FAILED")
  )
  expect_true(all(grepl("supplied robots_txt", f$message, fixed = TRUE)))
})

# ---- the tree and the arguments ----------------------------------------------

test_that("audit_tree() in root mode equals sitemap_tree()", {
  index <- paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<sitemap><loc>https://ex.com/child.xml</loc></sitemap>",
    "</sitemapindex>"
  )
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/robots.txt" = "Sitemap: https://ex.com/idx.xml",
      "https://ex.com/idx.xml" = index,
      "https://ex.com/child.xml" = root_urlset("https://ex.com/a"),
      "https://ex.com/sitemap.xml" = html_page
    ),
    seen = seen
  ))
  audit <- audit_sitemap("https://ex.com", from = "root")
  expect_identical(audit_tree(audit), sitemap_tree("https://ex.com"))
  expect_identical(audit_urls(audit)$loc, "https://ex.com/a")
})

test_that("root mode rejects bad input and contradictory arguments", {
  expect_error(
    audit_sitemap(c("https://a.com", "https://b.com"), from = "root"),
    class = "sitemapr_bad_input"
  )
  expect_error(
    audit_sitemap("https://ex.com/s.xml", robots_txt = "Sitemap: x"),
    class = "sitemapr_bad_input"
  )
  expect_error(
    audit_sitemap(
      "https://ex.com",
      from = "root",
      use_robots = FALSE,
      robots_txt = "Sitemap: https://ex.com/s.xml"
    ),
    class = "sitemapr_bad_input"
  )
})

# ---- redirects, timeouts and host spellings (review of !121) ----------------

test_that("a redirected declared index keeps the tree as sitemap_tree()", {
  index <- paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<sitemap><loc>https://ex.com/child.xml</loc></sitemap>",
    "</sitemapindex>"
  )
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/robots.txt" = "Sitemap: https://ex.com/s.xml",
      "https://ex.com/real.xml" = index,
      "https://ex.com/child.xml" = root_urlset("https://ex.com/a")
    ),
    redirect = list("https://ex.com/s.xml" = "https://ex.com/real.xml"),
    seen = seen
  ))
  audit <- audit_sitemap("https://ex.com", from = "root")
  tree <- audit_tree(audit)
  expect_identical(tree, sitemap_tree("https://ex.com"))
  expect_identical(
    tree$parent_sitemap[tree$depth == 1L],
    "https://ex.com/s.xml"
  )
})

test_that("a redirected declared HTML page still names the robots.txt", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://ex.com/robots.txt" = "Sitemap: https://EX.com/s.xml",
      "https://ex.com/page.html" = html_page
    ),
    redirect = list("https://EX.com/s.xml" = "https://ex.com/page.html"),
    seen = seen
  ))
  audit <- audit_sitemap(
    "https://ex.com",
    from = "root",
    use_known_paths = FALSE
  )
  f <- audit_findings(audit)
  f <- f[f$code == "UNSUPPORTED_HTML_MASQUERADE", , drop = FALSE]
  expect_identical(nrow(f), 1L)
  expect_match(f$message, paste0("Declared in ", robots_url), fixed = TRUE)
  # The upper-case host is the same host, not a cross-host declaration.
  codes <- audit_findings(audit)$code
  expect_false("DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST" %in% codes)
})

test_that("cross-host compares against the robots.txt actually read", {
  # ex.com/robots.txt redirects to www.ex.com, which declares its own sitemap:
  # same host as the file that declares it, so no info finding.
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list(
      "https://www.ex.com/robots.txt" = "Sitemap: https://www.ex.com/s.xml",
      "https://www.ex.com/s.xml" = "<catalog/>"
    ),
    redirect = list(
      "https://ex.com/robots.txt" = "https://www.ex.com/robots.txt"
    ),
    seen = seen
  ))
  audit <- audit_sitemap(
    "https://ex.com",
    from = "root",
    use_known_paths = FALSE
  )
  f <- audit_findings(audit)
  expect_false("DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST" %in% f$code)
  root <- f[f$code == "UNSUPPORTED_ROOT", , drop = FALSE]
  expect_match(
    root$message,
    "Declared in https://www.ex.com/robots.txt",
    fixed = TRUE
  )
})

test_that("a declared sitemap that times out is FETCH_TIMEOUT", {
  seen <- new.env(parent = emptyenv())
  httr2::local_mocked_responses(root_mock(
    list("https://ex.com/robots.txt" = "Sitemap: https://ex.com/slow.xml"),
    timeout = "https://ex.com/slow.xml",
    seen = seen
  ))
  audit <- audit_sitemap(
    "https://ex.com",
    from = "root",
    use_known_paths = FALSE
  )
  f <- source_findings(audit, "https://ex.com/slow.xml")
  expect_identical(f$code, "FETCH_TIMEOUT")
  expect_identical(f$severity, "fatal")
  expect_match(f$message, robots_url, fixed = TRUE)
})

test_that("hosts compare in their normalized spelling", {
  expect_identical(audit_url_host("https://EX.com:8443/a"), "ex.com")
  expect_true(is.na(audit_url_host("not a url")))
})
