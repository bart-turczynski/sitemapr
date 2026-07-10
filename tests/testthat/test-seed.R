# Unit tests for the explicit-seed entry points (R/seed.R): sitemap_tree(from =
# "sitemap") and sitemap_tree_from_bytes(). Offline: child fetches go through
# httr2::local_mocked_responses (CRAN-safe).

seed_urlset <- function(...) {
  urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
  paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    "</urlset>"
  )
}

seed_index <- function(...) {
  kids <- paste0("<sitemap><loc>", c(...), "</loc></sitemap>", collapse = "")
  paste0(
    '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    kids,
    "</sitemapindex>"
  )
}

seed_mock <- function(body_map) {
  function(req) {
    body <- body_map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    if (is.character(body)) {
      body <- charToRaw(body)
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/xml"),
      body = body
    )
  }
}

# ---- sitemap_tree_from_bytes(): leaf, no network -----------------------------

test_that("bytes leaf seed parses with no network access and provenance seed", {
  # No mocked responses registered: any HTTP call would error, proving the leaf
  # path is fully offline.
  tree <- sitemap_tree_from_bytes(
    seed_urlset("https://ex.com/a", "https://ex.com/b"),
    source_url = "https://ex.com/sitemap.xml"
  )
  expect_named(tree, sitemap_tree_cols())
  expect_identical(nrow(tree), 1L)
  expect_identical(tree$depth, 0L)
  expect_identical(tree$status, "accepted")
  expect_identical(tree$page_count, 2L)
  expect_false(tree$gzip)
  expect_identical(tree$provenance, "seed")
  expect_true(is.na(tree$parent_sitemap))
})

test_that("bytes leaf seed accepts a raw vector as well as a string", {
  tree <- sitemap_tree_from_bytes(
    charToRaw(seed_urlset("https://ex.com/a")),
    source_url = "https://ex.com/sitemap.xml"
  )
  expect_identical(tree$page_count, 1L)
  expect_identical(tree$provenance, "seed")
})

# ---- sitemap_tree_from_bytes(): index expands children over the network ------

test_that("bytes index seed expands children over the network", {
  httr2::local_mocked_responses(seed_mock(list(
    "https://ex.com/a.xml" = seed_urlset(
      "https://ex.com/1",
      "https://ex.com/2"
    ),
    "https://ex.com/b.xml" = seed_urlset("https://ex.com/3")
  )))
  tree <- sitemap_tree_from_bytes(
    seed_index("https://ex.com/a.xml", "https://ex.com/b.xml"),
    source_url = "https://ex.com/sitemap_index.xml"
  )
  expect_identical(nrow(tree), 3L)

  root <- tree[tree$depth == 0L, ]
  expect_identical(root$provenance, "seed")
  expect_identical(root$page_count, 2L) # two child sitemaps

  kids <- tree[tree$depth == 1L, ]
  expect_setequal(
    kids$sitemap_url,
    c("https://ex.com/a.xml", "https://ex.com/b.xml")
  )
  expect_true(all(kids$provenance == "child-of-index"))
  expect_true(all(
    kids$parent_sitemap == "https://ex.com/sitemap_index.xml"
  ))
  expect_identical(sum(kids$page_count), 3L)
})

test_that("bytes index seed honours the child-count cap", {
  httr2::local_mocked_responses(seed_mock(list(
    "https://ex.com/a.xml" = seed_urlset("https://ex.com/1")
  )))
  tree <- sitemap_tree_from_bytes(
    seed_index("https://ex.com/a.xml", "https://ex.com/b.xml"),
    source_url = "https://ex.com/sitemap_index.xml",
    index_limits = index_limits(max_children = 1L)
  )
  # Root + the single expanded child (b.xml dropped by the cap).
  expect_identical(nrow(tree), 2L)
  expect_identical(
    tree$sitemap_url[tree$depth == 1L],
    "https://ex.com/a.xml"
  )
})

test_that("unparseable bytes yield a single rejected seed row, not an error", {
  tree <- sitemap_tree_from_bytes(
    "<!DOCTYPE html><html><body>not a sitemap</body></html>",
    source_url = "https://ex.com/sitemap.xml"
  )
  expect_identical(nrow(tree), 1L)
  expect_identical(tree$status, "rejected")
  expect_identical(tree$reason, "unparseable")
  expect_identical(tree$provenance, "seed")
})

test_that("sitemap_tree_from_bytes validates its inputs", {
  expect_error(
    sitemap_tree_from_bytes(42L, source_url = "https://ex.com/s.xml"),
    class = "sitemapr_bad_input"
  )
  expect_error(
    sitemap_tree_from_bytes(seed_urlset("https://ex.com/a"), source_url = NA),
    class = "sitemapr_bad_input"
  )
})

# ---- sitemap_tree(from = "sitemap"): exact-URL seed --------------------------

test_that("from = 'sitemap' fetches one URL and expands it, no catalog", {
  state <- new.env(parent = emptyenv())
  state$calls <- character(0)
  httr2::local_mocked_responses(function(req) {
    state$calls <- c(state$calls, req$url)
    body_map <- list(
      "https://ex.com/sitemap_index.xml" = seed_index("https://ex.com/a.xml"),
      "https://ex.com/a.xml" = seed_urlset(
        "https://ex.com/1",
        "https://ex.com/2"
      )
    )
    body <- body_map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/xml"),
      body = charToRaw(body)
    )
  })
  tree <- sitemap_tree("https://ex.com/sitemap_index.xml", from = "sitemap")

  expect_identical(nrow(tree), 2L)
  expect_identical(tree$provenance[tree$depth == 0L], "seed")
  expect_identical(
    tree$sitemap_url[tree$depth == 0L],
    "https://ex.com/sitemap_index.xml"
  )
  expect_identical(tree$provenance[tree$depth == 1L], "child-of-index")
  # Only the exact URL and its one child were fetched — no guessed-path catalog.
  expect_true("https://ex.com/sitemap_index.xml" %in% state$calls)
  expect_false("https://ex.com/sitemap.xml" %in% state$calls)
})

test_that("from = 'sitemap' returns a rejected seed row on a 404", {
  httr2::local_mocked_responses(seed_mock(list())) # all 404
  tree <- sitemap_tree("https://ex.com/nope.xml", from = "sitemap")
  expect_identical(nrow(tree), 1L)
  expect_identical(tree$status, "rejected")
  expect_identical(tree$reason, "not-found")
  expect_identical(tree$provenance, "seed")
})

test_that("from = 'sitemap' returns a rejected row on transport failure", {
  httr2::local_mocked_responses(function(req) {
    stop("simulated transport failure")
  })
  tree <- sitemap_tree("https://ex.com/sitemap.xml", from = "sitemap")
  expect_identical(tree$status, "rejected")
  expect_identical(tree$reason, "unreachable")
  expect_identical(tree$provenance, "seed")
})

test_that("seed fetch maps SSRF blocks to a rejected seed", {
  rec <- sitemapr_test_ns$create_source_records(
    "https://ex.com/sitemap.xml",
    as = "sitemap"
  )
  testthat::local_mocked_bindings(
    fetch_source = function(...) {
      rlang::abort("blocked", class = "sitemapr_ssrf_blocked")
    }
  )

  out <- sitemapr_test_ns$seed_fetch(
    rec,
    sitemapr_test_ns$default_user_agent(),
    sitemapr_test_ns$fetch_limits()
  )

  expect_identical(out$status, "rejected")
  expect_identical(out$reason, "blocked")
  expect_null(out$rec)
})

test_that("from = 'sitemap' rejects accepted bytes that fail parsing", {
  testthat::local_mocked_bindings(
    fetch_source = function(...) {
      rec <- sitemapr_test_ns$source_metadata(
        requested_url = "https://ex.com/bad.xml",
        final_url = "https://ex.com/bad.xml",
        status = 200L,
        error_class = NA_character_,
        format = "xml"
      )
      attr(rec, "body") <- charToRaw("<not-a-sitemap/>")
      rec
    }
  )

  tree <- sitemapr_test_ns$seed_tree_from_url(
    "https://ex.com/bad.xml",
    sitemapr_test_ns$default_user_agent(),
    sitemapr_test_ns$fetch_limits(),
    sitemapr_test_ns$index_limits()
  )

  expect_identical(tree$status, "rejected")
  expect_identical(tree$reason, "unparseable")
  expect_identical(tree$provenance, "seed")
})

test_that("from = 'sitemap' rejects a non-scalar x", {
  expect_error(
    sitemap_tree(c("a", "b"), from = "sitemap"),
    class = "sitemapr_bad_input"
  )
})

# ---- request policy propagation ----------------------------------------------

test_that("sitemap_tree_from_bytes threads the policy to index children", {
  httr2::local_mocked_responses(seed_mock(list(
    "https://ex.com/a.xml" = seed_urlset("https://ex.com/1")
  )))
  sink <- new.env(parent = emptyenv())
  sink$urls <- character(0)
  policy <- request_policy(prepare = function(req, ctx) {
    sink$urls <- c(sink$urls, ctx$url)
    req
  })
  sitemap_tree_from_bytes(
    seed_index("https://ex.com/a.xml"),
    source_url = "https://ex.com/sitemap_index.xml",
    policy = policy
  )
  # The in-memory root does no network; its index child fetch saw the policy.
  expect_true("https://ex.com/a.xml" %in% sink$urls)
})

test_that("sitemap_tree from = 'sitemap' threads the policy to root and kids", {
  root <- "https://ex.com/sitemap_index.xml"
  child <- "https://ex.com/a.xml"
  httr2::local_mocked_responses(seed_mock(list(
    "https://ex.com/sitemap_index.xml" = seed_index(child),
    "https://ex.com/a.xml" = seed_urlset("https://ex.com/1")
  )))
  sink <- new.env(parent = emptyenv())
  sink$urls <- character(0)
  policy <- request_policy(prepare = function(req, ctx) {
    sink$urls <- c(sink$urls, ctx$url)
    req
  })
  sitemap_tree(root, from = "sitemap", policy = policy)
  expect_true(root %in% sink$urls)
  expect_true(child %in% sink$urls)
})
