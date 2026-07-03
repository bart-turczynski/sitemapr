# .onLoad bounds rurl's full_parse cache (SITE-vsnkmxlx). The cache stays
# ENABLED (the repeat-parse win is real); we only cap its entry count so a
# long session validating many large sitemaps cannot accumulate an unbounded
# footprint.

test_that("load bounds rurl's full_parse cache to the default", {
  skip_if_not_installed("rurl")
  # .onLoad already ran when the package was loaded for the test session.
  info <- rurl::rurl_cache_info()
  full <- info[info$cache == "full_parse", ]
  expect_true(full$enabled)
  expect_identical(full$max_entries, 50000)
})

test_that("the cache bound is overridable via the sitemapr option", {
  skip_if_not_installed("rurl")
  withr::defer({
    rurl::rurl_cache_config(max_full_parse = sitemapr:::rurl_cache_max())
  })
  withr::with_options(
    list(sitemapr.rurl_cache_max = 123L),
    sitemapr:::.onLoad(NULL, "sitemapr")
  )
  info <- rurl::rurl_cache_info()
  full <- info[info$cache == "full_parse", ]
  expect_identical(full$max_entries, 123)
})

test_that("distinct URLs beyond the bound evict rather than accumulate", {
  skip_if_not_installed("rurl")
  bound <- 10L
  withr::defer({
    rurl::rurl_cache_config(max_full_parse = sitemapr:::rurl_cache_max())
    rurl::rurl_clear_caches()
  })
  rurl::rurl_clear_caches()
  rurl::rurl_cache_config(max_full_parse = bound)

  # Unicode hosts force the rurl slow path (url_needs_rurl()), so each distinct
  # URL populates the full_parse cache.
  urls <- sprintf("https://münchen-%d.de/", seq_len(bound * 5L))
  parsed <- sitemapr:::parse_url_adapter(urls)

  info <- rurl::rurl_cache_info()
  full <- info[info$cache == "full_parse", ]
  expect_lte(full$entries, bound)

  # Eviction does not corrupt output: the parse is still correct.
  expect_true(all(startsWith(parsed$host, "xn--")))
  expect_true(all(parsed$scheme == "https"))
})
