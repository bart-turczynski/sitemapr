# Unit tests for the per-engine validation-context data layer (ADR-009 §1,
# sitemap-spec §12.0/§12.1): the sitemap_ruleset axis + revision, the four
# per-source context axes, and the per-source-invariant child helper.

test_that("sitemap_rulesets() is the exact value set, baseline first", {
  expect_identical(
    sitemap_rulesets(),
    c("sitemaps.org", "google", "bing", "yandex")
  )
  # Baseline first so it is the match.arg default.
  expect_identical(sitemap_rulesets()[[1L]], "sitemaps.org")
})

test_that("ruleset_revision() defaults to the baseline and pins per ruleset", {
  expect_identical(ruleset_revision(), ruleset_revision("sitemaps.org"))

  for (ruleset in sitemap_rulesets()) {
    rev <- ruleset_revision(ruleset)
    expect_type(rev, "character")
    expect_length(rev, 1L)
    expect_true(nzchar(rev))
  }
})

test_that("ruleset_revision() rejects an unknown ruleset", {
  expect_error(ruleset_revision("altavista"))
})

test_that("check_sitemap_ruleset() accepts members and rejects non-members", {
  expect_identical(check_sitemap_ruleset("yandex"), "yandex")
  expect_error(
    check_sitemap_ruleset("altavista"),
    class = "sitemapr_invalid_ruleset_context"
  )
  expect_error(
    check_sitemap_ruleset(c("google", "bing")),
    class = "sitemapr_invalid_ruleset_context"
  )
  expect_error(
    check_sitemap_ruleset(NA_character_),
    class = "sitemapr_invalid_ruleset_context"
  )
})

test_that("ruleset_context() defaults to a neutral, structured context", {
  ctx <- ruleset_context()

  expect_s3_class(ctx, "sitemapr_ruleset_context")
  expect_named(
    ctx,
    c(
      "submission_channel",
      "discovery_provenance",
      "property_scope",
      "authority_evidence"
    )
  )
  expect_identical(ctx$submission_channel, "absent")
  expect_identical(ctx$discovery_provenance, "organic")
  expect_true(is.na(ctx$property_scope))
  expect_identical(ctx$authority_evidence, "absent")
})

test_that("ruleset_context() accepts a valid value on every axis", {
  ctx <- ruleset_context(
    submission_channel = "search_console_api",
    discovery_provenance = "robots_txt_reference",
    property_scope = "https://example.com/",
    authority_evidence = "verified_property_set"
  )

  expect_identical(ctx$submission_channel, "search_console_api")
  expect_identical(ctx$discovery_provenance, "robots_txt_reference")
  expect_identical(ctx$property_scope, "https://example.com/")
  expect_identical(ctx$authority_evidence, "verified_property_set")
})

test_that("submission_channel rejects 'discovered' (not a submission value)", {
  expect_error(ruleset_context(submission_channel = "discovered"))
})

test_that("each context axis enforces its exact value set", {
  expect_error(ruleset_context(submission_channel = "bogus"))
  expect_error(ruleset_context(discovery_provenance = "bogus"))
  expect_error(ruleset_context(authority_evidence = "bogus"))

  # Every documented submission channel constructs.
  for (channel in submission_channels()) {
    expect_s3_class(
      ruleset_context(submission_channel = channel),
      "sitemapr_ruleset_context"
    )
  }
  # Every documented discovery provenance constructs.
  for (prov in discovery_provenances()) {
    expect_s3_class(
      ruleset_context(discovery_provenance = prov),
      "sitemapr_ruleset_context"
    )
  }
  # Every documented authority evidence constructs.
  for (evidence in authority_evidence_values()) {
    expect_s3_class(
      ruleset_context(authority_evidence = evidence),
      "sitemapr_ruleset_context"
    )
  }
})

test_that("authority_evidence is structured, never boolean", {
  expect_error(ruleset_context(authority_evidence = TRUE))
  expect_error(ruleset_context(authority_evidence = FALSE))
})

test_that("property_scope accepts NA or a non-empty string, else rejects", {
  expect_true(is.na(ruleset_context(property_scope = NA)$property_scope))
  expect_identical(
    ruleset_context(property_scope = "https://a.example/")$property_scope,
    "https://a.example/"
  )
  expect_error(
    ruleset_context(property_scope = ""),
    class = "sitemapr_invalid_ruleset_context"
  )
  expect_error(
    ruleset_context(property_scope = c("a", "b")),
    class = "sitemapr_invalid_ruleset_context"
  )
  expect_error(
    ruleset_context(property_scope = 1L),
    class = "sitemapr_invalid_ruleset_context"
  )
})

test_that("ruleset_context_for_child() encodes the per-source invariant", {
  # A child with no evidence inherits nothing: no submission, discovered as an
  # index child, no property, no authority.
  child <- ruleset_context_for_child()

  expect_s3_class(child, "sitemapr_ruleset_context")
  expect_identical(child$submission_channel, "absent")
  expect_identical(child$discovery_provenance, "index_child")
  expect_true(is.na(child$property_scope))
  expect_identical(child$authority_evidence, "absent")
})

test_that("ruleset_context_for_child() is built only from its own evidence", {
  child <- ruleset_context_for_child(
    property_scope = "https://cdn.example.com/",
    authority_evidence = "verified_property_set"
  )

  expect_identical(child$property_scope, "https://cdn.example.com/")
  expect_identical(child$authority_evidence, "verified_property_set")
  # The helper takes no parent argument, so a parent index cannot pass anything
  # through it.
  expect_false("parent" %in% names(formals(ruleset_context_for_child)))
})
