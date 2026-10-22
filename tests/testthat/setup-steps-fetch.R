# Cucumber step definitions for fetch_classification.feature.
#
# testthat sources `setup-*.R` before the test files, so these steps are
# registered before `cucumber::run()` executes the active features.
#
# Only the child-4xx scenario remains: it drives the public read_sitemap()
# through the shared index-expansion steps (setup-steps-index.R), which serve
# the bodies with httr2's native mocking, so the real network is never hit.
# The fetch, SSRF and sniffing scenarios that called internals were replaced by
# test-fetch.R, test-ssrf.R and test-sniff.R (SITE-mnbswkkr).
#
# Guarded on `cucumber` being installed so the suggests-only R CMD check
# (`_R_CHECK_DEPENDS_ONLY_=true`, which CRAN runs) degrades gracefully: with the
# package absent the steps simply are not registered and test-cucumber.R skips.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  # --- GIVEN -----------------------------------------------------------------

  given(
    "a sitemap index that references a child URL returning 404",
    function(context) {
      # Sets up the shared index-expansion context (consumed by the generic
      # "I call read_sitemap on the index" step in setup-steps-index.R): an
      # index listing one resolvable child and one child that 404s.
      context$index_url <- "https://example.com/sitemap.xml"
      context$failed_child <- "https://example.com/missing.xml"
      context$body_map <- list2env(list(
        "https://example.com/sitemap.xml" = paste0(
          "<sitemapindex xmlns=",
          "\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
          "<sitemap><loc>https://example.com/child-1.xml</loc></sitemap>",
          "<sitemap><loc>https://example.com/missing.xml</loc></sitemap>",
          "</sitemapindex>"
        ),
        "https://example.com/child-1.xml" = paste0(
          "<urlset xmlns=",
          "\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
          "<url><loc>https://example.com/a</loc></url></urlset>"
        )
      ))
    }
  )

  # "I call read_sitemap on the index" is registered once, generically, by the
  # index-expansion slice (setup-steps-index.R); both this feature and
  # index_expansion.feature share it.

  # --- THEN ------------------------------------------------------------------

  # A child 404 surfaces as a non-fatal warning, the parse result keeps the good
  # children's rows, and the failed child is recorded in the `problems`
  # attribute.
  then("a warning-class condition is raised for the child", function(context) {
    raised <- vapply(
      context$warnings,
      inherits,
      logical(1),
      "sitemapr_http_error"
    )
    expect_true(any(raised))
  })

  then(
    paste0(
      "the partial parse result still contains rows from successful ",
      "children"
    ),
    function(context) {
      expect_true("https://example.com/a" %in% context$result$loc)
    }
  )

  then("the failed child appears in the problems attribute", function(context) {
    problems <- context$problems
    expect_true(any(grepl(
      context$failed_child,
      problems$subject_ref,
      fixed = TRUE
    )))
  })
}
