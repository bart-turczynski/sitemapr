# Unit tests for audit_sitemap() (R/audit-pipeline.R; SITE-zkjoglmx).
#
# The acceptance bar is EQUIVALENCE: a single-pass audit must yield the same
# typed rows as read_sitemap() and the same findings as validate_sitemap(),
# fetching a remote root (and its index children) exactly ONCE. Fully offline:
# local fixtures for equivalence; httr2 mocks with a fetch counter for the
# single-fetch proof. No snapshots (none exist in this suite).

audit_fixture <- function(name) test_path("fixtures", name)

# Drop the read_sitemap() companion attributes so the typed tibble compares
# cleanly against the (attribute-free) audit `urls` component.
audit_strip_attrs <- function(x) {
  attr(x, "sources") <- NULL
  attr(x, "problems") <- NULL
  x
}

au_urlset_body <- function(...) {
  locs <- vapply(
    c(...),
    function(u) sprintf("<url><loc>%s</loc></url>", u),
    character(1)
  )
  paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
    paste(locs, collapse = ""),
    "</urlset>"
  )
}

au_index_body <- function(...) {
  locs <- vapply(
    c(...),
    function(u) sprintf("<sitemap><loc>%s</loc></sitemap>", u),
    character(1)
  )
  paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
    paste(locs, collapse = ""),
    "</sitemapindex>"
  )
}

# An httr2 mock dispatching on request URL, counting every call into `sink` so a
# test can prove each URL is fetched exactly once.
au_counting_mock <- function(map, sink) {
  function(req) {
    sink$urls <- c(sink$urls, req$url)
    body <- map[[req$url]]
    if (is.null(body)) {
      return(httr2::response(status_code = 404L, url = req$url))
    }
    httr2::response(
      status_code = 200L,
      url = req$url,
      headers = list("Content-Type" = "application/xml; charset=UTF-8"),
      body = charToRaw(body)
    )
  }
}

# ---- structure ---------------------------------------------------------------

test_that("audit_sitemap() returns a valid sitemap_audit", {
  a <- audit_sitemap(audit_fixture("valid-minimal.xml"))
  expect_s3_class(a, "sitemap_audit")
  expect_s3_class(audit_urls(a), "tbl_df")
  expect_s3_class(audit_findings(a), "tbl_df")
  # The container validates its own column contracts on construction.
  expect_silent(sitemapr:::validate_sitemap_audit(a))
})

# ---- EQUIVALENCE: the core acceptance ----------------------------------------

test_that("audit rows and findings equal read/validate on every fixture", {
  files <- list.files(
    test_path("fixtures"),
    pattern = "[.](xml|txt)$",
    full.names = TRUE
  )
  corpus <- list.files(
    test_path("fixtures", "corpus"),
    pattern = "[.](xml|txt|gz)$",
    recursive = TRUE,
    full.names = TRUE
  )
  files <- c(files, corpus)
  expect_gt(length(files), 0L)

  for (f in files) {
    a <- suppressWarnings(audit_sitemap(f))

    read_ok <- tryCatch(
      {
        rs <- suppressWarnings(read_sitemap(f))
        TRUE
      },
      error = function(e) FALSE
    )
    if (read_ok) {
      expect_equal(
        audit_urls(a),
        audit_strip_attrs(rs),
        ignore_attr = TRUE,
        info = paste("rows:", f)
      )
    }

    validate_ok <- tryCatch(
      {
        vs <- suppressWarnings(validate_sitemap(f))
        TRUE
      },
      error = function(e) FALSE
    )
    if (validate_ok) {
      expect_equal(
        audit_findings(a),
        vs,
        ignore_attr = TRUE,
        info = paste("findings:", f)
      )
    }
  }
})

test_that("audit findings honor mode, matching validate_sitemap()", {
  f <- audit_fixture("schema-invalid-urlset.xml")
  for (m in c("strict", "non-strict")) {
    a <- audit_sitemap(f, mode = m)
    expect_equal(
      audit_findings(a),
      validate_sitemap(f, mode = m),
      ignore_attr = TRUE
    )
  }
})

# ---- SINGLE FETCH: one pass supplies both rows and findings ------------------

test_that("a URL index is fetched once and matches read + validate", {
  root <- "https://example.com/sitemap_index.xml"
  c1 <- "https://example.com/child1.xml"
  c2 <- "https://example.com/child2.xml"
  map <- list()
  map[[root]] <- au_index_body(c1, c2)
  map[[c1]] <- au_urlset_body("https://example.com/a", "https://example.com/a")
  map[[c2]] <- au_urlset_body("https://example.com/b")

  # Audit: one pass.
  sink <- new.env(parent = emptyenv())
  sink$urls <- character(0)
  httr2::local_mocked_responses(au_counting_mock(map, sink))
  a <- audit_sitemap(root)
  audit_urls_fetched <- sink$urls

  # Two-call baseline for the row/finding comparison and the fetch-count delta.
  sink2 <- new.env(parent = emptyenv())
  sink2$urls <- character(0)
  httr2::local_mocked_responses(au_counting_mock(map, sink2))
  rs <- read_sitemap(root)
  vs <- validate_sitemap(root)

  # One fetch per distinct URL (root + two children), none fetched twice.
  expect_setequal(unique(audit_urls_fetched), c(root, c1, c2))
  expect_true(all(table(audit_urls_fetched) == 1L))
  expect_length(audit_urls_fetched, 3L)
  # The two-call path fetches everything twice.
  expect_length(sink2$urls, 6L)

  expect_equal(audit_urls(a), audit_strip_attrs(rs), ignore_attr = TRUE)
  expect_equal(audit_findings(a), vs, ignore_attr = TRUE)
  # The expansion enriches the audit with the discovery tree + per-source rows.
  expect_gt(nrow(audit_tree(a)), 0L)
  expect_identical(nrow(audit_sources(a)), 3L)
})

test_that("a URL urlset root is fetched exactly once", {
  root <- "https://example.com/sitemap.xml"
  map <- list()
  map[[root]] <- au_urlset_body("https://example.com/p1")

  sink <- new.env(parent = emptyenv())
  sink$urls <- character(0)
  httr2::local_mocked_responses(au_counting_mock(map, sink))
  a <- audit_sitemap(root)

  expect_identical(sink$urls, root)
  expect_identical(nrow(audit_urls(a)), 1L)
})

# ---- partial failures stay attributable --------------------------------------

test_that("a failed source yields a coherent audit with the failure recorded", {
  missing <- file.path(tempdir(), "sitemapr-audit-missing.xml")
  if (file.exists(missing)) {
    unlink(missing)
  }
  a <- suppressWarnings(audit_sitemap(
    c(audit_fixture("valid-minimal.xml"), missing)
  ))

  expect_s3_class(a, "sitemap_audit")
  # The good source still contributes its rows.
  expect_gt(nrow(audit_urls(a)), 0L)
  # The failure surfaces on both attributable surfaces.
  expect_true("FETCH_FAILED" %in% audit_findings(a)$code)
  expect_true(any(grepl(
    "sitemapr-audit-missing",
    audit_problems(a)$subject_ref,
    fixed = TRUE
  )))
})

# ---- policy threading --------------------------------------------------------

test_that("audit threads the request policy to root and index children", {
  root <- "https://example.com/idx.xml"
  child <- "https://example.com/leaf.xml"
  map <- list()
  map[[root]] <- au_index_body(child)
  map[[child]] <- au_urlset_body("https://example.com/1")

  sink <- new.env(parent = emptyenv())
  sink$urls <- character(0)
  httr2::local_mocked_responses(au_counting_mock(map, sink))
  seen <- new.env(parent = emptyenv())
  seen$urls <- character(0)
  policy <- request_policy(prepare = function(req, ctx) {
    seen$urls <- c(seen$urls, ctx$url)
    req
  })
  audit_sitemap(root, policy = policy)

  expect_true(root %in% seen$urls)
  expect_true(child %in% seen$urls)
})

# ---- streaming mode (SITE-lzynozgl) ------------------------------------------
#
# collect = FALSE / on_urls hands each completed leaf's rows to a callback and
# does NOT retain them, bounding peak retained-row memory to one leaf. Findings,
# sources, problems, and tree stay identical to a collected audit.

test_that("streaming a URL index keeps findings, empties urls, records count", {
  root <- "https://example.com/sitemap_index.xml"
  c1 <- "https://example.com/child1.xml"
  c2 <- "https://example.com/child2.xml"
  map <- list()
  map[[root]] <- au_index_body(c1, c2)
  map[[c1]] <- au_urlset_body("https://example.com/a", "https://example.com/b")
  map[[c2]] <- au_urlset_body("https://example.com/c")

  s1 <- new.env(parent = emptyenv())
  s1$urls <- character(0)
  httr2::local_mocked_responses(au_counting_mock(map, s1))
  collected <- audit_sitemap(root)

  s2 <- new.env(parent = emptyenv())
  s2$urls <- character(0)
  httr2::local_mocked_responses(au_counting_mock(map, s2))
  seen <- new.env(parent = emptyenv())
  seen$leaves <- 0L
  seen$rows <- 0L
  seen$srcs <- character(0)
  streamed <- audit_sitemap(
    root,
    collect = FALSE,
    on_urls = function(rows, source) {
      seen$leaves <- seen$leaves + 1L
      seen$rows <- seen$rows + nrow(rows)
      seen$srcs <- c(seen$srcs, as.character(source$final_url))
    }
  )

  # Findings are COMPLETE and identical to the collected audit (per-leaf).
  expect_equal(
    audit_findings(streamed),
    audit_findings(collected),
    ignore_attr = TRUE
  )
  # The callback fired once per completed leaf, with per-source provenance.
  expect_identical(seen$leaves, 2L)
  expect_setequal(seen$srcs, c(c1, c2))
  # urls is empty; the streamed count is recorded and matches the collected.
  expect_identical(nrow(audit_urls(streamed)), 0L)
  n_collected <- as.numeric(nrow(audit_urls(collected)))
  expect_identical(
    as.numeric(attr(audit_urls(streamed), "streamed_row_count")),
    n_collected
  )
  expect_identical(as.numeric(seen$rows), n_collected)
  # sources and tree are unchanged from the collected audit.
  expect_identical(
    nrow(audit_sources(streamed)),
    nrow(audit_sources(collected))
  )
  expect_identical(nrow(audit_tree(streamed)), nrow(audit_tree(collected)))
})

test_that("streaming a non-index urlset emits one leaf and empties urls", {
  f <- audit_fixture("valid-minimal.xml")
  seen <- new.env(parent = emptyenv())
  seen$n <- 0L
  seen$rows <- 0L
  a <- audit_sitemap(
    f,
    collect = FALSE,
    on_urls = function(rows, source) {
      seen$n <- seen$n + 1L
      seen$rows <- seen$rows + nrow(rows)
    }
  )

  expect_identical(seen$n, 1L)
  expect_gt(seen$rows, 0L)
  expect_identical(nrow(audit_urls(a)), 0L)
  expect_identical(
    as.numeric(attr(audit_urls(a), "streamed_row_count")),
    as.numeric(seen$rows)
  )
  # Findings still match the standalone validate_sitemap().
  expect_equal(audit_findings(a), validate_sitemap(f), ignore_attr = TRUE)
})

test_that("a throwing streaming callback aborts the audit cleanly", {
  root <- "https://example.com/sitemap_index.xml"
  c1 <- "https://example.com/child1.xml"
  map <- list()
  map[[root]] <- au_index_body(c1)
  map[[c1]] <- au_urlset_body("https://example.com/a")
  s <- new.env(parent = emptyenv())
  s$urls <- character(0)
  httr2::local_mocked_responses(au_counting_mock(map, s))

  expect_error(
    audit_sitemap(
      root,
      collect = FALSE,
      on_urls = function(rows, source) stop("boom")
    ),
    class = "sitemapr_stream_callback_error"
  )

  cnd <- rlang::catch_cnd(audit_sitemap(
    root,
    collect = FALSE,
    on_urls = function(rows, source) stop("boom")
  ))
  expect_identical(cnd$leaf, c1)
})

test_that("on_urls must be a function", {
  expect_error(
    audit_sitemap(audit_fixture("valid-minimal.xml"), on_urls = "nope"),
    class = "sitemapr_bad_input"
  )
})
