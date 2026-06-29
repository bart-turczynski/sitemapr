# Cucumber step definitions for parse_formats.feature (SITE-saqolkqu).
#
# testthat sources `setup-*.R` before the test files, so these steps register
# before `cucumber::run()` executes the active features.
#
# Offline / CRAN-safe: local-file scenarios read hand-authored text fixtures
# from tests/testthat/fixtures/ (the .xml/.txt ones) or build .gz/.tar.gz
# fixtures in-memory at step time (the binary ones are generated, never
# committed, so the path-traversal archive is deterministic and the repo stays
# text-only). URL scenarios use httr2::local_mocked_responses, installed inside
# the `when` step (the mock is scoped to the calling frame, so a `given` step
# cannot install it; it would be torn down before the fetch).
#
# Step-description gotcha (SITE-qalrtbes): cucumber compiles a step description
# to an UNESCAPED, anchored regex (`^\s*<desc>\s*$`). Literal regex-special
# characters in the feature wording must therefore be escaped in the
# description — see the "(if any)" step below, where the parentheses are
# backslash-escaped so the regex matches the literal text.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  # ---- builders -------------------------------------------------------------

  parse_urlset_xml <- function(...) {
    urls <- paste0("<url><loc>", c(...), "</loc></url>", collapse = "")
    paste0(
      '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      urls,
      "</urlset>"
    )
  }

  parse_read_fixture_text <- function(name) {
    paste(readLines(test_path("fixtures", name), warn = FALSE), collapse = "\n")
  }

  # Gzip `text` to a fresh tempfile and return its path.
  parse_gzip_to_file <- function(text, ext = ".gz") {
    path <- tempfile(fileext = ext)
    con <- gzfile(path, "wb")
    writeBin(charToRaw(text), con)
    close(con)
    path
  }

  # Minimal ustar header (the reader does not verify the checksum, so the
  # checksum field is left as the conventional spaces).
  parse_tar_header <- function(name, size, typeflag = "0") {
    h <- raw(512L)
    put <- function(h, off, s) {
      b <- charToRaw(s)
      h[(off + 1L):(off + length(b))] <- b
      h
    }
    h <- put(h, 0L, name)
    h <- put(h, 124L, sprintf("%011o", size))
    h <- put(h, 148L, "        ")
    h <- put(h, 156L, typeflag)
    h <- put(h, 257L, "ustar")
    put(h, 263L, "00")
  }

  # Build a .tar.gz at `path` from a list of list(name=, content=, typeflag=).
  parse_tar_gz <- function(entries, path) {
    blocks <- raw(0L)
    for (e in entries) {
      tf <- if (is.null(e$typeflag)) "0" else e$typeflag
      content <- e$content
      if (is.null(content)) {
        content <- raw(0L)
      }
      if (is.character(content)) {
        content <- charToRaw(content)
      }
      pad <- length(content) %% 512L
      padded <- if (pad == 0L) content else c(content, raw(512L - pad))
      blocks <- c(blocks, parse_tar_header(e$name, length(content), tf), padded)
    }
    blocks <- c(blocks, raw(1024L)) # end-of-archive marker
    con <- gzfile(path, "wb")
    writeBin(blocks, con)
    close(con)
    path
  }

  # A mock dispatching on request URL via a named map of bodies; unknown URLs
  # get a 404 (used to exercise an unfetchable index child).
  parse_mock_by_url <- function(map, content_type = "application/xml") {
    function(req) {
      body <- map[[req$url]]
      if (is.null(body)) {
        return(httr2::response(status_code = 404L, url = req$url))
      }
      httr2::response(
        status_code = 200L,
        url = req$url,
        headers = list("Content-Type" = content_type),
        body = charToRaw(body)
      )
    }
  }

  # Resolve a bare local fixture name to a path read_sitemap can consume,
  # building the compressed fixtures on demand.
  parse_prepare_fixture <- function(name, context) {
    if (identical(name, "valid.xml.gz")) {
      xml <- parse_read_fixture_text("valid-minimal.xml")
      # The uncompressed equivalent, for the "matches" comparison.
      plain <- tempfile(fileext = ".xml")
      writeBin(charToRaw(xml), plain)
      context$expected <- read_sitemap(plain)
      return(parse_gzip_to_file(xml, ext = ".xml.gz"))
    }
    if (identical(name, "malformed.xml.gz")) {
      path <- tempfile(fileext = ".xml.gz")
      # gzip magic followed by garbage: a corrupt stream.
      writeBin(as.raw(c(0x1F, 0x8B, 0x08, 0x00, 0x11, 0x22, 0x33)), path)
      return(path)
    }
    # A committed text fixture (.xml / .txt).
    test_path("fixtures", name)
  }

  # Perform read_sitemap, capturing result / error / warning so the matching
  # `then` steps can assert whichever outcome occurred.
  parse_read_capture <- function(context) {
    context$error <- NULL
    context$warning <- NULL
    if (!is.null(context$mock)) {
      httr2::local_mocked_responses(context$mock)
    }
    context$result <- withCallingHandlers(
      tryCatch(
        read_sitemap(context$source),
        error = function(e) {
          context$error <- e
          NULL
        }
      ),
      warning = function(w) {
        context$warning <- w
        invokeRestart("muffleWarning")
      }
    )
  }

  # ---- GIVEN ----------------------------------------------------------------

  given("fixture {string}", function(name, context) {
    context$source <- parse_prepare_fixture(name, context)
  })

  given(
    "fixture {string} containing a lastmod value",
    function(name, context) {
      context$source <- test_path("fixtures", name)
    }
  )

  given(
    "fixture {string} with image extension entries",
    function(name, context) {
      context$source <- test_path("fixtures", name)
    }
  )

  given(
    "fixture {string} with a field sitemap validators would flag",
    function(name, context) {
      context$source <- test_path("fixtures", name)
    }
  )

  given(
    "a local fixture {string} containing two sitemap files",
    function(name, context) {
      path <- tempfile(fileext = ".tar.gz")
      parse_tar_gz(
        list(
          list(
            name = "a.xml",
            content = parse_urlset_xml(
              "https://example.com/a1",
              "https://example.com/a2"
            )
          ),
          list(
            name = "b.xml",
            content = parse_urlset_xml(
              "https://example.com/b1"
            )
          )
        ),
        path
      )
      context$source <- path
      context$expected_locs <- c(
        "https://example.com/a1",
        "https://example.com/a2",
        "https://example.com/b1"
      )
    }
  )

  given(
    "a local fixture {string} containing one sitemap and one README",
    function(name, context) {
      path <- tempfile(fileext = ".tar.gz")
      parse_tar_gz(
        list(
          list(
            name = "sitemap.xml",
            content = parse_urlset_xml(
              "https://example.com/p1"
            )
          ),
          list(
            name = "README.md",
            content = "# Project\nNotes, not a sitemap.\n"
          )
        ),
        path
      )
      context$source <- path
      context$sitemap_locs <- "https://example.com/p1"
    }
  )

  given(
    "a local fixture {string} with a {string} entry",
    function(name, evil, context) {
      dir <- file.path(tempdir(), paste0("arc-", as.integer(runif(1, 1, 1e8))))
      dir.create(dir, showWarnings = FALSE)
      path <- file.path(dir, "path-traversal.tar.gz")
      parse_tar_gz(
        list(
          list(
            name = "ok.xml",
            content = parse_urlset_xml(
              "https://example.com/ok"
            )
          ),
          list(
            name = paste0(evil, ".xml"),
            content = parse_urlset_xml(
              "https://evil.example.com/owned"
            )
          )
        ),
        path
      )
      context$source <- path
      # Where a "../evil.xml" entry WOULD land if extraction escaped the
      # archive's directory; it must never be created (extraction is in-memory).
      context$traversal_target <- normalizePath(
        file.path(dir, "..", "evil.xml"),
        mustWork = FALSE
      )
    }
  )

  given("a sitemap index with two child XML files", function(context) {
    index_url <- "https://example.com/sitemap_index.xml"
    c1 <- "https://example.com/child-1.xml"
    c2 <- "https://example.com/child-2.xml"
    map <- list()
    map[[index_url]] <- parse_read_fixture_text("index-simple.xml")
    map[[c1]] <- parse_urlset_xml(
      "https://example.com/a1",
      "https://example.com/a2"
    )
    map[[c2]] <- parse_urlset_xml("https://example.com/b1")
    context$source <- index_url
    context$index_url <- index_url
    context$child_urls <- c(c1, c2)
    context$mock <- parse_mock_by_url(map)
  })

  given("a URL that returns a 500 response", function(context) {
    context$source <- "https://example.com/sitemap.xml"
    context$mock <- function(req) {
      httr2::response(status_code = 500L, url = req$url)
    }
  })

  # ---- WHEN -----------------------------------------------------------------

  when("I call read_sitemap on the fixture", function(context) {
    parse_read_capture(context)
  })
  when("I call read_sitemap on the archive path", function(context) {
    parse_read_capture(context)
  })
  # NB: "on the index" (bare) is owned by fetch_classification.feature's
  # skip-stub; cucumber's step registry is global, so this parse scenario uses a
  # distinct wording to avoid resolving to that stub.
  when("I call read_sitemap on the sitemap index", function(context) {
    parse_read_capture(context)
  })
  when("I call read_sitemap on that URL", function(context) {
    parse_read_capture(context)
  })

  # ---- THEN -----------------------------------------------------------------

  parse_contract_cols <- c(
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

  then("the result is a tibble", function(context) {
    expect_s3_class(context$result, "tbl_df")
  })

  then(
    paste0(
      "the columns include loc, lastmod, changefreq, priority, images, ",
      "video, news, alternates, source_sitemap"
    ),
    function(context) {
      expect_true(all(parse_contract_cols %in% names(context$result)))
    }
  )

  then("the lastmod column has class POSIXct", function(context) {
    expect_s3_class(context$result$lastmod, "POSIXct")
  })

  then("the images column is a list-column", function(context) {
    expect_type(context$result$images, "list")
  })

  then(
    "each element contains the structured image data for that URL",
    function(context) {
      imgs <- context$result$images
      idx <- which(!vapply(imgs, is.null, logical(1L)))
      expect_gt(length(idx), 0L)
      first <- imgs[[idx[[1L]]]][[1L]]
      expect_match(first$loc[[1L]], "img/1.jpg", fixed = TRUE)
    }
  )

  then("each row has a non-NA loc", function(context) {
    expect_true(all(!is.na(context$result$loc) & nzchar(context$result$loc)))
  })

  then("lastmod, changefreq, priority are NA", function(context) {
    expect_true(all(is.na(context$result$lastmod)))
    expect_true(all(is.na(context$result$changefreq)))
    expect_true(all(is.na(context$result$priority)))
  })

  then("the result matches the uncompressed equivalent", function(context) {
    drop_provenance <- function(t) {
      t <- as.data.frame(t)
      t$source_sitemap <- NULL
      attributes(t)[c("sources", "problems")] <- NULL
      t
    }
    expect_equal(
      drop_provenance(context$result),
      drop_provenance(context$expected)
    )
  })

  then("rows from both sitemap files appear in the result", function(context) {
    expect_true(all(context$expected_locs %in% context$result$loc))
  })

  then(
    "the source_sitemap column distinguishes the two files",
    function(context) {
      expect_identical(length(unique(context$result$source_sitemap)), 2L)
    }
  )

  then("only sitemap rows appear in the result", function(context) {
    expect_setequal(context$result$loc, context$sitemap_locs)
  })

  then(
    "the problems attribute records the skipped non-sitemap file",
    function(context) {
      problems <- attr(context$result, "problems")
      expect_gt(nrow(problems), 0L)
      expect_true(any(grepl("README", problems$subject_ref, fixed = TRUE)))
    }
  )

  then("the traversal entry is rejected", function(context) {
    expect_false("https://evil.example.com/owned" %in% context$result$loc)
    problems <- attr(context$result, "problems")
    expect_true(any(problems$severity == "warning"))
  })

  then("no file is written outside the extraction boundary", function(context) {
    expect_false(file.exists(context$traversal_target))
  })

  then("a sitemapr-classed error condition is raised", function(context) {
    expect_false(is.null(context$error))
    expect_true(any(grepl("^sitemapr_", class(context$error))))
  })

  then(
    "the condition class indicates a decompression failure",
    function(context) {
      expect_s3_class(context$error, "sitemapr_decompression_error")
    }
  )

  then(
    paste0(
      "each row's source_sitemap value is the URL of the child that ",
      "contributed it"
    ),
    function(context) {
      expect_true(all(context$result$source_sitemap %in% context$child_urls))
    }
  )

  # The "(if any)" parentheses are literal in the feature; escape them so the
  # anchored, unescaped step regex matches the literal text (SITE-qalrtbes).
  then(
    "rows from the index itself \\(if any\\) carry the index URL",
    function(context) {
      expect_false(any(context$result$source_sitemap == context$index_url))
    }
  )

  then(
    "the return value is a tibble of URL rows, not a findings tibble",
    function(context) {
      expect_s3_class(context$result, "tbl_df")
      expect_true("loc" %in% names(context$result))
    }
  )

  then("no validate_sitemap-style code column is present", function(context) {
    expect_false("code" %in% names(context$result))
  })

  then("an error-class condition is raised", function(context) {
    expect_false(is.null(context$error))
    expect_s3_class(context$error, "error")
  })

  then("the error identifies the URL and the HTTP status", function(context) {
    expect_identical(context$error$status, 500L)
    expect_false(is.null(context$error$url))
    expect_true(nzchar(context$error$url))
  })

  then("the result has a sources attribute", function(context) {
    expect_false(is.null(attr(context$result, "sources")))
  })

  then(
    "the attribute contains fetch metadata for each source processed",
    function(context) {
      sources <- attr(context$result, "sources")
      expect_gt(nrow(sources), 0L)
      expect_true(all(c("final_url", "format") %in% names(sources)))
    }
  )
}
