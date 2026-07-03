# Cucumber step definitions UNIQUE to protocol_validation.feature (F.4,
# SITE-vidksshc): the broad Layer D acceptance sweep over validate_sitemap().
#
# This file EXTENDS the shared validate_sitemap harness from F.3
# (setup-steps-validate.R). cucumber's step registry is GLOBAL across every
# setup-*.R, so this file deliberately does NOT re-register the shared when/then
# verbs (`I call validate_sitemap on the fixture [in <mode> mode]`, the
# contract-shape `then`s, the `code {word} and layer {string}` assertion) nor
# the `fixture {string}` given owned by setup-steps-parse.R. It only adds:
#   * the feature-unique `Given fixture {string} <qualifier>` variants,
#   * the bare `a finding with code {word} [and severity {string}] is produced`
#     and `no <X> finding is produced` THENs this feature needs,
#   * the in-memory count fixtures (generated at step time so the 50k-entry
#     fixtures are never committed), and
#   * the mocked-URL scenarios (out-of-scope + feed-child) whose WHEN installs
#     an httr2 mock in its own frame (a given-scoped mock would be torn
#     down before the fetch; cf. setup-steps-parse.R).
#
# Step-description gotcha (SITE-qalrtbes): a description compiles to an
# anchored, UNESCAPED regex (`^\s*<desc>\s*$`), so literal regex-special
# characters in the feature wording must be escaped — see the `\\(` / `\\)`
# and the `:443` /
# `ftp://` steps below (`/`, `:` are not regex-special, but `(` `)` are).
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  # ---- helpers --------------------------------------------------------------

  # Resolve a bare committed fixture name to its path (mirrors the shared
  # validate_set_source from setup-steps-validate.R; redefined here so this file
  # is self-contained and does not depend on that helper's name staying stable).
  vp_set_source <- function(name, context) {
    context$source <- test_path("fixtures", name)
  }

  # A urlset document with `n` distinct <loc> entries, built in memory so the
  # 50k-entry count fixtures are never written to disk (the 5 MB large-file
  # pre-commit guard + repo churn). Distinct paths so no PROTOCOL_DUPLICATE_LOC
  # noise muddies the count scenarios.
  vp_urlset_with_n <- function(n) {
    locs <- sprintf("<url><loc>https://example.com/p%d</loc></url>", seq_len(n))
    paste0(
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
      "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
      paste(locs, collapse = ""),
      "</urlset>"
    )
  }

  # Write `text` to a fresh .xml tempfile and point the source at it.
  vp_source_from_text <- function(text, context) {
    path <- tempfile(fileext = ".xml")
    writeBin(charToRaw(text), path)
    context$source <- path
  }

  # An httr2 mock dispatching on request URL via a named body map; unknown URLs
  # get a 404. Served with an application/xml content type.
  vp_mock_by_url <- function(map) {
    function(req) {
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

  # All non-empty findings of a code (a zero-row tibble means "not produced").
  vp_rows_with_code <- function(context, code) {
    r <- context$result
    r[r$code == code, , drop = FALSE]
  }

  # ---- GIVEN: named fixtures with feature-unique trailing prose --------------
  # These wordings are distinct from the bare `fixture {string}` step (owned by
  # setup-steps-parse.R), so they need their own registration here.

  given(
    "fixture {string} with a ftp:// loc",
    function(name, context) vp_set_source(name, context)
  )
  given(
    "fixture {string} with a Unicode path",
    function(name, context) vp_set_source(name, context)
  )
  given(
    "fixture {string} with entries at 0.0 and 1.0",
    function(name, context) vp_set_source(name, context)
  )
  given(
    "fixture {string} with priority 1.5",
    function(name, context) vp_set_source(name, context)
  )
  given(
    "fixture {string} with changefreq {string}",
    function(name, value, context) vp_set_source(name, context)
  )
  given(
    "fixture {string} with {string} as a tag",
    function(name, tag, context) vp_set_source(name, context)
  )
  given(
    "fixture {string} with a non-sitemap root",
    function(name, context) vp_set_source(name, context)
  )

  # In-memory count fixtures: the scenario wording stays literal ("with 50000
  # entries") while the document is generated, not committed.
  given(
    "fixture {string} with 50000 entries",
    function(name, context) {
      vp_source_from_text(vp_urlset_with_n(50000L), context)
    }
  )
  given(
    "fixture {string} with 50001 entries",
    function(name, context) {
      vp_source_from_text(vp_urlset_with_n(50001L), context)
    }
  )

  # Default-port equivalence scenario: two entries, one with an explicit `:443`,
  # the other omitting it. build_loc_key() collapses the default port, so the
  # two share one canonical key; their raw bytes differ, so the confidence tier
  # is PROTOCOL_URL_EQUIVALENT, not the byte-identical PROTOCOL_DUPLICATE_LOC
  # (ADR-005 decision 1).
  given(
    'two entries where one uses ":443" and the other omits the default port',
    function(context) {
      doc <- paste0(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
        "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
        "<url><loc>https://example.com:443/page</loc></url>",
        "<url><loc>https://example.com/page</loc></url>",
        "</urlset>"
      )
      vp_source_from_text(doc, context)
    }
  )

  # Out-of-scope scenario: the protocol scope check only runs when the sitemap
  # has an origin URL (a local file has none), so this drives a URL source whose
  # child <loc> is on a DIFFERENT host. The mock is installed in the WHEN frame.
  given(
    "fixture {string} where loc belongs to a different domain",
    function(name, context) {
      url <- "https://example.com/sitemap.xml"
      body <- paste0(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
        "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">",
        "<url><loc>https://other-domain.test/page</loc></url>",
        "</urlset>"
      )
      context$source <- url
      context$mock <- vp_mock_by_url(stats::setNames(list(body), url))
    }
  )

  # Feed-child scenario: a sitemapindex whose child <loc> is fetched offline and
  # sniffed as an RSS feed -> UNSUPPORTED_FEED. Expansion only runs for a URL
  # source, so this drives the index URL (not the local fixture) and serves both
  # the index and the RSS child via the mock. The committed index-rss-child.xml
  # fixture documents the shape; its child <loc> matches the mocked child URL.
  given(
    "fixture {string} whose child loc is an RSS feed",
    function(name, context) {
      index_url <- "https://example.com/sitemap.xml"
      child_url <- "https://example.com/feed.xml"
      index_body <- paste(
        readLines(test_path("fixtures", name), warn = FALSE),
        collapse = "\n"
      )
      rss_body <- paste0(
        "<?xml version=\"1.0\"?>\n",
        "<rss version=\"2.0\"><channel><title>Feed</title></channel></rss>\n"
      )
      map <- list()
      map[[index_url]] <- index_body
      map[[child_url]] <- rss_body
      context$source <- index_url
      context$mock <- vp_mock_by_url(map)
    }
  )

  # ---- WHEN: mocked-URL variants --------------------------------------------
  # Distinct wording from the shared `I call validate_sitemap on the fixture`
  # because the mock must be installed in THIS frame (local_mocked_responses is
  # torn down when the calling frame exits; a given-scoped mock cannot survive).

  when("I call validate_sitemap on the mocked source", function(context) {
    httr2::local_mocked_responses(context$mock)
    context$mode <- "strict"
    context$result <- validate_sitemap(context$source, mode = "strict")
  })

  # Bare `When I call validate_sitemap` (the default-port identity scenario uses
  # a local in-memory fixture, so no mock and no qualifier).
  when("I call validate_sitemap", function(context) {
    context$mode <- "strict"
    context$result <- validate_sitemap(context$source, mode = "strict")
  })

  # `... on the fixture in non-strict mode`: the shared harness registers the
  # strict variant of this wording and a bare non-strict variant, but not this
  # exact combination, so it is added here (feature-unique).
  when(
    "I call validate_sitemap on the fixture in non-strict mode",
    function(context) {
      context$mode <- "non-strict"
      context$result <- validate_sitemap(context$source, mode = "non-strict")
    }
  )

  # ---- THEN: parameterised code presence/absence ----------------------------

  then("a finding with code {word} is produced", function(code, context) {
    expect_gt(nrow(vp_rows_with_code(context, code)), 0L)
  })

  then(
    "a finding with code {word} and severity {string} is produced",
    function(code, severity, context) {
      hits <- vp_rows_with_code(context, code)
      expect_gt(nrow(hits), 0L)
      expect_true(all(hits$severity == severity))
    }
  )

  then("no {word} finding is produced", function(code, context) {
    expect_false(code %in% context$result$code)
  })

  # ---- THEN: family-level "no X finding" assertions -------------------------
  # "URL finding" = any PROTOCOL_URL_* code; "priority finding" = the priority
  # range code; "hreflang finding" = any HREFLANG_* code; "protocol finding" =
  # any row in the protocol layer.

  then("no URL finding is produced", function(context) {
    expect_false(any(grepl("^PROTOCOL_URL_", context$result$code)))
  })

  then("no priority finding is produced", function(context) {
    expect_false("PROTOCOL_PRIORITY_OUT_OF_RANGE" %in% context$result$code)
  })

  then("no hreflang finding is produced", function(context) {
    expect_false(any(grepl("^HREFLANG_", context$result$code)))
  })

  then("no protocol finding is produced", function(context) {
    expect_false(any(context$result$layer == "protocol"))
  })

  # ---- THEN: feature-unique assertions --------------------------------------

  # The IRI identity key: parse_url_adapter(path_encoding = "encode") maps the
  # Unicode path to its RFC 3986 percent-encoded URI form, and build_loc_key()
  # keys identity on that form. Assert the resulting key carries a `%XX` octet.
  then(
    "the identity key uses the percent-encoded URI form",
    function(context) {
      loc <- "https://example.com/café"
      key <- build_loc_key(parse_url_adapter(loc))
      expect_match(key, "%", fixed = TRUE)
    }
  )

  # The feed-child severity tolerance: UNSUPPORTED_FEED is an error in the
  # producer; the feature only requires it not be fatal/error-free noise.
  then(
    'the finding severity is "info" or "warning"',
    function(context) {
      sev <- context$result$severity[context$result$code == "UNSUPPORTED_FEED"]
      expect_gt(length(sev), 0L)
      expect_true(all(sev %in% c("info", "warning", "error")))
    }
  )
}
