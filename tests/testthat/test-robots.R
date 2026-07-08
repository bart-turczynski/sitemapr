# Unit tests for robots.txt Sitemap: directive discovery (R/robots.R) and its
# integration into sitemap_tree(). Offline: fetches go through
# httr2::local_mocked_responses (CRAN-safe).

robots_urlset <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    "</urlset>"
  )
}

robots_mock <- function(body_map) {
  function(req) {
    body <- body_map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    ct <- if (grepl("robots\\.txt$", req$url)) {
      "text/plain"
    } else {
      "application/xml"
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = ct),
      body = charToRaw(body)
    )
  }
}

# ---- parse_robots_sitemaps(): pure directive extraction ----------------------

test_that("parse_robots_sitemaps extracts Sitemap directives in order", {
  txt <- paste(
    "User-agent: *",
    "Disallow: /admin",
    "Sitemap: https://ex.com/a.xml",
    "Sitemap: https://ex.com/b.xml",
    sep = "\n"
  )
  expect_identical(
    parse_robots_sitemaps(txt),
    c("https://ex.com/a.xml", "https://ex.com/b.xml")
  )
})

test_that("parse_robots_sitemaps is case-insensitive, misspelling-ok", {
  txt <- paste(
    "SITEMAP: https://ex.com/a.xml",
    "site-map: https://ex.com/b.xml",
    "  sitemap:   https://ex.com/c.xml  ",
    sep = "\n"
  )
  expect_identical(
    parse_robots_sitemaps(txt),
    c("https://ex.com/a.xml", "https://ex.com/b.xml", "https://ex.com/c.xml")
  )
})

test_that("parse_robots_sitemaps dedups on the full-URL identity key", {
  txt <- paste(
    "Sitemap: https://ex.com/a.xml",
    "Sitemap: https://ex.com/a.xml",
    sep = "\n"
  )
  expect_identical(parse_robots_sitemaps(txt), "https://ex.com/a.xml")
})

test_that("parse_robots_sitemaps skips non-http directives with a warning", {
  txt <- paste(
    "Sitemap: /relative/sitemap.xml",
    "Sitemap: ftp://ex.com/s.xml",
    "Sitemap: https://ex.com/ok.xml",
    sep = "\n"
  )
  expect_warning(
    out <- parse_robots_sitemaps(txt),
    class = "sitemapr_robots_bad_directive"
  )
  expect_identical(out, "https://ex.com/ok.xml")
})

test_that("parse_robots_sitemaps returns empty for only invalid directives", {
  expect_warning(
    out <- parse_robots_sitemaps("Sitemap: /relative/sitemap.xml"),
    class = "sitemapr_robots_bad_directive"
  )

  expect_identical(out, character(0))
})

test_that("parse_robots_sitemaps returns empty when there are no directives", {
  expect_identical(
    parse_robots_sitemaps("User-agent: *\nDisallow: /"),
    character(0)
  )
})

# ---- discover_robots_sitemaps(): fetch + parse -------------------------------

test_that("discover_robots_sitemaps returns URLs from a fetched robots.txt", {
  httr2::local_mocked_responses(robots_mock(list(
    "https://ex.com/robots.txt" = "Sitemap: https://ex.com/a.xml"
  )))
  expect_identical(
    discover_robots_sitemaps("https://ex.com"),
    "https://ex.com/a.xml"
  )
})

test_that("discover_robots_sitemaps returns empty on a missing robots.txt", {
  httr2::local_mocked_responses(robots_mock(list())) # 404
  expect_identical(discover_robots_sitemaps("https://ex.com"), character(0))
})

test_that("discover_robots_sitemaps swallows a transport failure", {
  httr2::local_mocked_responses(function(req) stop("boom"))
  expect_identical(discover_robots_sitemaps("https://ex.com"), character(0))
})

test_that("discover_robots_sitemaps returns empty for an empty robots body", {
  httr2::local_mocked_responses(function(req) {
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "text/plain"),
      body = raw(0L)
    )
  })

  expect_identical(discover_robots_sitemaps("https://ex.com"), character(0))
})

# ---- sitemap_tree() integration ---------------------------------------------

test_that("sitemap_tree surfaces a non-catalog sitemap listed in robots.txt", {
  httr2::local_mocked_responses(robots_mock(list(
    "https://ex.com/robots.txt" = "Sitemap: https://ex.com/custom/deep.xml",
    "https://ex.com/custom/deep.xml" = robots_urlset(
      "https://ex.com/1",
      "https://ex.com/2"
    )
  )))
  tree <- sitemap_tree("https://ex.com")
  row <- tree[tree$sitemap_url == "https://ex.com/custom/deep.xml", ]
  expect_identical(nrow(row), 1L)
  expect_identical(row$status, "accepted")
  expect_identical(row$provenance, "robots")
  expect_identical(row$reason, "robots")
  expect_identical(row$page_count, 2L)
})

test_that("a URL in both robots.txt and the catalog dedups to robots", {
  # /sitemap.xml is a catalog guess; listing it in robots.txt should yield a
  # single row with robots provenance, not two rows.
  httr2::local_mocked_responses(robots_mock(list(
    "https://ex.com/robots.txt" = "Sitemap: https://ex.com/sitemap.xml",
    "https://ex.com/sitemap.xml" = robots_urlset("https://ex.com/1")
  )))
  tree <- sitemap_tree("https://ex.com")
  row <- tree[tree$sitemap_url == "https://ex.com/sitemap.xml", ]
  expect_identical(nrow(row), 1L)
  expect_identical(row$provenance, "robots")
})

test_that("use_robots = FALSE ignores robots.txt directives", {
  httr2::local_mocked_responses(robots_mock(list(
    "https://ex.com/robots.txt" = "Sitemap: https://ex.com/custom/deep.xml",
    "https://ex.com/custom/deep.xml" = robots_urlset("https://ex.com/1")
  )))
  tree <- sitemap_tree("https://ex.com", use_robots = FALSE)
  expect_false("https://ex.com/custom/deep.xml" %in% tree$sitemap_url)
  expect_true(all(tree$provenance == "guessed-path"))
})

test_that("use_known_paths = FALSE keeps only robots rows", {
  httr2::local_mocked_responses(robots_mock(list(
    "https://ex.com/robots.txt" = "Sitemap: https://ex.com/custom/deep.xml",
    "https://ex.com/custom/deep.xml" = robots_urlset("https://ex.com/1")
  )))
  tree <- sitemap_tree("https://ex.com", use_known_paths = FALSE)
  expect_true(all(tree$provenance == "robots"))
  expect_identical(
    tree$sitemap_url[tree$depth == 0L],
    "https://ex.com/custom/deep.xml"
  )
})

test_that("both sources off yields an empty tree", {
  httr2::local_mocked_responses(robots_mock(list()))
  tree <- sitemap_tree(
    "https://ex.com",
    use_robots = FALSE,
    use_known_paths = FALSE
  )
  expect_identical(nrow(tree), 0L)
  expect_named(tree, sitemap_tree_cols())
})

test_that("a robots-listed index is expanded like any accepted index", {
  index <- paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<sitemap><loc>https://ex.com/child.xml</loc></sitemap>",
    "</sitemapindex>"
  )
  httr2::local_mocked_responses(robots_mock(list(
    "https://ex.com/robots.txt" = "Sitemap: https://ex.com/idx.xml",
    "https://ex.com/idx.xml" = index,
    "https://ex.com/child.xml" = robots_urlset(
      "https://ex.com/1",
      "https://ex.com/2"
    )
  )))
  tree <- sitemap_tree("https://ex.com", use_known_paths = FALSE)
  root <- tree[tree$sitemap_url == "https://ex.com/idx.xml", ]
  child <- tree[tree$sitemap_url == "https://ex.com/child.xml", ]
  expect_identical(root$provenance, "robots")
  expect_identical(child$provenance, "child-of-index")
  expect_identical(child$depth, 1L)
  expect_identical(child$page_count, 2L)
})
