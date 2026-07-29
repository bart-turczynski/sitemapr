# Tests for the run manifest (R/layers-run.R, SITE-ysoqjxpm): the sink the
# validate/audit pipelines record exercised layers into, and the
# `attr(x, "layers_run")` stamp the report's Checks section unions into its
# inference.
#
# The invariant under test is asymmetric and worth stating: the stamp may only
# ADD evidence. A run that did not exercise a layer must never carry it, because
# the report would then advertise a check that never ran.

# ---- the sink primitives -----------------------------------------------------

test_that("a fresh sink has recorded nothing", {
  expect_identical(layer_sink_new()$layers, character(0))
})

test_that("recording accumulates layers without duplicating them", {
  sink <- layer_sink_new()
  layer_sink_record(sink, "schema")
  layer_sink_record(sink, "robots")
  layer_sink_record(sink, "schema")

  expect_identical(sink$layers, c("schema", "robots"))
})

test_that("recording into a NULL sink is a no-op, not an error", {
  expect_null(layer_sink_record(NULL, "schema"))
})

# ---- the stamp ---------------------------------------------------------------

test_that("an empty layer set attaches no attribute at all", {
  f <- empty_findings_contract()
  expect_null(attr(findings_stamp_layers(f, character(0)), "layers_run"))
  expect_null(attr(layer_sink_stamp(f, layer_sink_new()), "layers_run"))
  expect_null(attr(layer_sink_stamp(f, NULL), "layers_run"))
})

test_that("a non-empty layer set is stamped and read back", {
  f <- findings_stamp_layers(empty_findings_contract(), c("schema", "robots"))
  expect_identical(attr(f, "layers_run"), c("schema", "robots"))
  expect_identical(findings_layers_run(f), c("schema", "robots"))
})

test_that("a sink stamps what it recorded", {
  sink <- layer_sink_new()
  layer_sink_record(sink, "robots")
  f <- layer_sink_stamp(empty_findings_contract(), sink)

  expect_identical(findings_layers_run(f), "robots")
})

test_that("an unstamped tibble reads as an empty layer set", {
  expect_identical(findings_layers_run(empty_findings_contract()), character(0))
})

# ---- the union ---------------------------------------------------------------

test_that("the union of no stamps at all is empty, not NULL", {
  parts <- list(empty_findings_contract(), empty_findings_contract())
  expect_identical(findings_layers_run_union(parts), character(0))
  expect_identical(findings_layers_run_union(list()), character(0))
})

test_that("the union deduplicates across parts", {
  parts <- list(
    findings_stamp_layers(empty_findings_contract(), "schema"),
    findings_stamp_layers(empty_findings_contract(), c("schema", "robots")),
    empty_findings_contract()
  )
  expect_identical(findings_layers_run_union(parts), c("schema", "robots"))
})

# ---- wiring: what the pipelines actually record ------------------------------

lr_urlset <- function(loc) {
  path <- withr::local_tempfile(fileext = ".xml", .local_envir = parent.frame())
  writeLines(
    paste0(
      '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      "<url><loc>",
      loc,
      "</loc></url></urlset>"
    ),
    path
  )
  path
}

# A robots.txt allowing everything, so the robots layer runs and emits NOTHING —
# the case the manifest exists for.
lr_allow_all <- function(req) {
  httr2::response(
    status_code = 200L,
    url = req$url,
    body = charToRaw("User-agent: *\nDisallow: /other\n")
  )
}

test_that("a clean check_robots run records the robots layer", {
  skip_if_not_installed("robotstxtr")
  path <- lr_urlset("https://allow.example/ok")
  f <- httr2::with_mocked_responses(
    lr_allow_all,
    validate_sitemap(path, mode = "non-strict", check_robots = TRUE)
  )

  # No robots finding fired, yet the layer is recorded as having run.
  expect_identical(sum(f$layer == "robots"), 0L)
  expect_true("robots" %in% findings_layers_run(f))
})

test_that("a default call records no robots layer", {
  # The load-bearing negative: claiming a check ran when it did not is the one
  # failure mode this whole section is built to avoid.
  path <- lr_urlset("https://allow.example/ok")
  f <- validate_sitemap(path, mode = "non-strict")

  expect_false("robots" %in% findings_layers_run(f))
})

test_that("a gzip source records the schema layer its format hides", {
  f <- suppressWarnings(validate_sitemap(
    test_path("fixtures", "corpus", "compressed", "valid.xml.gz")
  ))
  expect_true("schema" %in% findings_layers_run(f))
})

test_that("an archive records no schema layer, because none runs", {
  # validate_archive_parts() reaches no validate_schema() call, so recording
  # `schema` here would be a false claim rather than a fix.
  f <- suppressWarnings(validate_sitemap(
    test_path("fixtures", "corpus", "compressed", "valid.tar.gz")
  ))
  expect_false("schema" %in% findings_layers_run(f))
})

test_that("an unsupported root records no schema layer", {
  # The short-circuit returns before validate_schema() is reached.
  f <- suppressWarnings(validate_sitemap(
    test_path("fixtures", "unsupported-root.xml")
  ))
  expect_false("schema" %in% findings_layers_run(f))
})

test_that("a clean batch run keeps its stamp through the zero-row combine", {
  # combine_findings_contracts() drops zero-row parts; the union has to be taken
  # before that filter or a clean run loses exactly the evidence it produced.
  skip_if_not_installed("robotstxtr")
  paths <- c(
    lr_urlset("https://allow.example/a"),
    lr_urlset("https://allow.example/b")
  )
  f <- httr2::with_mocked_responses(
    lr_allow_all,
    validate_sitemaps(paths, mode = "non-strict", check_robots = TRUE)
  )

  expect_identical(nrow(f), 0L)
  expect_true(all(c("schema", "robots") %in% findings_layers_run(f)))
})

test_that("the audit projection stamps the same layers as validate", {
  gz <- test_path("fixtures", "corpus", "compressed", "valid.xml.gz")
  audited <- suppressWarnings(audit_findings(audit_sitemap(gz)))
  validated <- suppressWarnings(validate_sitemap(gz))

  expect_identical(
    findings_layers_run(audited),
    findings_layers_run(validated)
  )
  expect_true("schema" %in% findings_layers_run(audited))
})
