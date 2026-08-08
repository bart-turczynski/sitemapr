# The registry's `ruleset` column vs the emitters (SITE-crjgvsht).
#
# The column says WHERE a code's emitter is reachable: `baseline` on every call,
# `overlay` only when some engine overlay is selected, an engine name only under
# that one engine. Nothing checked it until `INDEX_CHILD_OUT_OF_SCOPE` shipped
# marked `baseline` against an emitter that returns empty on the baseline path,
# and the sibling port filed and worked a "baseline implementation gap" that did
# not exist (SMV-xalhuaxt). The name-only cross-port comparison cannot see this
# class of defect, so it has to be caught here.
#
# Two directions, only one of which a finite battery can decide:
#
#   - A code marked non-`baseline` that DOES fire on a baseline call is caught
#     automatically by the battery below — every code a baseline run emits must
#     be marked `baseline`.
#   - A code marked `baseline` that NEVER fires on a baseline call cannot be
#     disproved by any finite battery (absence of evidence). That is the
#     direction the real defect ran, so each non-baseline code additionally
#     pins its producer's dormancy under `ruleset = NULL` by execution, and the
#     set of such codes is tied to the registry below. Adding an overlay-gated
#     emitter therefore means adding it to `overlay_only_codes` here, or the
#     set-equality test fails.

fixture <- function(name) test_path("fixtures", name)

# The shipped copy, through the same reader the package uses at run time --
# `docs/` is .Rbuildignore'd and `inst/` is flattened into the package root, so
# neither path survives an installed-package test run.
registry <- function() {
  sitemapr_test_call("findings_registry")
}

# Codes whose emitters are gated on an engine overlay, with the value the
# registry must carry for each. Verified by execution, not by reading the code
# (see the per-code tests below and the entry-point sweep in this file).
overlay_only_codes <- c(
  INDEX_CHILD_OUT_OF_SCOPE = "overlay",
  PROTOCOL_URL_DECODED_TOO_LONG = "yandex",
  PROTOCOL_TAG_DATA_LIMIT_EXCEEDED = "yandex",
  ENGINE_UNSUPPORTED_SITEMAP_FORMAT = "yandex"
)

test_that("the registry's non-baseline rows are exactly the gated codes", {
  reg <- registry()
  non_baseline <- reg[reg$ruleset != "baseline", c("code", "ruleset")]

  expect_setequal(non_baseline$code, names(overlay_only_codes))
  expect_identical(
    unname(overlay_only_codes[non_baseline$code]),
    non_baseline$ruleset
  )
})

test_that("every code a baseline call emits is marked ruleset=baseline", {
  reg <- registry()
  # The whole flat fixture directory in both modes, so a fixture added later
  # joins the battery without anyone remembering to list it here. A fixture the
  # entry point rejects outright (deliberately malformed input) contributes
  # nothing and is skipped rather than special-cased by name.
  battery <- list.files(fixture(""), full.names = TRUE)
  battery <- battery[!dir.exists(battery)]

  codes_for <- function(path, mode) {
    tryCatch(validate_sitemap(path, mode = mode)$code, error = function(e) {
      character(0)
    })
  }
  seen <- unique(unlist(lapply(battery, function(f) {
    c(codes_for(f, "strict"), codes_for(f, "non-strict"))
  })))
  # The battery has to actually reach the pipeline, or this passes vacuously.
  expect_gt(length(seen), 20L)

  marked <- reg$ruleset[match(seen, reg$code)]
  expect_identical(seen[marked != "baseline"], character(0))
})

test_that("the index-child scope producer is dormant on the baseline path", {
  spec <- sitemapr_test_call(
    "findings_ruleset_spec",
    "google",
    ruleset_context()
  )
  args <- list(
    "https://example.com/deep/index.xml",
    "https://other.example.net/child.xml",
    "https://example.com/deep/index.xml"
  )

  baseline <- sitemapr_test_call(
    "index_child_scope_findings",
    args[[1L]],
    args[[2L]],
    args[[3L]],
    NULL
  )
  overlay <- sitemapr_test_call(
    "index_child_scope_findings",
    args[[1L]],
    args[[2L]],
    args[[3L]],
    spec
  )

  expect_identical(nrow(baseline), 0L)
  expect_identical(overlay$code, "INDEX_CHILD_OUT_OF_SCOPE")
})

test_that("the three yandex codes fire under yandex only, end to end", {
  # One over-long <loc> trips both yandex length guards; an RSS 2.0 source trips
  # the format-acceptance guard. Both are document-local, so no fetch is needed.
  dir <- withr::local_tempdir()
  long <- file.path(dir, "long.xml")
  writeLines(
    c(
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      sprintf(
        "  <url><loc>https://example.com/%s</loc></url>",
        strrep("abcdefghij", 160L)
      ),
      "</urlset>"
    ),
    long
  )

  codes_under <- function(path, ruleset) {
    validate_sitemap_ruleset(path, ruleset)$code
  }
  yandex_codes <- c(
    "PROTOCOL_URL_DECODED_TOO_LONG",
    "PROTOCOL_TAG_DATA_LIMIT_EXCEEDED"
  )

  for (code in yandex_codes) {
    expect_false(code %in% codes_under(long, "sitemaps.org"))
    expect_false(code %in% codes_under(long, "google"))
    expect_false(code %in% codes_under(long, "bing"))
    expect_true(code %in% codes_under(long, "yandex"))
    expect_false(code %in% validate_sitemap(long)$code)
  }

  feed <- fixture("feed-rss2.xml")
  fmt <- "ENGINE_UNSUPPORTED_SITEMAP_FORMAT"
  expect_false(fmt %in% codes_under(feed, "sitemaps.org"))
  expect_false(fmt %in% codes_under(feed, "google"))
  expect_false(fmt %in% codes_under(feed, "bing"))
  expect_true(fmt %in% codes_under(feed, "yandex"))
  expect_false(fmt %in% validate_sitemap(feed)$code)
})
