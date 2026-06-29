# Cucumber step definitions for discovery.feature (SITE-veaawhbg).
#
# testthat sources `setup-*.R` before the test files, so these steps are
# registered before `cucumber::run()` executes the active features.
#
# Discovery fetches go through httr2's native mocking
# (httr2::local_mocked_responses); the real network is never hit, so the suite
# is CRAN-safe. The mock is installed INSIDE the helper that performs the run
# (and the run completes synchronously before the helper returns), so the
# frame-scoped mock is active for every candidate fetch.
#
# Cucumber compiles each step description to an UNESCAPED regex (anchored
# ^...$), so any regex-special char in the wording is interpreted as regex
# (SITE-qalrtbes). The feature wording is otherwise metachar-free, but the
# `I call sitemap_tree(...)` steps carry literal parentheses, so they are
# escaped as `\\(` / `\\)` in the registrations below.
#
# Guarded on `cucumber` being installed so the suggests-only R CMD check
# (`_R_CHECK_DEPENDS_ONLY_=true`, which CRAN runs) degrades gracefully.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  # A minimal urlset body returned for any candidate the fixture "resolves".
  disc_urlset <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<url><loc>https://example.com/page/1</loc></url></urlset>"
  )

  # Run discovery against `root` under a request-logging mock. A candidate whose
  # URL ends with one of the "resolved" paths gets a 200 urlset; everything else
  # 404s. Requested URLs are recorded in `context$requested` (in fetch order).
  run_discovery <- function(context, root = context$root, cap = NULL) {
    context$requested <- character(0)
    ok_paths <- context$ok_paths
    if (is.null(ok_paths)) {
      ok_paths <- character(0)
    }
    mock <- function(req) {
      context$requested <- c(context$requested, req$url)
      if (
        length(ok_paths) > 0L &&
          any(vapply(
            ok_paths,
            function(p) endsWith(req$url, p),
            logical(1)
          ))
      ) {
        return(httr2::response(
          status_code = 200L,
          url = req$url,
          headers = list("Content-Type" = "application/xml"),
          body = charToRaw(disc_urlset)
        ))
      }
      httr2::response(status_code = 404L, url = req$url)
    }
    httr2::local_mocked_responses(mock)
    limits <- if (is.null(cap)) {
      sitemapr:::discovery_limits()
    } else {
      sitemapr:::discovery_limits(max_candidates = cap)
    }
    context$tree <- sitemapr::sitemap_tree(root, limits = limits)
  }

  # Find the single tree row whose sitemap_url ends with the given path.
  tree_row_for <- function(context, path) {
    context$tree[endsWith(context$tree$sitemap_url, path), ]
  }

  # --- given -----------------------------------------------------------------

  given("a site root URL {string}", function(url, context) {
    context$root <- url
  })

  given(
    "a guess catalog that would produce the same URL twice",
    function(context) {
      # The real catalog already does: Shopify's /sitemap.xml == the generic.
      context$root <- "https://example.com"
    }
  )

  given("a fixture server returns 200 for {string}", function(path, context) {
    context$ok_paths <- c(context$ok_paths, path)
  })

  given("a fixture server returns 404 for all guesses", function(context) {
    context$ok_paths <- character(0)
  })

  given(
    "a guess catalog with more entries than the configured candidate cap",
    function(context) {
      context$root <- "https://example.com"
    }
  )

  given(
    "a fixture where one guess resolves and one returns 404",
    function(context) {
      context$root <- "https://example.com"
      context$ok_paths <- "/sitemap.xml"
    }
  )

  given("a resolved discovery candidate", function(context) {
    context$root <- "https://example.com"
    context$ok_paths <- "/sitemap.xml"
  })

  given("a fixture server that logs all requests", function(context) {
    context$root <- "https://example.com"
  })

  # --- when ------------------------------------------------------------------

  when("discovery runs against a fixture server", function(context) {
    run_discovery(context)
  })

  when("discovery runs", function(context) {
    run_discovery(context)
  })

  when("discovery runs against {string}", function(root, context) {
    run_discovery(context, root = root)
  })

  when("discovery runs with a cap of {int}", function(cap, context) {
    run_discovery(context, cap = cap)
  })

  # Literal parens escaped for the unescaped-regex compiler (SITE-qalrtbes).
  when("I call sitemap_tree\\({string}\\)", function(root, context) {
    run_discovery(context, root = root)
  })

  # --- then ------------------------------------------------------------------

  then(
    "the candidates include standard paths such as {string} and {string}",
    function(a, b, context) {
      urls <- context$tree$sitemap_url
      testthat::expect_true(any(endsWith(urls, a)))
      testthat::expect_true(any(endsWith(urls, b)))
    }
  )

  then(
    "candidates are tried in the documented catalog order",
    function(context) {
      expected <- sitemapr:::discovery_candidates(context$root)$candidate_url
      testthat::expect_identical(context$requested, expected)
    }
  )

  then(
    "the candidates include at least one CMS-specific path",
    function(context) {
      testthat::expect_true(any(endsWith(
        context$tree$sitemap_url,
        "/wp-sitemap.xml"
      )))
    }
  )

  then(
    "CMS paths appear after generic paths in the ordered catalog",
    function(context) {
      req <- context$requested
      cms_at <- which(endsWith(req, "/wp-sitemap.xml"))
      generic_at <- which(endsWith(req, "/sitemaps.xml"))
      testthat::expect_gt(min(cms_at), max(generic_at))
    }
  )

  then("the URL is requested only once", function(context) {
    dup_url <- "https://example.com/sitemap.xml"
    testthat::expect_identical(sum(context$requested == dup_url), 1L)
  })

  then(
    "the sitemap_tree row for {string} has status {string}",
    function(path, status, context) {
      row <- tree_row_for(context, path)
      testthat::expect_identical(nrow(row), 1L)
      testthat::expect_identical(row$status, status)
    }
  )

  then("the reason records the catalog match", function(context) {
    accepted <- context$tree[context$tree$status == "accepted", ]
    testthat::expect_true(all(startsWith(accepted$reason, "catalog")))
  })

  then("the sitemap_tree rows have status {string}", function(status, context) {
    testthat::expect_true(all(context$tree$status == status))
  })

  then("the reason is {string}", function(reason, context) {
    testthat::expect_true(all(context$tree$reason == reason))
  })

  then(
    "validate_sitemap produces no finding for missing guesses",
    function(context) {
      # A missing guess (404) is a rejected discovery candidate; it must never
      # cross into the findings layer. Pointing validate_sitemap() (Layer F,
      # SITE-ymzvnlpr) at such a URL surfaces the transport failure as a classed
      # `sitemapr_entrypoint_error` — it returns no findings tibble at all, so a
      # 404 can never become a finding row. The given's `404 for all guesses`
      # fixture is re-mocked here because run_discovery's frame-scoped mock was
      # torn down when the WHEN returned.
      missing <- paste0(context$root, "/sitemap.xml")
      httr2::local_mocked_responses(function(req) {
        httr2::response(status_code = 404L, url = req$url)
      })
      suppressWarnings(
        testthat::expect_error(
          sitemapr::validate_sitemap(missing),
          class = "sitemapr_entrypoint_error"
        )
      )
    }
  )

  then("at most {int} candidates are evaluated", function(cap, context) {
    testthat::expect_lte(length(unique(context$requested)), cap)
    testthat::expect_lte(nrow(context$tree), cap)
  })

  then("the result contains a row for the accepted URL", function(context) {
    testthat::expect_true(any(context$tree$status == "accepted"))
  })

  then("the result contains a row for the rejected URL", function(context) {
    testthat::expect_true(any(context$tree$status == "rejected"))
  })

  then("both rows carry provenance {string}", function(provenance, context) {
    testthat::expect_true(all(context$tree$provenance == provenance))
  })

  then(
    paste(
      "each result row has columns depth, parent_sitemap, sitemap_url,",
      "page_count, gzip, status, reason, provenance"
    ),
    function(context) {
      testthat::expect_identical(
        names(context$tree),
        c(
          "depth",
          "parent_sitemap",
          "sitemap_url",
          "page_count",
          "gzip",
          "status",
          "reason",
          "provenance"
        )
      )
    }
  )

  then("no request is made to {string}", function(path, context) {
    testthat::expect_false(any(endsWith(context$requested, path)))
  })

  then(
    "the Sitemap directive in robots.txt is not consulted",
    function(context) {
      testthat::expect_false(
        any(grepl("robots", context$requested, fixed = TRUE))
      )
    }
  )
}
