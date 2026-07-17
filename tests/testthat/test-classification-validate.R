# Direct unit tests for the classification-layer engine-format producer
# (R/classification-validate.R, spec 12.3): `engine_format_support()` (the pure
# per-engine acceptance lookup) and `validate_engine_format()` (the producer
# that emits ENGINE_UNSUPPORTED_SITEMAP_FORMAT only under an engine that rejects
# a parsed feed dialect). The baseline (NULL ruleset) must stay byte-identical.

base <- "sitemap://example.com/feed.xml"

spec_for <- function(engine) {
  findings_ruleset_spec(engine, ruleset_context())
}

test_that("yandex rejects every parsed feed dialect (spec 12.3)", {
  yandex <- spec_for("yandex")
  expect_identical(engine_format_support("rss2.0", yandex), "unsupported")
  expect_identical(engine_format_support("atom1.0", yandex), "unsupported")
  expect_identical(engine_format_support("atom0.3", yandex), "unsupported")
})

test_that("google supports RSS 2.0 / Atom 1.0 but Atom 0.3 is undocumented", {
  google <- spec_for("google")
  expect_identical(engine_format_support("rss2.0", google), "supported")
  expect_identical(engine_format_support("atom1.0", google), "supported")
  expect_identical(engine_format_support("atom0.3", google), "not_documented")
})

test_that("bing accepts every parsed feed dialect", {
  bing <- spec_for("bing")
  expect_identical(engine_format_support("rss2.0", bing), "supported")
  expect_identical(engine_format_support("atom1.0", bing), "supported")
  expect_identical(engine_format_support("atom0.3", bing), "supported")
})

test_that("the baseline (NULL ruleset) accepts every dialect", {
  expect_identical(engine_format_support("rss2.0", NULL), "supported")
  expect_identical(engine_format_support("atom1.0", NULL), "supported")
  expect_identical(engine_format_support("atom0.3", NULL), "supported")
})

test_that("validate_engine_format emits one finding for yandex + rss2.0", {
  out <- validate_engine_format("rss2.0", base, spec_for("yandex"))
  expect_identical(nrow(out), 1L)
  expect_identical(out$code, "ENGINE_UNSUPPORTED_SITEMAP_FORMAT")
  expect_identical(out$severity, "error")
  expect_identical(out$subject_type, "source")
  expect_identical(out$subject_ref, base)
})

test_that("validate_engine_format emits nothing on the baseline path", {
  out <- validate_engine_format("rss2.0", base, NULL)
  expect_identical(nrow(out), 0L)
})

test_that("validate_engine_format emits nothing for a supported dialect", {
  out <- validate_engine_format("rss2.0", base, spec_for("google"))
  expect_identical(nrow(out), 0L)
})

test_that("validate_engine_format emits nothing for a not_documented dialect", {
  out <- validate_engine_format("atom0.3", base, spec_for("google"))
  expect_identical(nrow(out), 0L)
})
