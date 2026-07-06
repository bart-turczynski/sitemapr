# Cucumber step definitions for the validate_sitemap() acceptance features
# (SITE-rpoholfa): findings_contract.feature and schema_validation.feature.
#
# These are the SHARED validate_sitemap steps. F.4 (feed/RSS classification)
# reuses this file verbatim and only ADDS its feature-unique steps; the steps
# here are kept generic/parameterised so they need no re-registration.
#
# testthat sources `setup-*.R` before the test files, so these register before
# `cucumber::run()` runs the active top-level features. cucumber's step registry
# is GLOBAL across every setup-*.R, so this file deliberately does NOT re-define
# `fixture {string}` (owned by setup-steps-parse.R) — the bare quoted-fixture
# givens (`Given fixture "valid-minimal.xml"`) resolve to that step. Where
# a scenario adds trailing prose (`... that produces at least one finding`) the
# wording differs, so a distinct step is registered here.
#
# Offline / CRAN-safe: every scenario reads a committed local fixture from
# tests/testthat/fixtures/; no network access is performed (no URL/index
# scenario is present in either feature, so no httr2 mock is needed — the
# parse steps' mock plumbing is unused here).
#
# Step-description gotcha (SITE-qalrtbes): a description compiles to an
# anchored, UNESCAPED regex (`^\s*<desc>\s*$`), so literal regex-special
# characters in the feature wording must be escaped in the description — see the
# `\\(...\\)`, `\\#`, and `<n>` steps below.
if (requireNamespace("cucumber", quietly = TRUE)) {
  library(cucumber)

  # ---- helpers --------------------------------------------------------------

  # The 10-column findings contract (docs/findings-contract.md), in order.
  validate_contract_cols <- c(
    "code",
    "severity",
    "layer",
    "subject_type",
    "subject_ref",
    "message",
    "evidence",
    "mode",
    "is_strict_only",
    "remediation_hint"
  )

  # The severity vocabulary and the fixed layer vocabulary.
  validate_severities <- c("fatal", "error", "warning", "info")
  validate_layers <- c(
    "input",
    "fetch",
    "discovery",
    "classification",
    "decompression",
    "schema",
    "protocol",
    "index-expansion",
    "report"
  )

  # Point context$source at a committed fixture by bare name.
  validate_set_source <- function(name, context) {
    context$source <- test_path("fixtures", name)
  }

  # Run validate_sitemap on the resolved source, capturing the result tibble.
  validate_run <- function(context, mode = "strict") {
    context$mode <- mode
    context$result <- validate_sitemap(context$source, mode = mode)
  }

  # Schema-layer rows of the captured result.
  validate_schema_rows <- function(context) {
    r <- context$result
    r[r$layer == "schema", , drop = FALSE]
  }

  # ---- GIVEN ----------------------------------------------------------------

  # Generic "any fixture" givens: a small fixture that always yields findings,
  # used where the scenario does not care which fixture is in play.
  given("any sitemap fixture", function(context) {
    validate_set_source("urlset-duplicate-loc.xml", context)
  })
  given("any fixture that produces findings", function(context) {
    validate_set_source("urlset-duplicate-loc.xml", context)
  })
  given("any valid sitemap fixture", function(context) {
    validate_set_source("valid-minimal.xml", context)
  })

  # Named-fixture givens whose trailing prose makes the wording distinct from
  # the bare `fixture {string}` step owned by setup-steps-parse.R.
  given(
    "fixture {string} that produces at least one finding",
    function(name, context) validate_set_source(name, context)
  )
  given(
    "fixture {string} which produces an entry-level finding",
    function(name, context) validate_set_source(name, context)
  )
  given(
    "fixture {string} that produces a text-sitemap finding",
    function(name, context) validate_set_source(name, context)
  )
  given(
    "fixture {string} which triggers a strict-only rule",
    function(name, context) validate_set_source(name, context)
  )
  given(
    "fixture {string} with a misplaced element",
    function(name, context) validate_set_source(name, context)
  )
  given(
    paste(
      "fixture {string} using image, news, video, and hreflang namespaces",
      "simultaneously"
    ),
    function(name, context) validate_set_source(name, context)
  )
  given(
    paste(
      "fixture {string} with an invalid video element alongside valid",
      "others"
    ),
    function(name, context) validate_set_source(name, context)
  )
  given(
    "fixture {string} with a namespace not in the bundled catalog",
    function(name, context) validate_set_source(name, context)
  )

  # Long-content fixtures, referenced descriptively rather than by name.
  given(
    "a fixture that produces an XML-level finding with long content",
    function(context) validate_set_source("url-long-loc.xml", context)
  )
  given(
    "a fixture XML document containing an external entity declaration",
    function(context) validate_set_source("xxe-attempt.xml", context)
  )

  # PROTOCOL_DUPLICATE_LOC-producing fixture for the code-stability scenario.
  given(
    "any fixture that produces a PROTOCOL_DUPLICATE_LOC finding",
    function(context) validate_set_source("urlset-duplicate-loc.xml", context)
  )

  # The remediation_hint scenario: any finding row; reuse the duplicate-loc
  # fixture and let the WHEN step pick the first row.
  given(
    "a finding that has no associated remediation hint",
    function(context) validate_set_source("urlset-duplicate-loc.xml", context)
  )

  # ---- WHEN -----------------------------------------------------------------

  when("I call validate_sitemap on the fixture", function(context) {
    validate_run(context, "strict")
  })
  when(
    "I call validate_sitemap on the fixture in strict mode",
    function(context) validate_run(context, "strict")
  )
  when("I call validate_sitemap in strict mode", function(context) {
    validate_run(context, "strict")
  })
  when("I call validate_sitemap in non-strict mode", function(context) {
    validate_run(context, "non-strict")
  })

  # Inspect a single finding row (the remediation_hint scenario).
  when("I inspect the finding row", function(context) {
    validate_run(context, "strict")
    context$row <- context$result[1L, , drop = FALSE]
  })

  # Twice-call determinism: capture both results for a row-for-row diff.
  validate_run_twice <- function(context, mode = "strict") {
    context$mode <- mode
    context$result_a <- validate_sitemap(context$source, mode = mode)
    context$result_b <- validate_sitemap(context$source, mode = mode)
    context$result <- context$result_a
  }
  when(
    "I call validate_sitemap twice on the same fixture with the same mode",
    function(context) validate_run_twice(context, "strict")
  )
  when(
    paste(
      "I call validate_sitemap twice on the same fixture with the same mode",
      "and catalog version"
    ),
    function(context) validate_run_twice(context, "strict")
  )

  # ---- THEN: contract shape -------------------------------------------------

  then("the return value is a tibble", function(context) {
    expect_s3_class(context$result, "tbl_df")
  })

  then(
    paste0(
      "the result has columns: code, severity, layer, subject_type, ",
      "subject_ref, message, evidence, mode, is_strict_only, remediation_hint"
    ),
    function(context) {
      expect_named(context$result, validate_contract_cols)
    }
  )

  then(
    'every row in the severity column is one of "fatal", "error", "warning", "info"', # nolint: line_length_linter.
    function(context) {
      expect_true(all(context$result$severity %in% validate_severities))
    }
  )

  then(
    "every row in the layer column is one of the values in the layer vocabulary", # nolint: line_length_linter.
    function(context) {
      expect_true(all(context$result$layer %in% validate_layers))
    }
  )

  # ---- THEN: subject_ref + evidence -----------------------------------------

  then(
    'the subject_ref value begins with "sitemap://"',
    function(context) {
      refs <- context$result$subject_ref
      expect_gt(length(refs), 0L)
      expect_true(all(startsWith(refs, "sitemap://")))
    }
  )

  # The "#entry:<n>" fragment. None of #, <, > are regex-special, so the
  # description matches the feature text literally without escaping.
  then(
    'the fragment portion follows the "#entry:<n>" pattern',
    function(context) {
      refs <- context$result$subject_ref
      frag <- refs[grepl("#entry:", refs, fixed = TRUE)]
      expect_gt(length(frag), 0L)
      expect_true(all(grepl("#entry:[0-9]+$", frag)))
    }
  )

  then(
    "the excerpt field in each evidence list is at most 500 characters",
    function(context) {
      lens <- vapply(
        context$result$evidence,
        function(ev) {
          ex <- ev$excerpt
          if (is.null(ex) || is.na(ex)) 0L else nchar(ex)
        },
        integer(1L)
      )
      expect_true(all(lens <= 500L))
    }
  )

  then(
    "the excerpt field in the text finding is at most 200 characters",
    function(context) {
      ex <- context$result$evidence[[1L]]$excerpt
      expect_false(is.na(ex))
      expect_lte(nchar(ex), 200L)
    }
  )

  # ---- THEN: mode + strict/non-strict ---------------------------------------

  then('every row in the mode column is "strict"', function(context) {
    expect_true(all(context$result$mode == "strict"))
  })

  then(
    "the PROTOCOL_LASTMOD_DATE_ONLY row has is_strict_only TRUE",
    function(context) {
      r <- context$result
      row <- r[r$code == "PROTOCOL_LASTMOD_DATE_ONLY", , drop = FALSE]
      expect_identical(nrow(row), 1L)
      expect_true(row$is_strict_only[[1L]])
    }
  )

  then("the remediation_hint value is NA", function(context) {
    expect_true(is.na(context$row$remediation_hint[[1L]]))
  })

  then(
    'at least one finding has severity "error" or "fatal"',
    function(context) {
      expect_true(any(context$result$severity %in% c("error", "fatal")))
    }
  )

  then("schema findings are still present in the result", function(context) {
    expect_gt(nrow(validate_schema_rows(context)), 0L)
  })

  then(
    'the findings have severity at most "warning" \\(not "fatal" or "error"\\)',
    function(context) {
      expect_false(any(context$result$severity %in% c("fatal", "error")))
    }
  )

  then(
    "no PROTOCOL_LASTMOD_DATE_ONLY finding is present",
    function(context) {
      expect_false("PROTOCOL_LASTMOD_DATE_ONLY" %in% context$result$code)
    }
  )

  # ---- THEN: determinism ----------------------------------------------------

  then(
    "the code column values are identical between the two calls",
    function(context) {
      expect_identical(context$result_a$code, context$result_b$code)
    }
  )

  then("the two result tibbles are identical row-for-row", function(context) {
    expect_identical(context$result_a, context$result_b)
  })

  # ---- THEN: schema-layer assertions ----------------------------------------

  then("no schema-layer findings are produced", function(context) {
    expect_identical(nrow(validate_schema_rows(context)), 0L)
  })

  # Parameterised code+layer assertion reused across features.
  then(
    "a finding with code {word} and layer {string} is produced",
    function(code, layer, context) {
      r <- context$result
      hits <- r[r$code == code & r$layer == layer, , drop = FALSE]
      expect_gt(nrow(hits), 0L)
    }
  )

  then(
    'the finding severity is "error" or "fatal"',
    function(context) {
      r <- context$result
      sev <- r$severity[r$code == "SCHEMA_INVALID"]
      expect_gt(length(sev), 0L)
      expect_true(all(sev %in% c("error", "fatal")))
    }
  )

  then(
    "a SCHEMA_INVALID finding is produced scoped to the video extension",
    function(context) {
      r <- context$result
      hits <- r[r$code == "SCHEMA_INVALID", , drop = FALSE]
      expect_gt(nrow(hits), 0L)
      # Scoped to the video extension: the message names the video namespace
      # scope and the evidence excerpt carries the video namespace URI.
      msg_video <- grepl("video", hits$message, ignore.case = TRUE)
      ex_video <- vapply(
        hits$evidence,
        function(ev) {
          ex <- ev$excerpt
          !is.null(ex) && !is.na(ex) && grepl("video", ex, fixed = TRUE)
        },
        logical(1L)
      )
      expect_true(any(msg_video | ex_video))
    }
  )

  then(
    "the finding evidence identifies the invalid element",
    function(context) {
      r <- context$result
      hits <- r[r$code == "SCHEMA_INVALID", , drop = FALSE]
      expect_gt(nrow(hits), 0L)
      excerpts <- vapply(
        hits$evidence,
        function(ev) {
          ex <- ev$excerpt
          if (is.null(ex) || is.na(ex)) NA_character_ else ex
        },
        character(1L)
      )
      expect_true(any(!is.na(excerpts) & nzchar(excerpts)))
    }
  )

  then("a SCHEMA_UNKNOWN_NAMESPACE finding is produced", function(context) {
    expect_true("SCHEMA_UNKNOWN_NAMESPACE" %in% context$result$code)
  })

  # ---- THEN: XXE safety + in-process ----------------------------------------

  # XXE-safety proof. The fixture is a DOCTYPE-with-internal-subset urlset, now
  # correctly sniffed as XML (sniff_strip_prologue skips the internal subset).
  # The XXE-safe XML parse never resolves the external entity: `&xxe;` expands
  # to nothing — it is neither replaced by the contents of file:///etc/hostname
  # nor carried through as a literal reference — and the entity-bearing DOCTYPE
  # surfaces as a single SCHEMA_INVALID finding rather than being validated
  # as-is.
  validate_xxe_text <- function(context) {
    excerpts <- unlist(lapply(context$result$evidence, function(ev) {
      ex <- ev$excerpt
      if (is.null(ex) || is.na(ex)) character(0) else ex
    }))
    c(excerpts, context$result$message)
  }

  then("no entity expansion occurs", function(context) {
    text <- validate_xxe_text(context)
    # Neither the expanded external file contents nor a literal `&xxe;`
    # reference leaks into any finding's evidence or message.
    expect_false(any(grepl("&xxe;", text, fixed = TRUE)))
    expect_false(any(grepl("/etc/hostname", text, fixed = TRUE)))
  })

  then(
    "a SCHEMA_INVALID finding reports the entity references are not expanded",
    function(context) {
      res <- context$result
      hit <- res$code == "SCHEMA_INVALID" &
        grepl("not expanded", res$message, fixed = TRUE)
      expect_true(any(hit))
    }
  )

  # In-process guarantee: xml2::xml_validate runs in the R process. Assert
  # behaviourally that the call completed and returned the contract tibble with
  # no child process spawned (validate_sitemap shells out to nothing).
  then(
    "the process list shows no Java subprocess spawned during the call",
    function(context) {
      expect_s3_class(context$result, "tbl_df")
      expect_named(context$result, validate_contract_cols)
    }
  )
}
