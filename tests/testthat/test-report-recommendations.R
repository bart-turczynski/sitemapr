# Unit tests for the report's recommendations section
# (R/report-recommendations.R).
#
# Each recommendation is a pure function of the `urls`/`sources` tibbles, so the
# trigger points are pinned directly: one case just below the threshold (silent)
# and one at or above it (fires). The citation-scope decisions are pinned too —
# the child-per-index bound is 50,000 (not the sibling port's 1,000), and the
# 500-index cap is rendered as a Search Console submission cap, never as a
# format rule.

recs_for <- function(urls, sources = NULL) {
  sitemapr_test_call("report_recommendations", urls, sources)
}

rec_titles <- function(urls, sources = NULL) {
  vapply(recs_for(urls, sources), function(r) r$title, character(1))
}

# `urls` rows whose lastmod is `days` old, one row each.
aged_urls <- function(days, now = Sys.time()) {
  # A space separator, not the ISO "T": as.POSIXct() silently falls back to a
  # date-only parse on "...T...Z" and would drop the time component, moving
  # every age half a day and blurring the day-exact boundaries below.
  stamps <- format(
    now - as.difftime(days, units = "days"),
    "%Y-%m-%d %H:%M:%S",
    tz = "UTC"
  )
  report_urls_fixture(
    paste0("https://ex.com/", seq_along(days)),
    lastmod = stamps
  )
}

# ---- lastmod -----------------------------------------------------------------

test_that("an all-absent lastmod corpus is recommended one", {
  urls <- report_urls_fixture(c("https://ex.com/a", "https://ex.com/b"))
  rec <- sitemapr_test_call("report_rec_lastmod_absent", urls)

  expect_equal(rec$title, "Add <lastmod> to your URLs")
  expect_equal(rec$provenance, "documented")
  expect_match(rec$detail, "None of the 2 URLs", fixed = TRUE)
})

test_that("one dated URL is enough to withdraw the absent-lastmod advice", {
  expect_null(sitemapr_test_call("report_rec_lastmod_absent", aged_urls(1)))
  # An empty corpus has nothing to advise about either.
  expect_null(
    sitemapr_test_call(
      "report_rec_lastmod_absent",
      report_urls_fixture(character(0))
    )
  )
})

test_that("staleness fires only past half the dated URLs", {
  now <- as.POSIXct("2026-07-29 12:00:00", tz = "UTC")
  stale_rec <- function(days) {
    sitemapr_test_call("report_rec_lastmod_stale", aged_urls(days, now), now)
  }

  # Exactly half over a year old is not "most", so nothing is said.
  expect_null(stale_rec(c(400, 10)))
  # Two of three is.
  rec <- stale_rec(c(400, 500, 10))
  expect_equal(rec$provenance, "documented")
  expect_match(rec$detail, "2 of 3 dated URLs (67%)", fixed = TRUE)
  # The threshold is sitemapr's own, and says so rather than posing as sourced.
  expect_match(rec$detail, "sitemapr flags", fixed = TRUE)
  # A year and a day is stale; a year is not.
  expect_null(stale_rec(365))
  expect_false(is.null(stale_rec(366)))
  # No dated URL at all: nothing to measure.
  expect_null(
    sitemapr_test_call(
      "report_rec_lastmod_stale",
      report_urls_fixture("https://ex.com/a"),
      now
    )
  )
})

# ---- advisory fields ---------------------------------------------------------

test_that("priority/changefreq presence is advised against, once", {
  urls <- report_urls_fixture(c("https://ex.com/a", "https://ex.com/b"))
  expect_null(sitemapr_test_call("report_rec_advisory_fields", urls))

  urls$priority <- c(0.5, NA_real_)
  urls$changefreq <- c(NA_character_, "daily")
  rec <- sitemapr_test_call("report_rec_advisory_fields", urls)

  expect_match(rec$detail, "1 URLs carry <priority>", fixed = TRUE)
  expect_match(rec$detail, "1 carry <changefreq>", fixed = TRUE)
  # Yandex is the documented exception and is named as one.
  expect_match(rec$detail, "Yandex", fixed = TRUE)
  expect_equal(rec$provenance, "documented")
})

# ---- protocol bounds ---------------------------------------------------------

test_that("the URL count fires from 80% of the 50,000-URL bound", {
  key <- "https://ex.com/s.xml"
  sources <- report_sources_fixture(key, key, "xml-urlset")
  below <- report_urls_fixture(
    paste0("https://ex.com/", seq_len(39999L)),
    source_sitemap = key
  )
  expect_null(sitemapr_test_call("report_rec_url_count", below, sources))

  at <- report_urls_fixture(
    paste0("https://ex.com/", seq_len(40000L)),
    source_sitemap = key
  )
  rec <- sitemapr_test_call("report_rec_url_count", at, sources)
  expect_equal(rec$provenance, "inherited_protocol")
  expect_match(rec$detail, "lists 40,000 URLs", fixed = TRUE)
  expect_match(rec$detail, "80% of the bound", fixed = TRUE)
  # The bound named for an index is 50,000 children, never the sibling's 1,000.
  expect_match(rec$detail, "up to 50,000 children", fixed = TRUE)

  expect_null(sitemapr_test_call("report_rec_url_count", at, NULL))
})

test_that("size measures the uncompressed document only", {
  key <- "https://ex.com/s.xml"
  sources <- report_sources_fixture(key, key, "xml-urlset")
  sources$bytes <- 41943039 # one byte under 80% of 52,428,800
  expect_null(sitemapr_test_call("report_rec_size", sources))

  sources$bytes <- 41943040
  rec <- sitemapr_test_call("report_rec_size", sources)
  expect_equal(rec$provenance, "inherited_protocol")
  expect_match(rec$detail, "52,428,800-byte", fixed = TRUE)

  # A gzip source's recorded bytes are the COMPRESSED transfer size, which the
  # 50 MB uncompressed bound does not apply to.
  gz <- sources
  gz$format <- "gzip"
  expect_null(sitemapr_test_call("report_rec_size", gz))

  # A missing byte count cannot trigger it either.
  unknown <- sources
  unknown$bytes <- NA_integer_
  expect_null(sitemapr_test_call("report_rec_size", unknown))
  expect_null(sitemapr_test_call("report_rec_size", NULL))
})

test_that("child sitemaps are measured against 50,000, not 1,000", {
  index_key <- "https://ex.com/i.xml"
  children <- paste0("https://ex.com/c", seq_len(39999L), ".xml")
  sources <- report_sources_fixture(
    c(index_key, children),
    c(index_key, children),
    c("xml-sitemapindex", rep("xml-urlset", length(children)))
  )
  # 39,999 children: the sibling port's 1,000 would have fired 39 times over.
  expect_null(sitemapr_test_call("report_rec_index_children", sources))

  one_more <- "https://ex.com/c40000.xml"
  bigger <- report_sources_fixture(
    c(index_key, children, one_more),
    c(index_key, children, one_more),
    c("xml-sitemapindex", rep("xml-urlset", length(children) + 1L))
  )
  rec <- sitemapr_test_call("report_rec_index_children", bigger)
  expect_equal(rec$provenance, "inherited_protocol")
  expect_match(rec$detail, "expanded 40,000 child sitemaps", fixed = TRUE)

  # No index in the run: the bound is not the one that applies.
  flat <- report_sources_fixture(children, children, "xml-urlset")
  expect_null(sitemapr_test_call("report_rec_index_children", flat))
  expect_null(sitemapr_test_call("report_rec_index_children", NULL))
})

test_that("the 500-index cap is rendered as a submission cap, not a rule", {
  keys <- paste0("https://ex.com/i", seq_len(500L), ".xml")
  at_cap <- report_sources_fixture(keys, keys, "xml-sitemapindex")
  # 500 is the accepted maximum, so it is not yet worth saying anything.
  expect_null(sitemapr_test_call("report_rec_index_files", at_cap))

  over <- c(keys, "https://ex.com/i501.xml")
  sources <- report_sources_fixture(over, over, "xml-sitemapindex")
  rec <- sitemapr_test_call("report_rec_index_files", sources)

  expect_equal(rec$provenance, "documented")
  expect_equal(rec$sources, "google_large")
  # Scope is the point: the documents stay valid.
  expect_match(rec$detail, "submission", fixed = TRUE)
  expect_match(rec$detail, "not a format rule", fixed = TRUE)
  expect_null(sitemapr_test_call("report_rec_index_files", NULL))
})

# ---- assembly and rendering --------------------------------------------------

test_that("recommendations come back in a fixed order", {
  urls <- aged_urls(rep(500, 2))
  urls$priority <- c(0.5, 0.5)
  expect_equal(
    rec_titles(urls),
    c(
      "Most dated URLs have not been touched in over a year",
      "Consider dropping <priority> and <changefreq>"
    )
  )
})

test_that("every cited source resolves to a label and a URL", {
  keys <- c(
    "sitemaps_org",
    "google_build",
    "google_large",
    "bing_lastmod",
    "bing_2025"
  )
  for (key in keys) {
    src <- sitemapr_test_call("report_rec_source", key)
    expect_match(src$label, "\\S")
    expect_match(src$url, "^https://")
  }
})

test_that("a clean corpus renders the positive recommendations note", {
  # No lastmod at all would itself be a recommendation, so this corpus carries a
  # fresh one and no advisory fields.
  urls <- aged_urls(1)
  html <- render_string(
    "clean",
    urls = urls,
    findings = sitemapr_test_call("empty_findings_contract")
  )

  expect_match(html, "<h2>Recommendations</h2>", fixed = TRUE)
  expect_match(html, "Nothing to recommend", fixed = TRUE)
})

test_that("a triggered recommendation renders its badge and its source link", {
  html <- render_string(core_fixture())

  expect_match(html, "<h2>Recommendations</h2>", fixed = TRUE)
  expect_match(html, "smr-rec-title", fixed = TRUE)
  expect_match(html, "smr-prov", fixed = TRUE)
  # The citation is a content link to the primary source, not a loaded asset.
  expect_match(html, "blogs.bing.com/webmaster", fixed = TRUE)
  expect_match(html, "rel=\"noopener noreferrer\"", fixed = TRUE)
})
