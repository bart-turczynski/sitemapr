# Cucumber step definitions for fetch_classification.feature.
#
# testthat sources `setup-*.R` before the test files, so these steps are
# registered before `cucumber::run()` executes the active features.
#
# Network behavior is exercised through httr2's native mocking
# (httr2::local_mocked_responses); the real network is never hit, so the suite
# is CRAN-safe. The mock is installed INSIDE the `when` step that performs the
# fetch (not the `given` step), because local_mocked_responses() is scoped to
# the calling frame and would be torn down the moment a `given` step returned.
# Pure-logic scenarios (byte-level sniffing) call the real `sniff_format()` on
# bytes read from hand-authored fixtures under tests/testthat/fixtures/.
#
# Guarded on `cucumber` being installed so the suggests-only R CMD check
# (`_R_CHECK_DEPENDS_ONLY_=true`, which CRAN runs) degrades gracefully: with the
# package absent the steps simply are not registered and test-cucumber.R skips.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  # --- shared mock builders --------------------------------------------------

  # A 200 response carrying the given raw body + content type.
  default_body <- charToRaw("<?xml version=\"1.0\"?><urlset/>")
  fetch_mock_ok <- function(
    url = "https://example.com/sitemap.xml",
    body = default_body,
    content_type = "application/xml; charset=UTF-8"
  ) {
    httr2::response(
      status_code = 200,
      url = url,
      headers = list("Content-Type" = content_type),
      body = body
    )
  }

  # A 3xx response carrying a Location header (manual-redirect input).
  fetch_mock_redirect <- function(url, location, status = 301L) {
    httr2::response(
      status_code = status,
      url = url,
      headers = list(Location = location)
    )
  }

  # Perform a fetch, capturing result, error, and warning into the context so
  # the matching `then` steps can assert on whichever outcome occurred.
  fetch_capture <- function(context, ...) {
    context$error <- NULL
    context$warning <- NULL
    context$result <- withCallingHandlers(
      tryCatch(
        sitemapr_test_call("fetch_source", ...),
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

  # Build a fetch URL for a bare host token, bracketing IPv6 literals.
  fetch_url_for_host <- function(host) {
    if (grepl(":", host, fixed = TRUE)) {
      sprintf("http://[%s]/sitemap.xml", host)
    } else {
      sprintf("http://%s/sitemap.xml", host)
    }
  }

  # Turn the documented User-Agent template into an anchored regex: the
  # <version> and <contact-url> placeholders become wildcards and the literal
  # regex metacharacters that the template actually contains (the parentheses
  # and the leading "+" of the contact URL) are escaped.
  fetch_ua_template_regex <- function(template) {
    rx <- gsub("<version>", "WILDCARD", template, fixed = TRUE)
    rx <- gsub("<contact-url>", "WILDCARD", rx, fixed = TRUE)
    rx <- gsub("(", "\\(", rx, fixed = TRUE)
    rx <- gsub(")", "\\)", rx, fixed = TRUE)
    rx <- gsub("+", "\\+", rx, fixed = TRUE)
    rx <- gsub("WILDCARD", ".+", rx, fixed = TRUE)
    paste0("^", rx, "$")
  }

  # --- GIVEN -----------------------------------------------------------------

  given("a fixture server that echoes request headers", function(context) {
    context$echo_headers <- TRUE
  })

  given("a custom user_agent {string}", function(ua, context) {
    context$user_agent <- ua
  })

  given(
    "a fixture server that delays responses by 60 seconds",
    function(context) {
      context$transport <- "timeout"
    }
  )

  given(
    paste0(
      "a fixture server that starts sending a valid XML sitemap then ",
      "stalls mid-body"
    ),
    function(context) {
      context$transport <- "timeout"
    }
  )

  given(
    paste0(
      "a fixture server that serves a body larger than the configured ",
      "safety ceiling"
    ),
    function(context) {
      context$transport <- "oversized"
    }
  )

  given(
    "a fixture server that redirects 4 times before serving a sitemap",
    function(context) {
      context$redirects <- 4L
    }
  )

  given("a fixture server that redirects 6 times", function(context) {
    context$redirects <- 6L
  })

  given(
    "an initial URL that redirects to an RFC-1918 address",
    function(context) {
      context$start_url <- "https://example.com/sitemap.xml"
      context$redirect_target <- "http://192.168.1.10/internal.xml"
    }
  )

  given("a sitemap URL with host {string}", function(host, context) {
    context$url <- fetch_url_for_host(host)
  })

  given(
    "a URL that would normally be rejected by the structural guard",
    function(context) {
      context$url <- "http://127.0.0.1/sitemap.xml"
    }
  )

  given(
    "a fixture file named {string} that contains valid XML",
    function(name, context) {
      context$bytes <- readBin(
        test_path("fixtures", name),
        "raw",
        n = 1e6
      )
    }
  )

  given(
    "a fixture file named {string} that is gzip-compressed XML",
    function(name, context) {
      context$bytes <- readBin(
        test_path("fixtures", name),
        "raw",
        n = 1e6
      )
    }
  )

  given("a successfully fetched sitemap", function(context) {
    context$transport <- "ok"
  })

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

  # --- WHEN ------------------------------------------------------------------

  # Default-settings fetch that captures the outgoing request for header checks.
  when("I fetch a sitemap URL with default settings", function(context) {
    httr2::local_mocked_responses(function(req) {
      context$request <- req
      fetch_mock_ok()
    })
    fetch_capture(context, url = "https://example.com/sitemap.xml")
  })

  # Fetch honoring a caller-supplied User-Agent; captures the request.
  when("I fetch a sitemap URL", function(context) {
    httr2::local_mocked_responses(function(req) {
      context$request <- req
      fetch_mock_ok()
    })
    fetch_capture(
      context,
      url = "https://example.com/sitemap.xml",
      user_agent = context$user_agent
    )
  })

  when("I fetch with a 5-second timeout", function(context) {
    httr2::local_mocked_responses(function(req) {
      rlang::abort(
        "Timeout was reached",
        class = c("httr2_timeout", "httr2_failure", "httr2_error")
      )
    })
    fetch_capture(
      context,
      url = "https://example.com/sitemap.xml",
      limits = sitemapr_test_call("fetch_limits", timeout = 5)
    )
  })

  when("the request exceeds the configured timeout", function(context) {
    httr2::local_mocked_responses(function(req) {
      rlang::abort(
        "Timeout was reached",
        class = c("httr2_timeout", "httr2_failure", "httr2_error")
      )
    })
    fetch_capture(context, url = "https://example.com/sitemap.xml")
  })

  when("the body is read into memory", function(context) {
    big <- as.raw(rep(0x41, 50L))
    httr2::local_mocked_responses(list(
      fetch_mock_ok(url = "https://example.com/sitemap.xml", body = big)
    ))
    fetch_capture(
      context,
      url = "https://example.com/sitemap.xml",
      limits = sitemapr_test_call("fetch_limits", max_bytes = 10L)
    )
  })

  when("I fetch with a max-redirects limit of 5", function(context) {
    n <- context$redirects
    hops <- lapply(seq_len(n), function(i) {
      fetch_mock_redirect(
        sprintf("https://example.com/%d", i - 1L),
        sprintf("https://example.com/%d", i)
      )
    })
    final <- fetch_mock_ok(url = sprintf("https://example.com/%d", n))
    httr2::local_mocked_responses(c(hops, list(final)))
    fetch_capture(
      context,
      url = "https://example.com/0",
      limits = sitemapr_test_call("fetch_limits", max_redirects = 5L)
    )
  })

  when("I fetch the URL", function(context) {
    httr2::local_mocked_responses(list(
      fetch_mock_redirect(context$start_url, context$redirect_target)
    ))
    fetch_capture(context, url = context$start_url)
  })

  when("I attempt to fetch it", function(context) {
    context$network_called <- FALSE
    httr2::local_mocked_responses(function(req) {
      context$network_called <- TRUE
      fetch_mock_ok(url = req$url)
    })
    fetch_capture(context, url = context$url)
  })

  when("I call read_sitemap with ssrf_guard = FALSE", function(context) {
    httr2::local_mocked_responses(list(
      fetch_mock_ok(url = context$url)
    ))
    fetch_capture(context, url = context$url, ssrf_guard = FALSE)
  })

  when("sitemapr classifies the content", function(context) {
    context$format <- sitemapr_test_call("sniff_format", context$bytes)
  })

  when("I inspect the sources attribute", function(context) {
    body <- charToRaw("<?xml version=\"1.0\"?><urlset></urlset>")
    httr2::local_mocked_responses(list(
      fetch_mock_ok(url = "https://example.com/sitemap.xml", body = body)
    ))
    fetch_capture(context, url = "https://example.com/sitemap.xml")
  })

  # "I call read_sitemap on the index" is registered once, generically, by the
  # index-expansion slice (setup-steps-index.R); both this feature and
  # index_expansion.feature share it.

  # --- THEN ------------------------------------------------------------------

  then("the User-Agent header matches {string}", function(template, context) {
    expect_match(
      context$request$options$useragent,
      fetch_ua_template_regex(template)
    )
  })

  then("the User-Agent header is {string}", function(ua, context) {
    expect_identical(context$request$options$useragent, ua)
  })

  then(
    paste0(
      "the request fails with a timeout condition before the server ",
      "responds"
    ),
    function(context) {
      expect_s3_class(context$error, "sitemapr_timeout")
    }
  )

  then("sitemapr raises a sitemapr_timeout condition", function(context) {
    expect_s3_class(context$error, "sitemapr_timeout")
  })

  then("no partial parse result is returned", function(context) {
    expect_null(context$result)
  })

  then("sitemapr raises a sitemapr_body_ceiling condition", function(context) {
    expect_s3_class(context$error, "sitemapr_body_ceiling")
  })

  then("the over-ceiling body is discarded unparsed", function(context) {
    expect_null(context$result)
  })

  then("the final sitemap content is returned", function(context) {
    expect_null(context$error)
    expect_identical(context$result$status, 200L)
    expect_identical(context$result$format, "xml-urlset")
  })

  then(
    "the request fails with a redirect-limit-exceeded condition",
    function(context) {
      expect_s3_class(context$error, "sitemapr_redirect_limit")
    }
  )

  then("the redirect is rejected by the SSRF guard", function(context) {
    expect_s3_class(context$error, "sitemapr_ssrf_blocked")
  })

  then(
    "the rejection reason identifies the redirect target",
    function(context) {
      expect_identical(context$error$url, context$redirect_target)
    }
  )

  then(
    "the request is rejected before any network activity",
    function(context) {
      expect_false(isTRUE(context$network_called))
      expect_s3_class(context$error, "sitemapr_ssrf_blocked")
    }
  )

  then("the finding code indicates an SSRF guard rejection", function(context) {
    expect_s3_class(context$error, "sitemapr_ssrf_blocked")
  })

  then("the request is rejected by the SSRF guard", function(context) {
    expect_s3_class(context$error, "sitemapr_ssrf_blocked")
  })

  then("the URL is fetched without an SSRF rejection", function(context) {
    expect_null(context$error)
    expect_identical(context$result$status, 200L)
  })

  then(
    "the format is classified as {string} based on bytes",
    function(format, context) {
      expect_identical(context$format, format)
    }
  )

  then("the format is classified as {string}", function(format, context) {
    expect_identical(context$format, format)
  })

  then(
    paste0(
      "each source record contains requested_url, final_url, status, ",
      "redirect_chain, content_type, charset, bytes, timing, error_class, ",
      "format, root, namespaces, and profile_id"
    ),
    function(context) {
      expect_named(
        context$result,
        c(
          "requested_url",
          "final_url",
          "status",
          "redirect_chain",
          "content_type",
          "charset",
          "bytes",
          "timing",
          "error_class",
          "format",
          "root",
          "namespaces",
          "profile_id"
        )
      )
    }
  )

  # Child-4xx scenario (now activated by the index-expansion slice): a child 404
  # surfaces as a non-fatal warning, the parse result keeps the good children's
  # rows, and the failed child is recorded in the `problems` attribute. The
  # context is set up by the shared `given`/`when` steps (setup-steps-index.R).
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
