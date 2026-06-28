# Unit tests for sitemap_tree() and its row schema (R/sitemap-tree.R). Offline:
# candidate fetches go through httr2::local_mocked_responses (CRAN-safe).

tree_urlset <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls, "</urlset>"
  )
}

tree_index <- function(...) {
  kids <- paste0("<sitemap><loc>", c(...), "</loc></sitemap>", collapse = "")
  paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    kids, "</sitemapindex>"
  )
}

# Mock dispatcher: 200 with a mapped body, else 404.
tree_mock <- function(body_map) {
  function(req) {
    body <- body_map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    if (is.character(body)) body <- charToRaw(body)
    httr2::response(
      status_code = 200L, url = req$url,
      headers = list("Content-Type" = "application/xml"), body = body
    )
  }
}

test_that("empty_sitemap_tree carries the 8-column contract and types", {
  tree <- empty_sitemap_tree()
  expect_s3_class(tree, "tbl_df")
  expect_identical(nrow(tree), 0L)
  expect_identical(
    names(tree),
    c("depth", "parent_sitemap", "sitemap_url", "page_count", "gzip",
      "status", "reason", "provenance")
  )
  expect_type(tree$depth, "integer")
  expect_type(tree$page_count, "integer")
  expect_type(tree$gzip, "logical")
})

test_that("each result row exposes the documented column contract", {
  httr2::local_mocked_responses(tree_mock(list()))
  tree <- sitemap_tree("https://example.com")
  expect_identical(
    names(tree),
    c("depth", "parent_sitemap", "sitemap_url", "page_count", "gzip",
      "status", "reason", "provenance")
  )
})

test_that("an accepted candidate row carries status, page_count, and gzip", {
  httr2::local_mocked_responses(tree_mock(list(
    "https://example.com/sitemap.xml" =
      tree_urlset("https://a/1", "https://a/2")
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
    "https://example.com/sitemap_index.xml" =
      tree_index("https://example.com/a.xml", "https://example.com/b.xml"),
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
    "https://example.com/sitemap_index.xml" =
      tree_index("https://example.com/a.xml", "https://example.com/b.xml"),
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
