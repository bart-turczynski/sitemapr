# Tests for validate_sitemap_robots() / validate_sitemaps_robots(), the
# robots-aware entry points (SITE-fsawklnl; docs/sitemap-spec.md §13.0).
#
# The point of the entry point is that a caller can select an engine's ROBOTS
# semantics and read back which axes decided the findings. So the tests pin:
# equivalence with validate_sitemap(check_robots = TRUE) under the default
# context (the back-compat claim), the added column and its expanded values,
# that a non-Google context genuinely reaches the findings, and that the
# sitemap-ruleset axis stays independent of it.
#
# Everything runs offline against httr2-mocked robots.txt transports; the
# `mock_robots` / `with_robots` helpers are shared with test-robots-validate.R.

vsr_urlset <- function(locs) {
  body <- paste0("<url><loc>", locs, "</loc></url>", collapse = "")
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    body,
    "</urlset>"
  )
  path <- withr::local_tempfile(fileext = ".xml", .local_envir = parent.frame())
  writeLines(xml, path)
  path
}

vsr_locs <- function() {
  c(
    "https://disallow.example/private/x",
    "https://allow.example/ok",
    "https://boom.example/y"
  )
}

test_that("the default context reproduces validate_sitemap(check_robots)", {
  skip_if_not_installed("robotstxtr")
  # The back-compat claim: `robots_context()` IS the Google-default widening
  # validate_sitemap() has always applied, so the two results differ only by
  # the added column.
  path <- vsr_urlset(vsr_locs())

  new <- with_robots(validate_sitemap_robots(path, mode = "non-strict"))
  old <- with_robots(
    validate_sitemap(path, mode = "non-strict", check_robots = TRUE)
  )

  expect_identical(new[names(old)], old)
  expect_identical(setdiff(names(new), names(old)), "robots_context")
})

test_that("the result carries the EXPANDED axes on every row", {
  skip_if_not_installed("robotstxtr")
  path <- vsr_urlset(vsr_locs())
  f <- with_robots(validate_sitemap_robots(
    path,
    robots_context_preset("google"),
    mode = "non-strict"
  ))

  expect_gt(nrow(f), 0L)
  expect_type(f$robots_context, "list")
  # Unclassed, as the ruleset context column is: plain named lists, not S3.
  expect_type(f$robots_context[[1L]], "list")
  expect_identical(
    f$robots_context[[1L]],
    list(
      product_token = "Googlebot",
      policy_ruleset = "google",
      matcher_backend = "google",
      preset = "google"
    )
  )
  # Constant across rows: the robots context is a call-level choice.
  expect_length(unique(f$robots_context), 1L)
})

test_that("an engine preset decides the findings under its own semantics", {
  skip_if_not_installed("robotstxtr")
  skip_if(
    robotstxtr_engine_contract()$matcher_availability[["yandex"]] != "available"
  )
  # Before SITE-fsawklnl this combination was unreachable: evaluation honoured
  # every engine, but deriving findings from a non-Google context aborted.
  path <- vsr_urlset(vsr_locs())
  f <- with_robots(validate_sitemap_robots(
    path,
    robots_context_preset("yandex"),
    mode = "non-strict"
  ))

  robots <- f[f$layer == "robots", , drop = FALSE]
  expect_setequal(robots$code, c("ROBOTS_DISALLOWED", "ROBOTS_INDETERMINATE"))
  expect_identical(
    f$robots_context[[1L]]$matcher_backend,
    "yandex"
  )
})

test_that("a backend with no matcher capability decides nothing", {
  skip_if_not_installed("robotstxtr")
  skip_if(
    robotstxtr_engine_contract()$matcher_availability[["rfc9309"]] ==
      "available"
  )
  # `capability_unavailable` must surface as the honest "cannot decide", never
  # as a silent allow or an empty robots layer.
  path <- vsr_urlset(vsr_locs())
  f <- with_robots(validate_sitemap_robots(
    path,
    robots_context_preset("rfc9309"),
    mode = "non-strict"
  ))

  robots <- f[f$layer == "robots", , drop = FALSE]
  expect_identical(unique(robots$code), "ROBOTS_INDETERMINATE")
})

test_that("the robots layer is on by construction", {
  skip_if_not_installed("robotstxtr")
  # There is deliberately no `check_robots` argument to contradict the context:
  # supplying one IS the request to run the layer.
  expect_false("check_robots" %in% names(formals(validate_sitemap_robots)))
  expect_false(
    "robots_user_agent" %in% names(formals(validate_sitemap_robots))
  )

  path <- vsr_urlset("https://disallow.example/private/x")
  f <- with_robots(validate_sitemap_robots(path, mode = "non-strict"))
  expect_gt(sum(f$layer == "robots"), 0L)
})

test_that("a non-context argument is rejected", {
  # A bare user-agent string is the OTHER entry point's surface. Accepting it
  # here would silently widen onto the Google axes, which is exactly the
  # ambiguity this entry point exists to remove.
  path <- vsr_urlset("https://allow.example/ok")
  expect_error(
    validate_sitemap_robots(path, "Googlebot"),
    class = "sitemapr_invalid_robots_context"
  )
  expect_error(
    validate_sitemap_robots(path, ruleset_context()),
    class = "sitemapr_invalid_robots_context"
  )
})

test_that("an absent robotstxtr warns and skips, as everywhere else", {
  local_mocked_bindings(robotstxtr_available = function() FALSE)
  path <- vsr_urlset("https://disallow.example/private/x")

  expect_warning(
    f <- validate_sitemap_robots(path, mode = "non-strict"),
    class = "sitemapr_robots_unavailable"
  )
  # Every other layer still runs, and the column is still present so the
  # result shape does not depend on the user's install.
  expect_identical(sum(f$layer == "robots"), 0L)
  expect_true("robots_context" %in% names(f))
})

test_that("the result stays the baseline schema-v1 ten columns plus one", {
  skip_if_not_installed("robotstxtr")
  # The robots axes are independent of `sitemap_ruleset` (ADR-009 §1): this
  # entry point selects a robots engine and does NOT turn on the additive
  # per-engine ruleset columns.
  path <- vsr_urlset("https://allow.example/ok")
  f <- with_robots(validate_sitemap_robots(path, mode = "non-strict"))

  expect_named(f, c(names(empty_findings_contract()), "robots_context"))
  expect_false(any(c("ruleset", "provenance") %in% names(f)))
})

test_that("a zero-finding run still carries the column", {
  skip_if_not_installed("robotstxtr")
  path <- vsr_urlset("https://allow.example/ok")
  f <- with_robots(validate_sitemap_robots(path))

  expect_identical(nrow(f), 0L)
  expect_true("robots_context" %in% names(f))
  expect_type(f$robots_context, "list")
})

test_that("validate_sitemaps_robots batches under one context", {
  skip_if_not_installed("robotstxtr")
  a <- vsr_urlset("https://disallow.example/private/x")
  b <- vsr_urlset("https://allow.example/ok")

  f <- with_robots(validate_sitemaps_robots(
    c(a, b),
    robots_context_preset("google"),
    mode = "non-strict"
  ))

  expect_gt(sum(f$layer == "robots"), 0L)
  expect_length(unique(f$robots_context), 1L)
  expect_identical(f$robots_context[[1L]]$product_token, "Googlebot")
})
