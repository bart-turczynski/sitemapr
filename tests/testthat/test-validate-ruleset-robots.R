# Tests for selecting BOTH engine-aware axes in one call: the `robots_context`
# argument on validate_sitemap_ruleset() / validate_sitemaps_ruleset()
# (SITE-otfmeyqx; ADR-009 §1, docs/sitemap-spec.md §13.0).
#
# ADR-009 makes `sitemap_ruleset` and the robots axes independent, but until
# this slice the exported surface made them mutually EXCLUSIVE — each lived on
# its own entry point, so "Bing's sitemap rules AND Bingbot's robots semantics"
# had no expression and callers ran the pipeline twice. These tests pin what
# independence is supposed to mean once both fit in one call: each axis governs
# its own columns, neither derives the other, and a mismatched pair is honoured
# on both sides rather than one axis quietly winning.
#
# Offline against the shared `mock_robots` / `with_robots` helpers.

vrr_urlset <- function(locs) {
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

vrr_locs <- function() {
  c(
    "https://disallow.example/private/x",
    "https://allow.example/ok",
    "https://boom.example/y"
  )
}

test_that("both axes take effect in one call, neither deriving the other", {
  skip_if_not_installed("robotstxtr")
  skip_if(
    robotstxtr_engine_contract()$matcher_availability[["yandex"]] != "available"
  )
  # The acceptance case, and deliberately a MISMATCHED pair: bing sitemap rules
  # with yandex robots. If either axis silently won, or if one were derived
  # from the other, one of these two assertions would read the other engine.
  path <- vrr_urlset(vrr_locs())
  f <- with_robots(validate_sitemap_ruleset(
    path,
    "bing",
    robots_context = robots_context_preset("yandex"),
    mode = "non-strict"
  ))

  expect_identical(unique(f$ruleset), "bing")
  expect_identical(f$robots_context[[1L]]$matcher_backend, "yandex")
  # The robots layer really ran under that backend rather than emitting an
  # empty layer that would also satisfy the column checks above.
  robots <- f[f$layer == "robots", , drop = FALSE]
  expect_gt(nrow(robots), 0L)
  expect_true("ROBOTS_DISALLOWED" %in% robots$code)
})

test_that("each axis governs its own columns", {
  skip_if_not_installed("robotstxtr")
  path <- vrr_urlset("https://allow.example/ok")
  pinned <- names(empty_findings_contract())
  additive <- c("ruleset", "ruleset_revision", "context", "provenance")

  overlay_only <- with_robots(validate_sitemap_ruleset(path, "google"))
  robots_only <- with_robots(validate_sitemap_ruleset(
    path,
    "sitemaps.org",
    robots_context = robots_context()
  ))
  both <- with_robots(validate_sitemap_ruleset(
    path,
    "google",
    robots_context = robots_context()
  ))

  expect_named(overlay_only, c(pinned, additive))
  expect_named(robots_only, c(pinned, "robots_context"))
  # Both: the ruleset columns keep their place and robots_context lands last.
  expect_named(both, c(pinned, additive, "robots_context"))
})

test_that("a baseline call with a robots context IS validate_sitemap_robots", {
  skip_if_not_installed("robotstxtr")
  # The documented equivalence. It is what makes the two entry points a
  # hierarchy rather than two overlapping ways to ask the same question.
  path <- vrr_urlset(vrr_locs())
  ctx <- robots_context_preset("google")

  via_ruleset <- with_robots(validate_sitemap_ruleset(
    path,
    "sitemaps.org",
    robots_context = ctx,
    mode = "non-strict"
  ))
  via_robots <- with_robots(
    validate_sitemap_robots(path, ctx, mode = "non-strict")
  )

  expect_identical(via_ruleset, via_robots)
})

test_that("supplying a robots context turns the layer on by construction", {
  skip_if_not_installed("robotstxtr")
  # Mirrors validate_sitemap_robots(): the context IS the request, so a caller
  # does not additionally have to remember check_robots = TRUE.
  path <- vrr_urlset("https://disallow.example/private/x")
  f <- with_robots(validate_sitemap_ruleset(
    path,
    "google",
    robots_context = robots_context(),
    mode = "non-strict"
  ))

  expect_gt(sum(f$layer == "robots"), 0L)
})

test_that("the two robots-axis surfaces cannot both be supplied", {
  path <- vrr_urlset("https://allow.example/ok")
  expect_error(
    validate_sitemap_ruleset(
      path,
      "google",
      robots_user_agent = "Bingbot",
      robots_context = robots_context()
    ),
    class = "sitemapr_invalid_robots_context"
  )
  # The default "*" is not a conflict: it is the absence of a choice.
  expect_no_error(with_robots(validate_sitemap_ruleset(
    path,
    "google",
    robots_user_agent = "*",
    robots_context = robots_context()
  )))
})

test_that("each context argument rejects the other's object", {
  skip_if_not_installed("robotstxtr")
  # The `context` name collision this slice had to resolve. Before it, a
  # robots_context() passed as `context` was accepted in silence.
  path <- vrr_urlset("https://allow.example/ok")
  expect_error(
    validate_sitemap_ruleset(path, "google", context = robots_context()),
    class = "sitemapr_invalid_ruleset_context"
  )
  expect_error(
    validate_sitemap_ruleset(
      path,
      "google",
      robots_context = ruleset_context()
    ),
    class = "sitemapr_invalid_robots_context"
  )
  expect_error(
    validate_sitemap_ruleset(path, "google", robots_context = "Googlebot"),
    class = "sitemapr_invalid_robots_context"
  )
})

test_that("the single-axis calls are unchanged", {
  skip_if_not_installed("robotstxtr")
  # Back-compat: adding the argument must not perturb any existing call.
  path <- vrr_urlset(vrr_locs())

  expect_identical(
    with_robots(validate_sitemap_ruleset(path, "google", mode = "non-strict")),
    with_robots(validate_sitemap_ruleset(
      path,
      "google",
      robots_context = NULL,
      mode = "non-strict"
    ))
  )
  # A ruleset call with no robots context leaves the robots axis exactly as
  # validate_sitemap() treats it: off unless check_robots asks for it.
  quiet <- with_robots(validate_sitemap_ruleset(
    path,
    "google",
    mode = "non-strict"
  ))
  expect_identical(sum(quiet$layer == "robots"), 0L)
  expect_false("robots_context" %in% names(quiet))
})

test_that("the string shorthand still works alongside the ruleset axis", {
  skip_if_not_installed("robotstxtr")
  # robots_user_agent= remains the widening shorthand; it adds no column.
  path <- vrr_urlset(vrr_locs())
  f <- with_robots(validate_sitemap_ruleset(
    path,
    "google",
    check_robots = TRUE,
    robots_user_agent = "Googlebot",
    mode = "non-strict"
  ))

  expect_gt(sum(f$layer == "robots"), 0L)
  expect_false("robots_context" %in% names(f))
})

test_that("validate_sitemaps_ruleset forwards both axes", {
  skip_if_not_installed("robotstxtr")
  # The plural twin delegates by forwarding every argument explicitly, which is
  # why the conflict check reads values rather than missing().
  a <- vrr_urlset("https://disallow.example/private/x")
  b <- vrr_urlset("https://allow.example/ok")

  f <- with_robots(validate_sitemaps_ruleset(
    c(a, b),
    "google",
    robots_context = robots_context_preset("google"),
    mode = "non-strict"
  ))

  expect_identical(unique(f$ruleset), "google")
  expect_identical(f$robots_context[[1L]]$product_token, "Googlebot")
  expect_gt(sum(f$layer == "robots"), 0L)
})

test_that("an absent robotstxtr warns and skips, keeping the column", {
  local_mocked_bindings(robotstxtr_available = function() FALSE)
  path <- vrr_urlset("https://disallow.example/private/x")

  expect_warning(
    f <- validate_sitemap_ruleset(
      path,
      "google",
      robots_context = robots_context(),
      mode = "non-strict"
    ),
    class = "sitemapr_robots_unavailable"
  )
  # Same contract as validate_sitemap_robots(): the result SHAPE does not
  # depend on the user's install. Shape, not values -- with the robots layer
  # skipped this sitemap is clean, so there are no rows to carry a value.
  expect_identical(nrow(f), 0L)
  expect_identical(sum(f$layer == "robots"), 0L)
  expect_true(all(c("ruleset", "robots_context") %in% names(f)))
})
