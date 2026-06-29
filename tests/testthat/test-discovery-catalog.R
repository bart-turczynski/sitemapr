# Unit tests for the guessed-path discovery catalog (R/discovery-catalog.R).

test_that("discovery_catalog is a tibble with the path/kind/source contract", {
  cat <- discovery_catalog()
  expect_s3_class(cat, "tbl_df")
  expect_identical(names(cat), c("path", "kind", "source"))
  expect_type(cat$path, "character")
  expect_type(cat$kind, "character")
  expect_type(cat$source, "character")
  expect_true(all(cat$kind %in% c("generic", "cms")))
})

test_that("the documented standard generic paths are present", {
  cat <- discovery_catalog()
  expect_true(all(
    c("/sitemap.xml", "/sitemap_index.xml") %in% cat$path
  ))
})

test_that("at least one CMS-specific path is present", {
  cat <- discovery_catalog()
  cms <- cat[cat$kind == "cms", ]
  expect_gte(nrow(cms), 1L)
  # WordPress's /wp-sitemap.xml is CMS-specific and unique to the CMS catalog.
  expect_true("/wp-sitemap.xml" %in% cms$path)
})

test_that("CMS paths appear after every generic path in catalog order", {
  cat <- discovery_catalog()
  last_generic <- max(which(cat$kind == "generic"))
  first_cms <- min(which(cat$kind == "cms"))
  expect_lt(last_generic, first_cms)
})

test_that("generic guesses keep their documented contractual order", {
  cat <- discovery_catalog()
  generic <- cat$path[cat$kind == "generic"]
  expect_identical(
    generic,
    c(
      "/sitemap.xml",
      "/sitemap_index.xml",
      "/sitemap-index.xml",
      "/sitemap.xml.gz",
      "/sitemap.txt",
      "/sitemap/index.xml",
      "/sitemaps.xml",
      "/news-sitemap.xml",
      "/sitemap-news.xml"
    )
  )
})

test_that("generic guesses carry NA source; CMS rows carry a source slug", {
  cat <- discovery_catalog()
  expect_true(all(is.na(cat$source[cat$kind == "generic"])))
  expect_true(all(!is.na(cat$source[cat$kind == "cms"])))
})

test_that("rows are unique even though a path may repeat across kinds", {
  cat <- discovery_catalog()
  # No exact-duplicate (path, kind, source) row ...
  expect_identical(nrow(cat), nrow(unique(cat)))
  # ... but Shopify intentionally reuses the generic /sitemap.xml path, so the
  # path alone is not unique. That collision is the builder's to dedup.
  expect_gt(sum(cat$path == "/sitemap.xml"), 1L)
})

test_that("robots.txt is never part of the catalog (ADR-002 deferral)", {
  cat <- discovery_catalog()
  expect_false(any(grepl("robots", cat$path, fixed = TRUE)))
})

test_that("the noise-prone bare /sitemap/ path is excluded from guesses", {
  cat <- discovery_catalog()
  expect_false("/sitemap/" %in% cat$path)
})
