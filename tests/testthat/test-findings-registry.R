# Unit tests for the run-time registry reader (R/findings-registry.R).
#
# The registry ships at inst/findings-registry.csv because `docs/` is
# .Rbuildignore'd and an installed package cannot read it. The byte-identity of
# the two copies is asserted by tools/check-findings-registry.R (the docs copy
# is absent from a built package, so it cannot be checked from here); these
# tests cover the reader itself and the eligibility filter that keeps a
# validator-only code out of any "this check ran" claim.

test_that("the registry is readable from the installed package", {
  reg <- sitemapr_test_call("findings_registry")

  expect_named(
    reg,
    c(
      "code",
      "severity",
      "layer",
      "subject_type",
      "is_strict_only",
      "status",
      "reconcile",
      "validator_code",
      "ruleset"
    )
  )
  expect_gt(nrow(reg), 0L)
  # Blank cells read as NA, not as the empty string, so `is.na()` is the test
  # for "no value" everywhere downstream.
  expect_true(anyNA(reg$reconcile))
  expect_true(all(nzchar(reg$reconcile), na.rm = TRUE))
})

test_that("the registry is parsed once per cache", {
  cache <- new.env(parent = emptyenv())
  first <- sitemapr_test_call("findings_registry", cache = cache)
  expect_false(is.null(cache$registry))

  # The second call must come back from the cache: mutate it and watch the
  # mutation survive, which a re-read would discard.
  cache$registry <- first[0L, , drop = FALSE]
  expect_equal(nrow(sitemapr_test_call("findings_registry", cache = cache)), 0L)
})

test_that("only active codes are eligible, with code/severity/layer/ruleset", {
  reg <- sitemapr_test_call("findings_registry")
  active <- sitemapr_test_call("findings_active_codes")

  # `ruleset` rides along because status alone does not decide whether a check
  # was exercised: it says the emitter exists here, `ruleset` says which calls
  # can reach it (SITE-lbhbltzf).
  expect_named(active, c("code", "severity", "layer", "ruleset"))
  expect_equal(nrow(active), sum(reg$status == "active"))
  # The statuses that name a check this port does NOT run are excluded, so they
  # can never be reported as having passed.
  expect_false(any(active$code %in% reg$code[reg$status != "active"]))
  expect_true(all(active$layer %in% sitemapr_test_ns$findings_layer_order))
})
