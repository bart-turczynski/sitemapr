# Cucumber step definitions for input_normalization.feature.
#
# testthat sources `setup-*.R` before the test files, so these steps are
# registered before `cucumber::run()` executes the active features.
#
# Guarded on `cucumber` being installed so the suggests-only R CMD check
# (`_R_CHECK_DEPENDS_ONLY_=true`, which CRAN runs) degrades gracefully: with the
# package absent the steps simply are not registered and test-cucumber.R skips.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  # --- GIVEN -----------------------------------------------------------------

  given("a direct sitemap URL {string}", function(x, context) {
    context$input <- x
    context$as <- "sitemap"
  })

  given("a site URL {string}", function(x, context) {
    context$input <- x
    context$as <- "site"
  })

  given("a local file path {string}", function(x, context) {
    context$input <- x
    context$as <- "sitemap"
  })

  given("a list of sitemap URLs:", function(table, context) {
    # cucumber treats the first table row as the header, so the first URL lands
    # in the column name. Reconstruct the full vector from header + body.
    context$input <- c(colnames(table), table[[1L]])
    context$as <- "sitemap"
  })

  given("a list with the same URL repeated twice", function(context) {
    u <- "https://example.com/sitemap.xml"
    context$input <- c(u, u)
    context$as <- "sitemap"
  })

  given("a list of {int} sitemap URLs", function(n, context) {
    context$input <- sprintf("https://example.com/sitemap%d.xml", seq_len(n))
    context$as <- "sitemap"
  })

  # The step description is compiled to a regex without escaping, so the literal
  # "+" chars in the feature text (scheme + host + path) are matched by ".".
  given(
    "two sitemap entries with the same scheme.host.path but different ports",
    function(context) {
      context$input <- c(
        "https://example.com:8080/sitemap.xml",
        "https://example.com:9090/sitemap.xml"
      )
      context$as <- "sitemap"
    }
  )

  # --- WHEN ------------------------------------------------------------------

  create_records_step <- function(context) {
    context$error <- NULL
    context$result <- tryCatch(
      sitemapr:::create_source_records(context$input, as = context$as),
      error = function(e) {
        context$error <- e
        NULL
      }
    )
  }

  when("I create source records", create_records_step)
  when("I create source records with default limits", create_records_step)
  when("sitemapr evaluates duplicate loc", create_records_step)

  # --- THEN ------------------------------------------------------------------

  then("the source record has provenance {string}", function(p, context) {
    expect_equal(context$result$provenance[[1L]], p)
  })

  then("the normalized URL preserves the https scheme", function(context) {
    expect_equal(context$result$scheme[[1L]], "https")
  })

  then("the normalized URL retains the http scheme", function(context) {
    expect_equal(context$result$scheme[[1L]], "http")
  })

  then("no scheme substitution occurs", function(context) {
    expect_false(context$result$scheme_inferred[[1L]])
  })

  expect_original_retained <- function(context) {
    expect_equal(context$result$original_input[[1L]], context$input[[1L]])
  }

  then(
    "the original URL is retained alongside the normalized URL",
    expect_original_retained
  )

  then("the normalized URL begins with {string}", function(prefix, context) {
    expect_true(startsWith(context$result$normalized_url[[1L]], prefix))
  })

  then("the original input {string} is retained", function(x, context) {
    expect_equal(context$result$original_input[[1L]], x)
  })

  then("the normalized URL is {string}", function(url, context) {
    expect_equal(context$result$normalized_url[[1L]], url)
  })

  then(
    "the normalized host is the Punycode form {string}",
    function(host, context) {
      expect_equal(context$result$host[[1L]], host)
    }
  )

  then("the original Unicode host is retained", function(context) {
    # Assert against the runtime-captured input, never a hardcoded literal, to
    # keep non-ASCII out of this source file.
    expect_equal(context$result$original_input[[1L]], context$input[[1L]])
  })

  then("the normalized path is {string}", function(path, context) {
    expect_equal(context$result$path[[1L]], path)
  })

  then("no network request is made", function(context) {
    expect_true(context$result$is_local_file[[1L]])
  })

  then("there are {int} source records", function(n, context) {
    expect_equal(nrow(context$result), n)
  })

  then("each has provenance {string}", function(p, context) {
    expect_true(all(context$result$provenance == p))
  })

  then(
    "there is {int} source record after deduplication",
    function(n, context) {
      expect_equal(nrow(context$result), n)
    }
  )

  then(
    "an error is raised citing the submitted-list cap of {int}",
    function(cap, context) {
      expect_false(is.null(context$error))
      expect_s3_class(context$error, "sitemapr_submitted_list_cap_error")
      expect_match(
        conditionMessage(context$error), as.character(cap),
        fixed = TRUE
      )
    }
  )

  then(
    paste0(
      "the entries are treated as distinct because port is part of the ",
      "identity key"
    ),
    function(context) {
      expect_equal(nrow(context$result), 2L)
    }
  )
}
