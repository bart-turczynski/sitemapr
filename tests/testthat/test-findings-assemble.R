# Unit tests for the Layer F findings assembler core (SITE-qwiygfas). Direct
# tests over synthetic producer finding tibbles (the 8-column shape), built with
# the producer constructors where convenient.

contract_cols <- c(
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

test_that("empty input yields a zero-row 10-column contract tibble", {
  out <- assemble_findings(list(), "strict")

  expect_s3_class(out, "tbl_df")
  expect_identical(nrow(out), 0L)
  expect_identical(names(out), contract_cols)
})

test_that("a list of only zero-row parts also yields the empty contract", {
  out <- assemble_findings(
    list(empty_protocol_findings(), empty_schema_findings()),
    "strict"
  )
  expect_identical(nrow(out), 0L)
  expect_identical(names(out), contract_cols)
})

test_that("column set and types match the contract exactly", {
  parts <- list(
    schema_findings(
      code = "SCHEMA_INVALID",
      severity = "error",
      subject_type = "document",
      subject_ref = "sitemap://e.com/s.xml",
      message = "bad",
      evidence = list(finding_evidence(excerpt = "x")),
      is_strict_only = FALSE
    )
  )
  out <- assemble_findings(parts, "strict")

  expect_identical(names(out), contract_cols)
  expect_type(out$code, "character")
  expect_type(out$severity, "character")
  expect_type(out$layer, "character")
  expect_type(out$subject_type, "character")
  expect_type(out$subject_ref, "character")
  expect_type(out$message, "character")
  expect_type(out$evidence, "list")
  expect_type(out$mode, "character")
  expect_type(out$is_strict_only, "logical")
  expect_type(out$remediation_hint, "character")
  expect_true(all(is.na(out$remediation_hint)))
  expect_identical(unique(out$mode), "strict")
})

test_that("non-strict drops is_strict_only rows; strict keeps them", {
  parts <- list(
    protocol_findings(
      code = "PROTOCOL_LASTMOD_DATE_ONLY",
      severity = "info",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:1",
      message = "date-only",
      evidence = list(finding_evidence(excerpt = "2024-01-01")),
      is_strict_only = TRUE
    )
  )

  strict <- assemble_findings(parts, "strict")
  expect_identical(nrow(strict), 1L)
  expect_identical(strict$code, "PROTOCOL_LASTMOD_DATE_ONLY")

  non_strict <- assemble_findings(parts, "non-strict")
  expect_identical(nrow(non_strict), 0L)
})

test_that("non-strict downgrades schema error to warning; strict leaves it", {
  parts <- list(
    schema_findings(
      code = "SCHEMA_INVALID",
      severity = "error",
      subject_type = "document",
      subject_ref = "sitemap://e.com/s.xml",
      message = "bad",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  )

  expect_identical(assemble_findings(parts, "strict")$severity, "error")
  expect_identical(assemble_findings(parts, "non-strict")$severity, "warning")
})

test_that("strict elevates info->warning codes; non-strict keeps info", {
  parts <- list(
    classification_findings(
      code = "ENCODING_BOM_DECLARATION_CONFLICT",
      severity = "info",
      subject_type = "source",
      subject_ref = "sitemap://e.com/s.xml",
      message = "bom",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    ),
    protocol_findings(
      code = "PROTOCOL_LASTMOD_LOOKS_GENERATED",
      severity = "info",
      subject_type = "document",
      subject_ref = "sitemap://e.com/s.xml",
      message = "gen",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  )

  strict <- assemble_findings(parts, "strict")
  expect_true(all(strict$severity == "warning"))

  non_strict <- assemble_findings(parts, "non-strict")
  expect_true(all(non_strict$severity == "info"))
})

test_that("mixed-layer, mixed-severity fixture sorts in exact contract order", {
  # Built deliberately out of order. Expected order: layer-vocabulary order
  # (classification < schema < protocol), then severity descending, then
  # subject_ref, then code.
  parts <- list(
    protocol_findings(
      code = "PROTOCOL_URL_FRAGMENT",
      severity = "info",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:9",
      message = "frag",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    ),
    protocol_findings(
      code = "PROTOCOL_DUPLICATE_LOC",
      severity = "warning",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:2",
      message = "dup",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    ),
    schema_findings(
      code = "SCHEMA_INVALID",
      severity = "error",
      subject_type = "document",
      subject_ref = "sitemap://e.com/s.xml",
      message = "schema",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    ),
    classification_findings(
      code = "UNSUPPORTED_ROOT",
      severity = "error",
      subject_type = "source",
      subject_ref = "sitemap://e.com/s.xml",
      message = "root",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  )

  out <- assemble_findings(parts, "strict")

  expect_identical(
    out$layer,
    c("classification", "schema", "protocol", "protocol")
  )
  expect_identical(
    out$code,
    c(
      "UNSUPPORTED_ROOT",
      "SCHEMA_INVALID",
      "PROTOCOL_DUPLICATE_LOC",
      "PROTOCOL_URL_FRAGMENT"
    )
  )
  expect_identical(
    out$severity,
    c("error", "error", "warning", "info")
  )
})

test_that("severity ties break by subject_ref then code", {
  parts <- list(
    protocol_findings(
      code = "PROTOCOL_URL_NO_HOST",
      severity = "error",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:2",
      message = "b",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    ),
    protocol_findings(
      code = "PROTOCOL_URL_NOT_ABSOLUTE",
      severity = "error",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:1",
      message = "a",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  )
  out <- assemble_findings(parts, "strict")
  expect_identical(
    out$subject_ref,
    c("sitemap://e.com/s.xml#entry:1", "sitemap://e.com/s.xml#entry:2")
  )
})

test_that("exact-duplicate rows are de-duplicated, first kept", {
  one <- protocol_findings(
    code = "PROTOCOL_URL_FRAGMENT",
    severity = "info",
    subject_type = "entry",
    subject_ref = "sitemap://e.com/s.xml#entry:1",
    message = "frag",
    evidence = list(finding_evidence(excerpt = "a")),
    is_strict_only = FALSE
  )
  out <- assemble_findings(list(one, one), "strict")
  expect_identical(nrow(out), 1L)
})

test_that("assembling the same parts twice is row-for-row identical", {
  parts <- list(
    protocol_findings(
      code = "PROTOCOL_DUPLICATE_LOC",
      severity = "warning",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:2",
      message = "dup",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    ),
    schema_findings(
      code = "SCHEMA_INVALID",
      severity = "error",
      subject_type = "document",
      subject_ref = "sitemap://e.com/s.xml",
      message = "schema",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  )
  expect_identical(
    assemble_findings(parts, "strict"),
    assemble_findings(parts, "strict")
  )
})
