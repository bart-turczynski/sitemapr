# Unit tests for sitemap_tree() and its row schema (R/sitemap-tree.R). Offline:
# candidate fetches go through httr2::local_mocked_responses (CRAN-safe).

tree_urlset <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    "</urlset>"
  )
}

tree_index <- function(...) {
  kids <- paste0("<sitemap><loc>", c(...), "</loc></sitemap>", collapse = "")
  paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    kids,
    "</sitemapindex>"
  )
}

# Mock dispatcher: 200 with a mapped body, else 404.
tree_mock <- function(body_map) {
  function(req) {
    body <- body_map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    if (is.character(body)) {
      body <- charToRaw(body)
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/xml"),
      body = body
    )
  }
}

test_that("sitemap_tree_cols() is the documented 8-column contract", {
  expect_identical(
    sitemap_tree_cols(),
    c(
      "depth",
      "parent_sitemap",
      "sitemap_url",
      "page_count",
      "gzip",
      "status",
      "reason",
      "provenance"
    )
  )
})

test_that("empty_sitemap_tree carries the column contract and types", {
  tree <- empty_sitemap_tree()
  expect_s3_class(tree, "tbl_df")
  expect_identical(nrow(tree), 0L)
  expect_named(tree, sitemap_tree_cols())
  expect_type(tree$depth, "integer")
  expect_type(tree$page_count, "integer")
  expect_type(tree$gzip, "logical")
})

test_that("each result row exposes the documented column contract", {
  httr2::local_mocked_responses(tree_mock(list()))
  tree <- sitemap_tree("https://example.com")
  expect_named(tree, sitemap_tree_cols())
})

test_that("an accepted candidate row carries status, page_count, and gzip", {
  httr2::local_mocked_responses(tree_mock(list(
    "https://example.com/sitemap.xml" = tree_urlset(
      "https://a/1",
      "https://a/2"
    )
  )))
  tree <- sitemap_tree("https://example.com")
  row <- tree[tree$sitemap_url == "https://example.com/sitemap.xml", ]
  expect_identical(row$status, "accepted")
  expect_identical(row$page_count, 2L)
  expect_false(row$gzip)
  expect_identical(row$depth, 0L)
  expect_true(is.na(row$parent_sitemap))
  expect_identical(row$provenance, "guessed-path")
})

test_that("a sitemapindex hit counts its child sitemaps as the page_count", {
  httr2::local_mocked_responses(tree_mock(list(
    "https://example.com/sitemap_index.xml" = tree_index(
      "https://example.com/a.xml",
      "https://example.com/b.xml"
    ),
    "https://example.com/a.xml" = tree_urlset("https://a/1"),
    "https://example.com/b.xml" = tree_urlset("https://b/1")
  )))
  tree <- sitemap_tree("https://example.com")
  row <- tree[tree$sitemap_url == "https://example.com/sitemap_index.xml", ]
  expect_identical(row$status, "accepted")
  expect_identical(row$page_count, 2L)
})

test_that("an accepted index candidate is expanded into depth-1 child rows", {
  httr2::local_mocked_responses(tree_mock(list(
    "https://example.com/sitemap_index.xml" = tree_index(
      "https://example.com/a.xml",
      "https://example.com/b.xml"
    ),
    "https://example.com/a.xml" = tree_urlset("https://a/1"),
    "https://example.com/b.xml" = tree_urlset("https://b/1")
  )))
  tree <- sitemap_tree("https://example.com")
  kids <- tree[tree$depth == 1L, ]
  expect_setequal(
    kids$sitemap_url,
    c("https://example.com/a.xml", "https://example.com/b.xml")
  )
  expect_true(all(
    kids$parent_sitemap == "https://example.com/sitemap_index.xml"
  ))
  expect_true(all(kids$provenance == "child-of-index"))
  expect_true(all(kids$status == "accepted"))
})

test_that("rejected rows carry status rejected, reason, and NA page_count", {
  httr2::local_mocked_responses(tree_mock(list())) # all 404
  tree <- sitemap_tree("https://example.com")
  expect_true(all(tree$status == "rejected"))
  expect_true(all(tree$reason == "not-found"))
  expect_true(all(is.na(tree$page_count)))
})

test_that("the tree includes both accepted and rejected candidates", {
  httr2::local_mocked_responses(tree_mock(list(
    "https://example.com/sitemap.xml" = tree_urlset("https://a/1")
  )))
  tree <- sitemap_tree("https://example.com")
  expect_true(any(tree$status == "accepted"))
  expect_true(any(tree$status == "rejected"))
  # Both an accepted and a rejected URL are present as rows.
  expect_true("https://example.com/sitemap.xml" %in% tree$sitemap_url)
  expect_gt(sum(tree$status == "rejected"), 0L)
})

test_that("all discovery rows are depth 0 with guessed-path provenance", {
  httr2::local_mocked_responses(tree_mock(list()))
  tree <- sitemap_tree("https://example.com")
  expect_true(all(tree$depth == 0L))
  expect_true(all(is.na(tree$parent_sitemap)))
  expect_true(all(tree$provenance == "guessed-path"))
})

test_that("a candidate whose fetch aborts has no record and no page_count", {
  # A transport failure on one candidate yields a NULL fetch record; the
  # assembler must skip it (no page_count/gzip), not error.
  mock <- function(req) {
    if (grepl("/sitemap\\.xml$", req$url)) {
      stop("simulated transport failure")
    }
    httr2::response(status_code = 404L, url = req$url)
  }
  httr2::local_mocked_responses(mock)
  tree <- sitemap_tree("https://example.com")
  row <- tree[tree$sitemap_url == "https://example.com/sitemap.xml", ]
  expect_identical(row$status, "rejected")
  expect_identical(row$reason, "unreachable")
  expect_true(is.na(row$page_count))
  expect_true(is.na(row$gzip))
})

test_that("an accepted candidate with an unparseable body skips page_count", {
  # A 200 HTML masquerade is accepted by discovery (2xx) but fails the parser;
  # the assembler swallows the parse error and leaves page_count NA.
  mock <- function(req) {
    if (grepl("/sitemap\\.xml$", req$url)) {
      return(httr2::response(
        status_code = 200L,
        url = req$url,
        headers = list("Content-Type" = "text/html"),
        body = charToRaw(
          "<!DOCTYPE html><html><body>not a sitemap</body></html>"
        )
      ))
    }
    httr2::response(status_code = 404L, url = req$url)
  }
  httr2::local_mocked_responses(mock)
  tree <- sitemap_tree("https://example.com")
  row <- tree[tree$sitemap_url == "https://example.com/sitemap.xml", ]
  expect_identical(row$status, "accepted")
  expect_true(is.na(row$page_count))
  expect_false(row$gzip)
})
