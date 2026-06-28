# Tests for the input-normalization slice (SITE-qebdxvlt).
# Each block maps to a scenario in the input_normalization acceptance feature.

test_that("explicit https URL preserved, provenance submitted-directly", {
  rec <- sitemapr:::create_source_records("https://example.com/sitemap.xml")

  expect_equal(nrow(rec), 1L)
  expect_equal(rec$provenance, "submitted-directly")
  expect_equal(rec$scheme, "https")
  expect_true(startsWith(rec$normalized_url, "https://"))
  expect_false(rec$scheme_inferred)
  # original retained alongside normalized
  expect_equal(rec$original_input, "https://example.com/sitemap.xml")
  expect_equal(rec$normalized_url, "https://example.com/sitemap.xml")
})

test_that("explicit http scheme is preserved with no substitution", {
  rec <- sitemapr:::create_source_records("http://example.com/sitemap.xml")

  expect_equal(rec$scheme, "http")
  expect_true(startsWith(rec$normalized_url, "http://"))
  expect_false(rec$scheme_inferred)
})

test_that("schemeless input receives https and is flagged inferred", {
  rec <- sitemapr:::create_source_records("example.com", as = "site")

  expect_true(startsWith(rec$normalized_url, "https://"))
  expect_true(rec$scheme_inferred)
  expect_equal(rec$original_input, "example.com")
})

test_that("site root URL is reduced to its origin", {
  rec <- sitemapr:::create_source_records(
    "https://example.com/blog/post-1",
    as = "site"
  )

  expect_equal(rec$normalized_url, "https://example.com")
})

test_that("unicode host is normalized via IDNA, original retained", {
  rec <- sitemapr:::create_source_records(
    "https://münchen.de/sitemap.xml",
    as = "site"
  )

  expect_equal(rec$host, "xn--mnchen-3ya.de")
  expect_equal(rec$original_input, "https://münchen.de/sitemap.xml")
})

test_that("host and scheme are lowercased", {
  rec <- sitemapr:::create_source_records("HTTPS://EXAMPLE.COM/sitemap.xml")

  expect_equal(rec$normalized_url, "https://example.com/sitemap.xml")
  expect_equal(rec$scheme, "https")
  expect_equal(rec$host, "example.com")
})

test_that("path dot-segments are resolved", {
  rec <- sitemapr:::create_source_records(
    "https://example.com/a/../sitemaps/./sitemap.xml"
  )

  expect_equal(rec$path, "/sitemaps/sitemap.xml")
})

test_that("local file path is classified, no existence required", {
  rec <- sitemapr:::create_source_records("/path/to/sitemap.xml")

  expect_equal(rec$provenance, "submitted-directly")
  expect_true(rec$is_local_file)
  expect_equal(rec$normalized_url, "/path/to/sitemap.xml")
  expect_false(file.exists("/path/to/sitemap.xml"))
})

test_that("URL vector produces multiple submitted-list records", {
  rec <- sitemapr:::create_source_records(c(
    "https://example.com/sitemap1.xml",
    "https://example.com/sitemap2.xml"
  ))

  expect_equal(nrow(rec), 2L)
  expect_true(all(rec$provenance == "submitted-list"))
})

test_that("duplicate URLs in a vector collapse to one record", {
  rec <- sitemapr:::create_source_records(c(
    "https://example.com/sitemap.xml",
    "https://example.com/sitemap.xml"
  ))

  expect_equal(nrow(rec), 1L)
})

test_that("submitted-list cap is enforced citing 25", {
  urls <- sprintf("https://example.com/sitemap-%02d.xml", 1:26)

  expect_error(
    sitemapr:::create_source_records(urls),
    regexp = "25",
    class = "sitemapr_submitted_list_cap_error"
  )
})

test_that("URLs differing only by port are distinct", {
  rec <- sitemapr:::create_source_records(c(
    "https://example.com:8080/sitemap.xml",
    "https://example.com:9090/sitemap.xml"
  ))

  expect_equal(nrow(rec), 2L)
  expect_equal(length(unique(rec$loc_key)), 2L)
})
