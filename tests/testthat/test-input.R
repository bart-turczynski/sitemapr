# Tests for the input-normalization slice (SITE-qebdxvlt).
# Each block maps to a scenario in the input_normalization acceptance feature.

source_records <- function(...) {
  sitemapr_test_call("create_source_records", ...)
}

test_that("explicit https URL preserved, provenance submitted-directly", {
  rec <- source_records("https://example.com/sitemap.xml")

  expect_identical(nrow(rec), 1L)
  expect_identical(rec$provenance, "submitted-directly")
  expect_identical(rec$scheme, "https")
  expect_true(startsWith(rec$normalized_url, "https://"))
  expect_false(rec$scheme_inferred)
  # original retained alongside normalized
  expect_identical(rec$original_input, "https://example.com/sitemap.xml")
  expect_identical(rec$normalized_url, "https://example.com/sitemap.xml")
})

test_that("explicit http scheme is preserved with no substitution", {
  rec <- source_records("http://example.com/sitemap.xml")

  expect_identical(rec$scheme, "http")
  expect_true(startsWith(rec$normalized_url, "http://"))
  expect_false(rec$scheme_inferred)
})

test_that("schemeless input receives https and is flagged inferred", {
  rec <- source_records("example.com", as = "site")

  expect_true(startsWith(rec$normalized_url, "https://"))
  expect_true(rec$scheme_inferred)
  expect_identical(rec$original_input, "example.com")
})

test_that("site root URL is reduced to its origin", {
  rec <- source_records(
    "https://example.com/blog/post-1",
    as = "site"
  )

  expect_identical(rec$normalized_url, "https://example.com")
})

test_that("unicode host is normalized via IDNA, original retained", {
  rec <- source_records(
    "https://münchen.de/sitemap.xml",
    as = "site"
  )

  expect_identical(rec$host, "xn--mnchen-3ya.de")
  expect_identical(rec$original_input, "https://münchen.de/sitemap.xml")
})

test_that("host and scheme are lowercased", {
  rec <- source_records("HTTPS://EXAMPLE.COM/sitemap.xml")

  expect_identical(rec$normalized_url, "https://example.com/sitemap.xml")
  expect_identical(rec$scheme, "https")
  expect_identical(rec$host, "example.com")
})

test_that("path dot-segments are resolved", {
  rec <- source_records(
    "https://example.com/a/../sitemaps/./sitemap.xml"
  )

  expect_identical(rec$path, "/sitemaps/sitemap.xml")
})

test_that("local file path is classified, no existence required", {
  rec <- source_records("/path/to/sitemap.xml")

  expect_identical(rec$provenance, "submitted-directly")
  expect_true(rec$is_local_file)
  expect_identical(rec$normalized_url, "/path/to/sitemap.xml")
  expect_false(file.exists("/path/to/sitemap.xml"))
})

test_that("URL vector produces multiple submitted-list records", {
  rec <- source_records(c(
    "https://example.com/sitemap1.xml",
    "https://example.com/sitemap2.xml"
  ))

  expect_identical(nrow(rec), 2L)
  expect_true(all(rec$provenance == "submitted-list"))
})

test_that("duplicate URLs in a vector collapse to one record", {
  rec <- source_records(c(
    "https://example.com/sitemap.xml",
    "https://example.com/sitemap.xml"
  ))

  expect_identical(nrow(rec), 1L)
})

test_that("submitted-list cap is enforced citing 25", {
  urls <- sprintf("https://example.com/sitemap-%02d.xml", 1:26)

  expect_error(
    source_records(urls),
    regexp = "25",
    class = "sitemapr_submitted_list_cap_error"
  )
})

test_that("URLs differing only by port are distinct", {
  rec <- source_records(c(
    "https://example.com:8080/sitemap.xml",
    "https://example.com:9090/sitemap.xml"
  ))

  expect_identical(nrow(rec), 2L)
  expect_length(unique(rec$loc_key), 2L)
})

test_that("normalized_url preserves a contentful query (SITE-vrgszbnu)", {
  rec <- source_records(
    "https://example.com/sitemap.php?page=2"
  )
  # The fetch URL must keep the query, or a dynamic sitemap is fetched wrong.
  expect_identical(rec$normalized_url, "https://example.com/sitemap.php?page=2")
})

test_that("normalized_url preserves a non-default port", {
  rec <- source_records(
    "https://example.com:8443/sitemap.xml"
  )
  expect_identical(rec$normalized_url, "https://example.com:8443/sitemap.xml")
})

test_that("normalized_url drops the fragment (never fetched)", {
  rec <- source_records(
    "https://example.com/sitemap.xml#section"
  )
  expect_identical(rec$normalized_url, "https://example.com/sitemap.xml")
})

test_that("a default port is identity-equivalent to no port", {
  rec <- source_records(c(
    "https://example.com:443/sitemap.xml",
    "https://example.com/sitemap.xml"
  ))
  # The two collapse to one source record after dedup on the identity key.
  expect_identical(nrow(rec), 1L)
})

test_that("normalized_url equals the identity key for a sitemap source", {
  rec <- source_records(
    "https://example.com:8443/sitemap.xml?page=2"
  )
  expect_identical(rec$normalized_url, rec$loc_key)
})

test_that("a non-character `x` raises sitemapr_input_type_error", {
  expect_error(
    source_records(42L),
    class = "sitemapr_input_type_error"
  )
  expect_error(
    source_records(list("a")),
    class = "sitemapr_input_type_error"
  )
})

test_that("an empty character `x` raises sitemapr_input_empty_error", {
  expect_error(
    source_records(character(0)),
    class = "sitemapr_input_empty_error"
  )
})

test_that("an unparseable URL raises sitemapr_input_parse_error", {
  # "https://" carries an explicit scheme but no host, so parse_url_adapter()
  # reports parse_status != "ok" and normalize_one() aborts.
  expect_error(
    source_records("https://"),
    class = "sitemapr_input_parse_error"
  )
})
