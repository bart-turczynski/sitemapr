# Unit tests for the XML sitemap parser (R/parse-xml.R). Pure/offline: every
# fixture is an inline string, no network and no temp files.

urlset_minimal <- paste0(
  '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
  "<url><loc>https://a/</loc></url>",
  "<url><loc>https://b/</loc></url>",
  "</urlset>"
)

test_that("a urlset parses to the contract row tibble", {
  res <- parse_sitemap_xml(urlset_minimal)
  expect_identical(res$kind, "urlset")
  expect_null(res$children)
  expect_s3_class(res$rows, "tbl_df")
  expect_identical(
    names(res$rows),
    c("loc", "lastmod", "changefreq", "priority", "images", "video",
      "news", "alternates", "source_sitemap")
  )
  expect_identical(res$rows$loc, c("https://a/", "https://b/"))
})

test_that("absent core fields default to NA and absent extensions to NULL", {
  rows <- parse_sitemap_xml(urlset_minimal)$rows
  expect_true(all(is.na(rows$lastmod)))
  expect_true(all(is.na(rows$changefreq)))
  expect_true(all(is.na(rows$priority)))
  expect_null(rows$images[[1L]])
  expect_null(rows$video[[2L]])
})

test_that("source_sitemap provenance is written to every row", {
  rows <- parse_sitemap_xml(
    urlset_minimal,
    source_sitemap = "child-of-index"
  )$rows
  expect_identical(rows$source_sitemap, rep("child-of-index", 2L))
})

test_that("an empty urlset yields the zero-row schema", {
  empty <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>'
  )
  rows <- parse_sitemap_xml(empty)$rows
  expect_identical(nrow(rows), 0L)
  expect_s3_class(rows$lastmod, "POSIXct")
})

test_that("core fields (lastmod, changefreq, priority) are parsed", {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url>',
    "<loc>https://a/</loc><lastmod>2026-01-02T03:04:05Z</lastmod>",
    "<changefreq>daily</changefreq><priority>0.8</priority>",
    "</url></urlset>"
  )
  rows <- parse_sitemap_xml(xml)$rows
  expect_s3_class(rows$lastmod, "POSIXct")
  expect_identical(attr(rows$lastmod, "tzone"), "UTC")
  expect_equal(
    rows$lastmod[[1L]],
    as.POSIXct("2026-01-02 03:04:05", tz = "UTC")
  )
  expect_identical(rows$changefreq, "daily")
  expect_identical(rows$priority, 0.8)
})

test_that("lastmod accepts date-only and timezone offsets, NA on garbage", {
  expect_equal(
    parse_lastmod("2026-06-01"),
    as.POSIXct("2026-06-01 00:00:00", tz = "UTC")
  )
  expect_equal(
    parse_lastmod("2026-01-02T03:04:05+02:00"),
    as.POSIXct("2026-01-02 01:04:05", tz = "UTC")
  )
  expect_true(is.na(parse_lastmod("not-a-date")))
  expect_true(is.na(parse_lastmod("")))
})

test_that("image extension data appears as a per-row list-column", {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" ',
    'xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">',
    "<url><loc>https://a/</loc>",
    "<image:image><image:loc>https://a/1.jpg</image:loc>",
    "<image:title>One</image:title></image:image>",
    "<image:image><image:loc>https://a/2.jpg</image:loc></image:image>",
    "</url>",
    "<url><loc>https://b/</loc></url>",
    "</urlset>"
  )
  rows <- parse_sitemap_xml(xml)$rows
  expect_type(rows$images, "list")
  expect_length(rows$images[[1L]], 2L)
  expect_identical(rows$images[[1L]][[1L]]$loc[[1L]], "https://a/1.jpg")
  expect_identical(rows$images[[1L]][[1L]]$title[[1L]], "One")
  expect_null(rows$images[[2L]])
})

test_that("a non-image extension stays NULL when only images are present", {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" ',
    'xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">',
    "<url><loc>https://a/</loc>",
    "<image:image><image:loc>https://a/1.jpg</image:loc></image:image>",
    "</url></urlset>"
  )
  rows <- parse_sitemap_xml(xml)$rows
  expect_null(rows$video[[1L]])
  expect_null(rows$news[[1L]])
  expect_null(rows$alternates[[1L]])
})

test_that("xhtml hreflang alternates preserve href/hreflang attributes", {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" ',
    'xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    "<url><loc>https://a/</loc>",
    '<xhtml:link rel="alternate" hreflang="de" href="https://a/de"/>',
    '<xhtml:link rel="alternate" hreflang="fr" href="https://a/fr"/>',
    "</url></urlset>"
  )
  rows <- parse_sitemap_xml(xml)$rows
  alt <- rows$alternates[[1L]]
  expect_length(alt, 2L)
  expect_identical(attr(alt[[1L]], "hreflang"), "de")
  expect_identical(attr(alt[[1L]], "href"), "https://a/de")
  expect_identical(attr(alt[[2L]], "hreflang"), "fr")
})

test_that("extension matching is namespace-aware, not prefix-bound", {
  # The image namespace is bound to a non-conventional prefix.
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" ',
    'xmlns:img="http://www.google.com/schemas/sitemap-image/1.1">',
    "<url><loc>https://a/</loc>",
    "<img:image><img:loc>https://a/1.jpg</img:loc></img:image>",
    "</url></urlset>"
  )
  rows <- parse_sitemap_xml(xml)$rows
  expect_length(rows$images[[1L]], 1L)
  expect_identical(rows$images[[1L]][[1L]]$loc[[1L]], "https://a/1.jpg")
})

test_that("a sitemapindex yields child loc/lastmod and empty rows", {
  xml <- paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<sitemap><loc>https://a/s1.xml</loc>",
    "<lastmod>2026-01-01</lastmod></sitemap>",
    "<sitemap><loc>https://a/s2.xml</loc></sitemap>",
    "</sitemapindex>"
  )
  res <- parse_sitemap_xml(xml)
  expect_identical(res$kind, "sitemapindex")
  expect_identical(nrow(res$rows), 0L)
  expect_identical(res$children$loc, c("https://a/s1.xml", "https://a/s2.xml"))
  expect_s3_class(res$children$lastmod, "POSIXct")
  expect_equal(
    res$children$lastmod[[1L]],
    as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  )
  expect_true(is.na(res$children$lastmod[[2L]]))
})

test_that("an unsupported root raises a classed condition", {
  expect_error(
    parse_sitemap_xml("<rss><channel/></rss>"),
    class = "sitemapr_unsupported_root"
  )
})

test_that("malformed XML raises a classed parse error", {
  expect_error(
    parse_sitemap_xml("<urlset><url><loc>x"),
    class = "sitemapr_xml_parse_error"
  )
})

test_that("external entities are not resolved (XXE-safe)", {
  # A SYSTEM entity must not load file contents; loc resolves to empty text.
  xxe <- paste0(
    '<?xml version="1.0"?>',
    '<!DOCTYPE urlset [ <!ENTITY xxe SYSTEM "file:///etc/hostname"> ]>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<url><loc>&xxe;</loc></url></urlset>"
  )
  rows <- parse_sitemap_xml(xxe)$rows
  expect_identical(rows$loc, "")
})
