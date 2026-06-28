# Unit tests for the pure-logic schema profile catalog (R/schema-catalog.R).
# No XML parsing/validation here — only the namespace map, root-kind detection,
# cache key, and profile resolution.

core_ns <- "http://www.sitemaps.org/schemas/sitemap/0.9"
image_ns <- "http://www.google.com/schemas/sitemap-image/1.1"
news_ns <- "http://www.google.com/schemas/sitemap-news/0.9"
xhtml_ns <- "http://www.w3.org/1999/xhtml"

test_that("catalog_version is a non-empty scalar string", {
  expect_type(schema_catalog_version, "character")
  expect_length(schema_catalog_version, 1L)
  expect_true(nzchar(schema_catalog_version))
})

test_that("every extension namespace maps to a bundled schema file", {
  catalog <- schema_extension_catalog()
  expect_true(all(grepl("\\.xsd$", catalog)))
  # The core namespace is handled separately, never via the extension map.
  expect_false(core_ns %in% names(catalog))
  # The v1 extension set is image, video, news, pagemap, hreflang(xhtml).
  expect_setequal(
    names(catalog),
    c(
      image_ns,
      "http://www.google.com/schemas/sitemap-video/1.1",
      news_ns,
      "http://www.google.com/schemas/sitemap-pagemap/1.0",
      xhtml_ns
    )
  )
})

test_that("every catalog file (and core files) is actually bundled", {
  dir <- schema_dir()
  skip_if(identical(dir, ""), "package not installed")
  files <- c(
    schema_core_file("urlset"),
    schema_core_file("sitemapindex"),
    unname(schema_extension_catalog())
  )
  expect_true(all(file.exists(file.path(dir, files))))
})

test_that("root kind detection maps urlset/sitemapindex and rejects others", {
  expect_identical(schema_root_kind("urlset"), "urlset")
  expect_identical(schema_root_kind("sitemapindex"), "sitemapindex")
  expect_identical(schema_root_kind("rss"), NA_character_)
  expect_identical(schema_root_kind(""), NA_character_)
})

test_that("core schema file differs by root kind", {
  expect_identical(schema_core_file("urlset"), "sitemap.xsd")
  expect_identical(schema_core_file("sitemapindex"), "siteindex.xsd")
  expect_identical(schema_core_file("rss"), NA_character_)
})

test_that("namespace set is de-duplicated, sorted, and free of empty values", {
  expect_identical(
    schema_sorted_namespace_set(c(image_ns, core_ns, image_ns, NA, "")),
    sort(c(core_ns, image_ns))
  )
  expect_identical(schema_sorted_namespace_set(character()), character())
})

test_that("cache key is (version, root_kind, sorted namespace set)", {
  key <- schema_cache_key("urlset", c(image_ns, core_ns))
  expect_identical(
    key,
    paste(c(schema_catalog_version, "urlset", sort(c(core_ns, image_ns))),
      collapse = "|"
    )
  )
})

test_that("cache key is insensitive to namespace order and duplicates", {
  expect_identical(
    schema_cache_key("urlset", c(core_ns, image_ns, news_ns)),
    schema_cache_key("urlset", c(news_ns, image_ns, core_ns, news_ns))
  )
})

test_that("cache key separates root kinds and catalog versions", {
  expect_false(identical(
    schema_cache_key("urlset", core_ns),
    schema_cache_key("sitemapindex", core_ns)
  ))
  expect_false(identical(
    schema_cache_key("urlset", core_ns, catalog_version = "1"),
    schema_cache_key("urlset", core_ns, catalog_version = "2")
  ))
})

test_that("pre-composed profile basename is sorted and order-independent", {
  expect_identical(
    schema_profile_basename("urlset", c(news_ns, image_ns)),
    "urlset-image-news.xsd"
  )
  expect_identical(
    schema_profile_basename("urlset", c(image_ns, news_ns)),
    schema_profile_basename("urlset", c(news_ns, image_ns))
  )
})

test_that("core-only urlset resolves to the bundled core schema", {
  res <- schema_resolve_profile("urlset", core_ns, schemas_dir = "/x")
  expect_identical(res$kind, "bundled")
  expect_identical(res$schema_path, file.path("/x", "sitemap.xsd"))
  expect_length(res$imports, 0L)
})

test_that("core-only sitemapindex resolves to the bundled index schema", {
  res <- schema_resolve_profile("sitemapindex", core_ns, schemas_dir = "/x")
  expect_identical(res$kind, "bundled")
  expect_identical(res$schema_path, file.path("/x", "siteindex.xsd"))
})

test_that("a bare doc with no namespaces still resolves core-only", {
  res <- schema_resolve_profile("urlset", character(), schemas_dir = "/x")
  expect_identical(res$kind, "bundled")
})

test_that("mixed namespaces without a pre-composed file need runtime gen", {
  res <- schema_resolve_profile(
    "urlset", c(core_ns, image_ns, news_ns),
    schemas_dir = "/no-such-dir"
  )
  expect_identical(res$kind, "runtime")
  expect_true(is.na(res$schema_path))
  # The wrapper must import the core schema plus each extension schema.
  expect_identical(
    sort(names(res$imports)),
    sort(c(core_ns, image_ns, news_ns))
  )
  expect_identical(
    unname(res$imports[[image_ns]]),
    file.path("/no-such-dir", "sitemap-image.xsd")
  )
})

test_that("a pre-composed generated profile is preferred over runtime gen", {
  dir <- withr::local_tempdir()
  dir.create(file.path(dir, "generated"))
  composed <- file.path(dir, "generated", "urlset-image-news.xsd")
  writeLines("<schema/>", composed)
  res <- schema_resolve_profile(
    "urlset", c(core_ns, news_ns, image_ns), schemas_dir = dir
  )
  expect_identical(res$kind, "generated")
  expect_identical(res$schema_path, composed)
  expect_identical(
    sort(names(res$imports)), sort(c(core_ns, image_ns, news_ns))
  )
})

test_that("an unrecognised namespace yields an unknown-namespace decision", {
  weird <- "https://example.com/ns/custom"
  res <- schema_resolve_profile(
    "urlset", c(core_ns, image_ns, weird), schemas_dir = "/x"
  )
  expect_identical(res$kind, "unknown-namespace")
  expect_identical(res$unknown_namespaces, weird)
  # No schema is resolved and nothing is imported for an unknown namespace.
  expect_true(is.na(res$schema_path))
})

test_that("resolution echoes the sorted namespace set and a cache key", {
  res <- schema_resolve_profile(
    "urlset", c(image_ns, core_ns), schemas_dir = "/x"
  )
  expect_identical(res$namespaces, sort(c(core_ns, image_ns)))
  expect_identical(
    res$cache_key, schema_cache_key("urlset", c(core_ns, image_ns))
  )
})
