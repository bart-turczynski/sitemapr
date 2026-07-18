# Exported limit constructors + sources()/problems() companion accessors
# (SITE-blevoisn).

# A minimal local urlset written to a tempfile, so read_sitemap() runs offline.
local_urlset_file <- function(env = parent.frame()) {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<url><loc>https://example.com/</loc></url>",
    "<url><loc>https://example.com/about</loc></url>",
    "</urlset>"
  )
  path <- withr::local_tempfile(fileext = ".xml", .local_envir = env)
  writeLines(xml, path)
  path
}

test_that("the three limit constructors are exported (usable without :::)", {
  exports <- getNamespaceExports("sitemapr")
  expect_true(all(
    c("fetch_limits", "index_limits", "discovery_limits") %in% exports
  ))
})

test_that("fetch_limits() preserves its list shape and coerced types", {
  withr::local_options(list(
    sitemapr.timeout = NULL,
    sitemapr.max_redirects = NULL,
    sitemapr.max_bytes = NULL
  ))

  lim <- fetch_limits()

  expect_named(lim, c("timeout", "max_redirects", "max_bytes"))
  expect_identical(lim$timeout, 30)
  expect_identical(lim$max_redirects, 5L)
  expect_identical(lim$max_bytes, 524288000L)
})

test_that("index_limits() preserves its list shape, Inf budgets, and types", {
  withr::local_options(list(
    sitemapr.max_index_depth = NULL,
    sitemapr.max_index_children = NULL,
    sitemapr.max_total_sitemaps = NULL,
    sitemapr.max_total_urls = NULL
  ))

  lim <- index_limits()

  expect_named(
    lim,
    c("max_depth", "max_children", "max_total_sitemaps", "max_total_urls")
  )
  expect_identical(lim$max_depth, 3L)
  expect_identical(lim$max_children, 50000L)
  expect_identical(lim$max_total_sitemaps, Inf)
  expect_identical(lim$max_total_urls, Inf)
  expect_type(lim$max_total_sitemaps, "double")
})

test_that("discovery_limits() preserves its list shape and coerced type", {
  withr::local_options(list(sitemapr.max_candidates = NULL))

  lim <- discovery_limits()

  expect_named(lim, "max_candidates")
  expect_identical(lim$max_candidates, 50L)
})

test_that("fetch_limits() rejects invalid limits with a classed condition", {
  expect_error(
    fetch_limits(timeout = -1),
    class = "sitemapr_invalid_limits"
  )
  expect_error(
    fetch_limits(max_redirects = c(1L, 2L)),
    class = "sitemapr_invalid_limits"
  )
  expect_error(
    fetch_limits(max_bytes = "big"),
    class = "sitemapr_invalid_limits"
  )
  expect_error(
    fetch_limits(timeout = NA_real_),
    class = "sitemapr_invalid_limits"
  )
  # A finite fetch limit must not be Inf (only the aggregate budgets allow it).
  expect_error(
    fetch_limits(timeout = Inf),
    class = "sitemapr_invalid_limits"
  )
})

test_that("index_limits() rejects invalid bounds; budgets accept Inf", {
  expect_error(
    index_limits(max_depth = -1),
    class = "sitemapr_invalid_limits"
  )
  expect_error(
    index_limits(max_children = NA_integer_),
    class = "sitemapr_invalid_limits"
  )
  # A non-budget bound must be finite.
  expect_error(
    index_limits(max_depth = Inf),
    class = "sitemapr_invalid_limits"
  )
  # The aggregate budgets accept a positive-infinite ceiling.
  expect_no_error(index_limits(max_total_sitemaps = Inf, max_total_urls = Inf))
  expect_error(
    index_limits(max_total_urls = -5),
    class = "sitemapr_invalid_limits"
  )
})

test_that("discovery_limits() rejects invalid candidate caps", {
  expect_error(
    discovery_limits(max_candidates = -1),
    class = "sitemapr_invalid_limits"
  )
  expect_error(
    discovery_limits(max_candidates = c(1L, 2L)),
    class = "sitemapr_invalid_limits"
  )
})

test_that("sources()/problems() read the read_sitemap() companions", {
  urls <- read_sitemap(local_urlset_file())

  expect_identical(sources(urls), attr(urls, "sources"))
  expect_identical(problems(urls), attr(urls, "problems"))

  # The companion shapes match the documented schemas.
  expect_named(sources(urls), names(empty_source_metadata()))
  expect_named(problems(urls), names(empty_problems()))
})

test_that("sources()/problems() dispatch on a sitemap_audit object", {
  urls <- read_sitemap(local_urlset_file())
  audit <- sitemap_audit(urls = urls)

  expect_identical(sources(audit), audit_sources(audit))
  expect_identical(problems(audit), audit_problems(audit))

  # Audit-promoted companions equal the read_sitemap() attributes they came
  # from (round-trip compatibility).
  expect_equal(sources(audit), attr(urls, "sources"))
  expect_equal(problems(audit), attr(urls, "problems"))
})

test_that("sources()/problems() default methods return NULL when absent", {
  expect_null(sources(data.frame(a = 1)))
  expect_null(problems(data.frame(a = 1)))
})
