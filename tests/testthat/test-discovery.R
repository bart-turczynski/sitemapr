# Unit tests for the discovery candidate builder (R/discovery.R).

test_that("candidates carry the documented column contract", {
  cand <- discovery_candidates("https://example.com")
  expect_s3_class(cand, "tbl_df")
  expect_identical(
    names(cand),
    c("candidate_url", "catalog_path", "kind", "source", "loc_key")
  )
})

test_that("candidate URLs join the catalog paths to the root origin", {
  cand <- discovery_candidates("https://example.com")
  expect_true("https://example.com/sitemap.xml" %in% cand$candidate_url)
  expect_true("https://example.com/wp-sitemap.xml" %in% cand$candidate_url)
})

test_that("candidates are tried in catalog order (generic before CMS)", {
  cand <- discovery_candidates("https://example.com")
  last_generic <- max(which(cand$kind == "generic"))
  first_cms <- min(which(cand$kind == "cms"))
  expect_lt(last_generic, first_cms)
  # The very first candidate is the first generic guess.
  expect_identical(cand$candidate_url[[1L]], "https://example.com/sitemap.xml")
})

test_that("a duplicate URL (Shopify == generic /sitemap.xml) is collapsed", {
  cand <- discovery_candidates("https://example.com")
  expect_identical(sum(cand$candidate_url == "https://example.com/sitemap.xml"),
                   1L)
  # The surviving row is the first (generic) occurrence, not the CMS one.
  keep <- cand[cand$candidate_url == "https://example.com/sitemap.xml", ]
  expect_identical(keep$kind, "generic")
})

test_that("the dedup count is the catalog minus the one URL collision", {
  cand <- discovery_candidates("https://example.com")
  cat_rows <- nrow(discovery_catalog())
  # Exactly one URL collision (Shopify /sitemap.xml) is removed.
  expect_identical(nrow(cand), cat_rows - 1L)
})

test_that("the candidate cap truncates after deduplication", {
  cand <- discovery_candidates(
    "https://example.com",
    limits = discovery_limits(max_candidates = 5L)
  )
  expect_identical(nrow(cand), 5L)
  # The retained candidates are the first five in catalog order.
  expect_identical(
    cand$candidate_url,
    c(
      "https://example.com/sitemap.xml",
      "https://example.com/sitemap_index.xml",
      "https://example.com/sitemap-index.xml",
      "https://example.com/sitemap.xml.gz",
      "https://example.com/sitemap.txt"
    )
  )
})

test_that("a bare-host root is normalized to an https origin", {
  cand <- discovery_candidates("example.com")
  expect_true("https://example.com/sitemap.xml" %in% cand$candidate_url)
})

test_that("a root with a path is reduced to its origin before joining", {
  cand <- discovery_candidates("https://example.com/blog/index.html")
  expect_true("https://example.com/sitemap.xml" %in% cand$candidate_url)
  expect_false(any(grepl("/blog/", cand$candidate_url, fixed = TRUE)))
})

test_that("an explicit non-default port is preserved in candidate URLs", {
  cand <- discovery_candidates("https://example.com:8443")
  expect_true(
    "https://example.com:8443/sitemap.xml" %in% cand$candidate_url
  )
})

test_that("empty or non-scalar root input is rejected", {
  expect_error(discovery_candidates(""), class = "sitemapr_bad_input")
  expect_error(
    discovery_candidates(c("https://a.com", "https://b.com")),
    class = "sitemapr_bad_input"
  )
})

test_that("discovery_limits resolves the cap from the option then default", {
  expect_identical(discovery_limits()$max_candidates, 50L)
  withr::with_options(
    list(sitemapr.max_candidates = 7L),
    expect_identical(discovery_limits()$max_candidates, 7L)
  )
})
