# Unit tests for the RSS/Atom feed parser (R/parse-feed.R). Pure/offline: feeds
# are loaded from tests/testthat/fixtures as raw bytes (exercising the byte path
# read_sitemap_xml() shares with the XML parser) or supplied as inline strings.

feed_bytes <- function(name) {
  path <- test_path("fixtures", name)
  readBin(path, what = "raw", n = file.info(path)$size)
}

contract_cols <- c(
  "loc",
  "lastmod",
  "changefreq",
  "priority",
  "images",
  "video",
  "news",
  "alternates",
  "source_sitemap"
)

test_that("RSS 2.0 parses items into faithful rows", {
  res <- parse_feed(feed_bytes("feed-rss2.xml"))
  expect_identical(res$kind, "feed")
  expect_identical(res$variant, "rss2.0")
  expect_null(res$children)
  expect_named(res$rows, contract_cols)
  expect_identical(
    res$rows$loc,
    c(
      "https://example.com/posts/1",
      "https://example.com/posts/2",
      "https://example.com/posts/3"
    )
  )
  # <pubDate> is kept as the raw RFC-822 string (faithful; ADR-004).
  expect_identical(res$rows$lastmod[[1L]], "Mon, 06 Sep 2010 16:45:00 +0000")
  expect_identical(res$rows$lastmod[[2L]], "Tue, 07 Sep 2010 08:00:00 GMT")
  expect_true(is.na(res$rows$lastmod[[3L]]))
})

test_that("RSS link ignores a rel=self atom:link inside an item", {
  # Item 2 carries an <atom:link rel="self" href=...> before the plain <link>;
  # the not(@href) guard must pick the item's own namespace-less <link>.
  res <- parse_feed(feed_bytes("feed-rss2.xml"))
  expect_identical(res$rows$loc[[2L]], "https://example.com/posts/2")
})

test_that("Atom 1.0 parses entries into faithful rows", {
  res <- parse_feed(feed_bytes("feed-atom10.xml"))
  expect_identical(res$variant, "atom1.0")
  expect_named(res$rows, contract_cols)
  expect_identical(
    res$rows$loc,
    c(
      "https://example.com/entries/1",
      "https://example.com/entries/2",
      "https://example.com/entries/3"
    )
  )
  # <updated> kept raw; entry 3 has none -> NA (no silent drop).
  expect_identical(res$rows$lastmod[[1L]], "2026-01-02T03:04:05Z")
  expect_identical(res$rows$lastmod[[2L]], "2026-01-03T10:20:30+02:00")
  expect_true(is.na(res$rows$lastmod[[3L]]))
})

test_that("Atom 0.3 parses entries and reads <modified> for the date", {
  res <- parse_feed(feed_bytes("feed-atom03.xml"))
  expect_identical(res$variant, "atom0.3")
  expect_identical(
    res$rows$loc,
    c("https://example.com/legacy/1", "https://example.com/legacy/2")
  )
  expect_identical(res$rows$lastmod[[1L]], "2026-02-02T03:04:05Z")
  expect_true(is.na(res$rows$lastmod[[2L]]))
})

test_that("feeds carry no changefreq/priority/extension data", {
  res <- parse_feed(feed_bytes("feed-atom10.xml"))
  expect_true(all(is.na(res$rows$changefreq)))
  expect_true(all(is.na(res$rows$priority)))
  expect_null(res$rows$images[[1L]])
  expect_null(res$rows$video[[1L]])
  expect_null(res$rows$news[[1L]])
  expect_null(res$rows$alternates[[1L]])
})

test_that("source_sitemap provenance is written to every feed row", {
  res <- parse_feed(
    feed_bytes("feed-rss2.xml"),
    source_sitemap = "https://example.com/feed.xml"
  )
  expect_identical(
    res$rows$source_sitemap,
    rep("https://example.com/feed.xml", 3L)
  )
})

test_that("the variant is prefix-agnostic and namespace-driven", {
  # A prefixed Atom 1.0 root still classifies as atom1.0 by namespace URI.
  xml <- paste0(
    '<a:feed xmlns:a="http://www.w3.org/2005/Atom">',
    "<a:entry><a:link href=\"https://x/1\"/></a:entry></a:feed>"
  )
  res <- parse_feed(xml)
  expect_identical(res$variant, "atom1.0")
  expect_identical(res$rows$loc, "https://x/1")
})

test_that("an empty feed yields the zero-row schema", {
  rss <- '<rss version="2.0"><channel><title>t</title></channel></rss>'
  atom <- '<feed xmlns="http://www.w3.org/2005/Atom"><title>t</title></feed>'
  expect_identical(nrow(parse_feed(rss)$rows), 0L)
  expect_identical(nrow(parse_feed(atom)$rows), 0L)
  expect_type(parse_feed(rss)$rows$lastmod, "character")
})

test_that("an unsupported feed dialect raises a typed condition", {
  expect_error(
    parse_feed(feed_bytes("feed-unsupported-rdf.xml")),
    class = "sitemapr_unsupported_feed"
  )
})

test_that("not-well-formed feed XML raises the shared parse-error condition", {
  expect_error(
    parse_feed(feed_bytes("feed-malformed.xml")),
    class = "sitemapr_xml_parse_error"
  )
})

test_that("external entities are not resolved in feeds (XXE-safe)", {
  xxe <- paste0(
    '<?xml version="1.0"?>',
    '<!DOCTYPE rss [ <!ENTITY xxe SYSTEM "file:///etc/hostname"> ]>',
    '<rss version="2.0"><channel>',
    "<item><link>https://example.com/&xxe;</link></item>",
    "</channel></rss>"
  )
  res <- parse_feed(xxe)
  expect_identical(res$rows$loc, "https://example.com/")
})
