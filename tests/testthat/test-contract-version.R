# Unit tests for the published cross-port contract identity
# (R/contract-version.R), the ADR-009 §7 obligation sitemapr owes its two
# siblings.
#
# The revision/digest pair is guarded at build time by
# tools/check-findings-registry.R against docs/findings-registry.csv. That copy
# is .Rbuildignore'd, so these tests check the SHIPPED inst/ copy instead — the
# one an installed package actually reads. Both copies are asserted
# byte-identical by the same tools script, so agreeing with either is agreeing
# with both.

test_that("the published contract has the documented shape", {
  con <- sitemap_contract()

  expect_named(
    con,
    c(
      "contract_id",
      "contract_version",
      "legacy_contract_version",
      "registry_revision",
      "ruleset_revisions",
      "sibling_versions"
    )
  )
  expect_identical(con$contract_version, "2")
  expect_identical(con$legacy_contract_version, "1")
})

test_that("contract_id is derived from the version, not restated", {
  # A hand-written id could drift from the number it names.
  con <- sitemap_contract()

  expect_identical(
    con$contract_id,
    paste0("sitemapr.findings/v", con$contract_version)
  )
})

test_that("the nested ruleset revisions agree with ruleset_revision()", {
  con <- sitemap_contract()

  expect_identical(
    con$ruleset_revisions,
    vapply(sitemap_rulesets(), ruleset_revision, character(1))
  )
})

test_that("both siblings are published with a range apiece", {
  sib <- sitemap_contract()$sibling_versions

  expect_named(sib, c("sitemap-validator", "robotstxtr"))
  expect_true(all(grepl("^>= [0-9.]+, < [0-9.]+$", sib)))
})

test_that("the robotstxtr range covers the version DESCRIPTION pins", {
  # The declared range and the actual Remotes/Suggests pin are two statements
  # about one integration; a build that pins outside its own published range is
  # advertising compatibility it does not exercise.
  sib <- sitemap_contract()$sibling_versions

  expect_identical(sib[["robotstxtr"]], ">= 0.2.0, < 0.3.0")
})

test_that("the published registry digest matches the shipped registry", {
  # The build-time guard reads docs/; this reads inst/, so a partial copy that
  # updated one file and not the other cannot pass both.
  path <- system.file("findings-registry.csv", package = "sitemapr")
  skip_if(!nzchar(path), "registry not installed")

  expect_identical(
    unname(tools::md5sum(path)),
    sitemapr_test_call("findings_registry_digest")
  )
})

test_that("the registry revision is a plain ISO date", {
  expect_match(
    sitemap_contract()$registry_revision,
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
  )
})
