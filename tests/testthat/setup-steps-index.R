# Cucumber step definitions for index_expansion.feature (SITE-qanfkjaq).
#
# testthat sources `setup-*.R` before the test files, so these steps are
# registered before `cucumber::run()` executes the active features.
#
# Index-expansion fetches go through httr2's native mocking
# (httr2::local_mocked_responses); the real network is never hit, so the suite
# is CRAN-safe. The mock is installed INSIDE the helper that performs the run
# (and the run completes synchronously before the helper returns), so the
# frame-scoped mock is active for the entry fetch and every child fetch.
#
# Findings vs problems (architecture.md §3). `read_sitemap()` is a parse API: it
# records bounded-traversal events (cycle, depth/count caps, nested index) in
# the code-free `problems` companion table, NOT in a findings tibble. The
# feature's planning-draft wording ("an INDEX_CYCLE_DETECTED finding") is
# therefore asserted here against that problems table (category
# "index-expansion"), exactly as parse_formats.feature asserts parse problems.
# The authoritative INDEX_* finding codes are emitted later by
# `validate_sitemap()` (Layer F, SITE-ymzvnlpr).
#
# Cucumber compiles each step description to an UNESCAPED, anchored regex
# (SITE-qalrtbes). The wording below is free of regex metacharacters (the
# INDEX_* tokens contain only word characters), so no escaping is needed.
#
# Guarded on `cucumber` being installed so the suggests-only R CMD check
# (`_R_CHECK_DEPENDS_ONLY_=true`, which CRAN runs) degrades gracefully.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  idx_ns <- "http://www.sitemaps.org/schemas/sitemap/0.9"

  # A leaf urlset carrying a single distinctive loc.
  idx_urlset <- function(loc) {
    paste0(
      "<urlset xmlns=\"",
      idx_ns,
      "\"><url><loc>",
      loc,
      "</loc></url></urlset>"
    )
  }

  # A sitemapindex listing the given child locs.
  idx_index <- function(...) {
    kids <- paste0(
      "<sitemap><loc>",
      c(...),
      "</loc></sitemap>",
      collapse = ""
    )
    paste0("<sitemapindex xmlns=\"", idx_ns, "\">", kids, "</sitemapindex>")
  }

  # Load a committed fixture file's contents (working dir is tests/testthat/).
  idx_fixture <- function(name) {
    paste(readLines(file.path("fixtures", name), warn = FALSE), collapse = "\n")
  }

  # Build the mock responder from `context$body_map` (URL -> XML string),
  # recording every requested URL into `context$requested`; unmapped URLs 404.
  # The caller installs it with httr2::local_mocked_responses IN ITS OWN FRAME,
  # since that mock is frame-scoped and torn down when its installer returns.
  idx_mock_fn <- function(context) {
    context$requested <- character(0)
    map <- context$body_map
    function(req) {
      context$requested <- c(context$requested, req$url)
      body <- map[[req$url]]
      if (is.null(body)) {
        return(httr2::response(status_code = 404L, url = req$url))
      }
      httr2::response(
        status_code = 200L,
        url = req$url,
        headers = list("Content-Type" = "application/xml"),
        body = charToRaw(body)
      )
    }
  }

  # Run read_sitemap() on the configured index under the mock, capturing the
  # result, its problems/sources attributes, and any warning conditions raised
  # (a child 4xx surfaces as a non-fatal `sitemapr_http_error` warning, which
  # the fetch_classification "child 4xx" scenario asserts on).
  idx_run_read <- function(context) {
    httr2::local_mocked_responses(idx_mock_fn(context))
    il <- context$index_limits
    context$warnings <- list()
    context$result <- withCallingHandlers(
      if (is.null(il)) {
        sitemapr::read_sitemap(context$index_url)
      } else {
        sitemapr::read_sitemap(context$index_url, index_limits = il)
      },
      warning = function(w) {
        context$warnings[[length(context$warnings) + 1L]] <- w
        invokeRestart("muffleWarning")
      }
    )
    context$problems <- attr(context$result, "problems")
    context$sources <- attr(context$result, "sources")
  }

  # Run sitemap_tree() on the index's site root under the mock.
  idx_run_tree <- function(context) {
    httr2::local_mocked_responses(idx_mock_fn(context))
    context$tree <- suppressWarnings(sitemapr::sitemap_tree(context$root))
  }

  # TRUE if any index-expansion problem message matches `pattern`.
  idx_has_problem <- function(context, pattern) {
    p <- context$problems
    any(p$category == "index-expansion" & grepl(pattern, p$message))
  }

  # --- given -----------------------------------------------------------------

  # index-simple.xml: served at /sitemap.xml so the same setup feeds both the
  # read_sitemap (direct URL) and sitemap_tree (discovered) paths. Its two
  # children resolve to distinct leaf urlsets.
  idx_simple_setup <- function(context) {
    context$index_url <- "https://example.com/sitemap.xml"
    context$root <- "https://example.com"
    context$direct_children <- c(
      "https://example.com/child-1.xml",
      "https://example.com/child-2.xml"
    )
    context$body_map <- list2env(list(
      "https://example.com/sitemap.xml" = idx_fixture("index-simple.xml"),
      "https://example.com/child-1.xml" = idx_urlset("https://example.com/a"),
      "https://example.com/child-2.xml" = idx_urlset("https://example.com/b")
    ))
  }

  given(
    "fixture {string} referencing two child sitemaps",
    function(name, context) idx_simple_setup(context)
  )

  # "the index fixture {string}" (not the bare "fixture {string}", which the
  # parse feature already owns) — cucumber step definitions are global.
  given(
    "the index fixture {string}",
    function(name, context) idx_simple_setup(context)
  )

  given(
    "a sitemapindex that lists the same child URL twice",
    function(context) {
      context$index_url <- "https://example.com/sitemap.xml"
      context$body_map <- list2env(list(
        "https://example.com/sitemap.xml" = idx_fixture(
          "index-duplicate-child.xml"
        ),
        "https://example.com/child-1.xml" = idx_urlset("https://example.com/a")
      ))
    }
  )

  given(
    "fixture {string} where the index lists itself as a child",
    function(name, context) {
      context$index_url <- "https://example.com/index-self-ref.xml"
      context$body_map <- list2env(list(
        "https://example.com/index-self-ref.xml" = idx_fixture(
          "index-self-ref.xml"
        ),
        "https://example.com/child-1.xml" = idx_urlset("https://example.com/a")
      ))
    }
  )

  given(
    "fixture {string} where index A points to B and B points to A",
    function(name, context) {
      a <- "https://example.com/index-cycle-ab.xml"
      b <- "https://example.com/index-b.xml"
      context$index_url <- a
      context$cycle_b <- b
      context$body_map <- list2env(stats::setNames(
        list(idx_fixture("index-cycle-ab.xml"), idx_index(a)),
        c(a, b)
      ))
    }
  )

  given(
    "fixture {string} with nesting deeper than 3 levels",
    function(name, context) {
      context$index_url <- "https://example.com/index-deep.xml"
      context$deep_leaf <- "https://example.com/deep-4.xml"
      context$body_map <- list2env(list(
        "https://example.com/index-deep.xml" = idx_fixture("index-deep.xml"),
        "https://example.com/deep-1.xml" = idx_index(
          "https://example.com/deep-2.xml"
        ),
        "https://example.com/deep-2.xml" = idx_index(
          "https://example.com/deep-3.xml"
        ),
        "https://example.com/deep-3.xml" = idx_index(
          "https://example.com/deep-4.xml"
        ),
        "https://example.com/deep-4.xml" = idx_urlset(
          "https://example.com/deep"
        )
      ))
    }
  )

  given(
    "a sitemapindex that declares more child URLs than the configured cap",
    function(context) {
      context$index_url <- "https://example.com/sitemap.xml"
      context$index_limits <- sitemapr_test_call(
        "index_limits",
        max_children = 2L
      )
      context$capped_out <- "https://example.com/c3.xml"
      context$body_map <- list2env(list(
        "https://example.com/sitemap.xml" = idx_fixture("index-over-cap.xml"),
        "https://example.com/c1.xml" = idx_urlset("https://example.com/1"),
        "https://example.com/c2.xml" = idx_urlset("https://example.com/2"),
        "https://example.com/c3.xml" = idx_urlset("https://example.com/3")
      ))
    }
  )

  given(
    "fixture {string} where a child is itself a sitemapindex",
    function(name, context) {
      context$index_url <- "https://example.com/index-nested.xml"
      context$body_map <- list2env(list(
        "https://example.com/index-nested.xml" = idx_fixture(
          "index-nested.xml"
        ),
        "https://example.com/nested-index.xml" = idx_index(
          "https://example.com/leaf.xml"
        ),
        "https://example.com/leaf.xml" = idx_urlset("https://example.com/deep")
      ))
    }
  )

  # --- when ------------------------------------------------------------------

  when("I call read_sitemap on the index", function(context) {
    idx_run_read(context)
  })

  when("I call read_sitemap on index A", function(context) {
    idx_run_read(context)
  })

  when("I call read_sitemap on the root index", function(context) {
    idx_run_read(context)
  })

  when("I call read_sitemap on the parent", function(context) {
    idx_run_read(context)
  })

  when(
    "I call read_sitemap with the default child count cap",
    function(context) idx_run_read(context)
  )

  when("I call sitemap_tree on the index", function(context) {
    idx_run_tree(context)
  })

  # --- then ------------------------------------------------------------------

  then("rows from both child sitemaps appear in the result", function(context) {
    testthat::expect_true("https://example.com/a" %in% context$result$loc)
    testthat::expect_true("https://example.com/b" %in% context$result$loc)
  })

  then("the tree depth for child rows is 1", function(context) {
    # read_sitemap() returns rows, not a tree; depth 1 means every row was
    # contributed by a direct (one-level-deep) child of the index.
    testthat::expect_true(all(
      context$result$source_sitemap %in% context$direct_children
    ))
  })

  then("each child row carries depth 1", function(context) {
    kids <- context$tree[context$tree$provenance == "child-of-index", ]
    testthat::expect_gt(nrow(kids), 0L)
    testthat::expect_true(all(kids$depth == 1L))
  })

  then("parent_sitemap references the index URL", function(context) {
    kids <- context$tree[context$tree$provenance == "child-of-index", ]
    testthat::expect_true(all(kids$parent_sitemap == context$index_url))
  })

  then("provenance is {string}", function(provenance, context) {
    kids <- context$tree[context$tree$depth == 1L, ]
    testthat::expect_true(all(kids$provenance == provenance))
  })

  then("the child is fetched and parsed exactly once", function(context) {
    child <- "https://example.com/child-1.xml"
    testthat::expect_identical(sum(context$requested == child), 1L)
    testthat::expect_identical(nrow(context$result), 1L)
  })

  then("the cycle is detected", function(context) {
    testthat::expect_true(idx_has_problem(context, "cycle"))
  })

  then(
    "an INDEX_CYCLE_DETECTED warning finding is produced",
    function(context) {
      p <- context$problems
      hit <- p$category == "index-expansion" &
        grepl("cycle", p$message, fixed = TRUE)
      testthat::expect_true(any(hit))
      testthat::expect_true(all(p$severity[hit] == "warning"))
    }
  )

  then("the self-reference is not followed", function(context) {
    # The index is fetched once (the entry fetch); the self-listing child shares
    # its identity key and is never re-fetched.
    testthat::expect_identical(sum(context$requested == context$index_url), 1L)
  })

  then("the cycle is detected at the second visit of A", function(context) {
    testthat::expect_true(idx_has_problem(context, "cycle"))
    # A is fetched once (entry); B once; the loop back to A is not followed.
    testthat::expect_identical(sum(context$requested == context$index_url), 1L)
  })

  then(
    "an INDEX_CYCLE_DETECTED finding is produced for the repeated URL",
    function(context) {
      p <- context$problems
      testthat::expect_true(any(
        p$category == "index-expansion" &
          grepl("cycle", p$message, fixed = TRUE) &
          p$subject_ref == context$index_url
      ))
    }
  )

  then("expansion stops without infinite recursion", function(context) {
    testthat::expect_identical(sum(context$requested == context$cycle_b), 1L)
  })

  then("an INDEX_DEPTH_EXCEEDED finding is produced", function(context) {
    testthat::expect_true(idx_has_problem(context, "depth limit"))
  })

  then("no children beyond depth 3 are fetched", function(context) {
    testthat::expect_false(context$deep_leaf %in% context$requested)
  })

  then("only the capped number of children are expanded", function(context) {
    testthat::expect_false(context$capped_out %in% context$requested)
    testthat::expect_identical(nrow(context$result), 2L)
  })

  then("an INDEX_CHILD_COUNT_EXCEEDED finding is produced", function(context) {
    testthat::expect_true(idx_has_problem(context, "cap"))
  })

  then("a SITEMAP_INDEX_NESTED warning finding is produced", function(context) {
    p <- context$problems
    hit <- p$category == "index-expansion" & grepl("[Nn]ested", p$message)
    testthat::expect_true(any(hit))
    testthat::expect_true(all(p$severity[hit] == "warning"))
  })

  then(
    "rows from the nested index's children are still present in the result",
    function(context) {
      testthat::expect_true("https://example.com/deep" %in% context$result$loc)
    }
  )

  then(
    "the tree rows form a connected parent-child chain from root to each leaf",
    function(context) {
      tree <- context$tree
      kids <- tree[!is.na(tree$parent_sitemap), ]
      # Every parented row's parent is itself a row in the tree (connected).
      testthat::expect_true(all(kids$parent_sitemap %in% tree$sitemap_url))
      # At least one expanded leaf exists below the discovered root.
      testthat::expect_true(any(tree$depth == 1L))
    }
  )
}
