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
  expect_named(out, contract_cols)
})

test_that("a list of only zero-row parts also yields the empty contract", {
  out <- assemble_findings(
    list(empty_protocol_findings(), empty_schema_findings()),
    "strict"
  )
  expect_identical(nrow(out), 0L)
  expect_named(out, contract_cols)
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

  expect_named(out, contract_cols)
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

# --- Per-engine provenance (§12.2a) ----------------------------------------

test_that("findings_provenance_for maps §12.2a page-scope per engine", {
  codes <- c("PROTOCOL_URL_OUT_OF_SCOPE", "PROTOCOL_DUPLICATE_LOC")
  expect_identical(
    findings_provenance_for(codes, "google"),
    c("documented", "inherited_protocol")
  )
  expect_identical(
    findings_provenance_for(codes, "yandex"),
    c("documented", "inherited_protocol")
  )
  expect_identical(
    findings_provenance_for(codes, "bing"),
    c("inherited_protocol", "inherited_protocol")
  )
})

test_that("yandex decoded-URL-length is an application_choice", {
  expect_identical(
    findings_provenance_for("PROTOCOL_URL_DECODED_TOO_LONG", "yandex"),
    "application_choice"
  )
})

test_that("yandex per-tag data limit is an advisory", {
  expect_identical(
    findings_provenance_for("PROTOCOL_TAG_DATA_LIMIT_EXCEEDED", "yandex"),
    "advisory"
  )
})

test_that("yandex sitemap-format acceptance is documented", {
  expect_identical(
    findings_provenance_for("ENGINE_UNSUPPORTED_SITEMAP_FORMAT", "yandex"),
    "documented"
  )
})

test_that("findings_provenance_for defaults unknown codes to inherited", {
  expect_identical(
    findings_provenance_for("PROTOCOL_URL_FRAGMENT", "google"),
    "inherited_protocol"
  )
})

test_that("assemble_findings stamps per-code provenance under an engine", {
  parts <- list(
    protocol_findings(
      code = "PROTOCOL_URL_OUT_OF_SCOPE",
      severity = "warning",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:1",
      message = "out of scope",
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
    )
  )
  out <- assemble_findings(
    parts,
    "strict",
    ruleset = findings_ruleset_spec("google", ruleset_context())
  )
  scope <- out$provenance[out$code == "PROTOCOL_URL_OUT_OF_SCOPE"]
  other <- out$provenance[out$code == "PROTOCOL_DUPLICATE_LOC"]
  expect_identical(scope, "documented")
  expect_identical(other, "inherited_protocol")
})

# --- Inherited file-limit provenance (§12.6) -------------------------------

test_that("§12.6 file-limit caps are documented under every engine", {
  for (engine in c("google", "bing", "yandex")) {
    expect_identical(
      findings_provenance_for("PROTOCOL_URL_COUNT_EXCEEDED", engine),
      "documented"
    )
  }
  expect_identical(
    findings_provenance_for("INDEX_CHILD_COUNT_EXCEEDED", "yandex"),
    "documented"
  )
  expect_identical(
    findings_provenance_for("PROTOCOL_SIZE_EXCEEDED", "yandex"),
    "documented"
  )
})

# --- Yandex raw-IRI acceptance (§12.5) -------------------------------------

test_that("yandex raw-IRI <loc> is an inherited_protocol record", {
  expect_identical(
    findings_provenance_for("PROTOCOL_URL_NOT_ESCAPED", "yandex"),
    "inherited_protocol"
  )
})

# --- Yandex metadata-acceptance relabels (§12.7) ---------------------------

test_that("§12.7 yandex metadata severities relabel error->warning", {
  codes <- c(
    "PROTOCOL_LASTMOD_INVALID",
    "PROTOCOL_CHANGEFREQ_INVALID",
    "PROTOCOL_PRIORITY_OUT_OF_RANGE"
  )
  expect_identical(
    findings_severity_for(codes, "yandex", rep("error", 3)),
    rep("warning", 3)
  )
  expect_identical(
    findings_provenance_for(codes, "yandex"),
    rep("documented", 3)
  )
})

test_that("§12.7 metadata severities stay error where no override applies", {
  expect_identical(
    findings_severity_for("PROTOCOL_LASTMOD_INVALID", "google", "error"),
    "error"
  )
  expect_identical(
    findings_severity_for("PROTOCOL_LASTMOD_INVALID", "bing", "error"),
    "error"
  )
})

# --- NULL-ruleset byte-identical guard --------------------------------------

test_that("NULL ruleset leaves the baseline path byte-identical", {
  parts <- list(
    protocol_findings(
      code = "PROTOCOL_LASTMOD_INVALID",
      severity = "error",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:1",
      message = "bad lastmod",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  )
  out <- assemble_findings(parts, "strict", ruleset = NULL)
  expect_identical(out$severity, "error")
  expect_named(out, contract_cols)
  expect_false("provenance" %in% names(out))
  expect_false("ruleset" %in% names(out))
})

test_that("findings_stamp_ruleset returns input unchanged for NULL", {
  small <- protocol_findings(
    code = "PROTOCOL_LASTMOD_INVALID",
    severity = "error",
    subject_type = "entry",
    subject_ref = "sitemap://e.com/s.xml#entry:1",
    message = "bad lastmod",
    evidence = list(finding_evidence()),
    is_strict_only = FALSE
  )
  expect_identical(findings_stamp_ruleset(small, NULL), small)
})

test_that("yandex overlay relabels metadata error to warning end-to-end", {
  parts <- list(
    protocol_findings(
      code = "PROTOCOL_LASTMOD_INVALID",
      severity = "error",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:1",
      message = "bad lastmod",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  )
  out <- assemble_findings(
    parts,
    "strict",
    ruleset = findings_ruleset_spec("yandex", ruleset_context())
  )
  row <- out[out$code == "PROTOCOL_LASTMOD_INVALID", , drop = FALSE]
  expect_identical(row$severity, "warning")
  expect_identical(row$provenance, "documented")
})

# --- Producer-supplied page-level metadata (SITE-qvdjvwwy) ------------------

# A single-row protocol part carrying an optional producer column, used to
# exercise the per-finding merge / override / pass-through seams.
page_part <- function(code = "PROTOCOL_URL_OUT_OF_SCOPE", ...) {
  p <- protocol_findings(
    code = code,
    severity = "warning",
    subject_type = "entry",
    subject_ref = "sitemap://e.com/s.xml#entry:1",
    message = "page finding",
    evidence = list(finding_evidence()),
    is_strict_only = FALSE
  )
  extra <- list(...)
  for (nm in names(extra)) {
    p[[nm]] <- extra[[nm]]
  }
  p
}

test_that("producer per-finding context merges over the uniform stamp", {
  parts <- list(page_part(
    context = list(list(
      status_code = 404L,
      submission_channel = "sitemap_ping"
    ))
  ))
  out <- assemble_findings(
    parts,
    "strict",
    ruleset = findings_ruleset_spec("google", ruleset_context())
  )
  ctx <- out$context[[1L]]
  # producer-only key is added
  expect_identical(ctx$status_code, 404L)
  # producer key WINS on collision with the uniform ruleset stamp
  expect_identical(ctx$submission_channel, "sitemap_ping")
  # uniform ruleset axes the producer did not touch are preserved
  expect_identical(ctx$discovery_provenance, "organic")
})

test_that("a finding with no context contribution keeps the uniform stamp", {
  # one page finding contributes context, a plain protocol finding does not;
  # the plain finding must still carry the uniform ruleset context unchanged.
  parts <- list(
    page_part(context = list(list(status_code = 404L))),
    protocol_findings(
      code = "PROTOCOL_DUPLICATE_LOC",
      severity = "warning",
      subject_type = "entry",
      subject_ref = "sitemap://e.com/s.xml#entry:2",
      message = "dup",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  )
  out <- assemble_findings(
    parts,
    "strict",
    ruleset = findings_ruleset_spec("google", ruleset_context())
  )
  plain <- out$context[out$code == "PROTOCOL_DUPLICATE_LOC"][[1L]]
  expect_identical(plain, unclass(ruleset_context()))
  expect_false("status_code" %in% names(plain))
})

test_that("producer-supplied remediation_hint passes through", {
  parts <- list(page_part(remediation_hint = "Remove the noindex directive."))
  out <- assemble_findings(
    parts,
    "strict",
    ruleset = findings_ruleset_spec("google", ruleset_context())
  )
  expect_identical(out$remediation_hint, "Remove the noindex directive.")
})

test_that("producer remediation_hint passes through on the baseline path too", {
  # remediation_hint is a pinned column, so pass-through does not require a
  # ruleset; a producer hint survives with ruleset = NULL and no v2 columns.
  parts <- list(page_part(remediation_hint = "Fix it."))
  out <- assemble_findings(parts, "strict", ruleset = NULL)
  expect_identical(out$remediation_hint, "Fix it.")
  expect_named(out, contract_cols)
  expect_false("context" %in% names(out))
  expect_false("provenance" %in% names(out))
})

test_that("producer-supplied provenance overrides the (code,ruleset) default", {
  # PROTOCOL_URL_OUT_OF_SCOPE defaults to "documented" under google; a producer
  # verdict of "inferred" (the cross-channel fold, §0.10) overrides it.
  parts <- list(page_part(provenance = "inferred"))
  out <- assemble_findings(
    parts,
    "strict",
    ruleset = findings_ruleset_spec("google", ruleset_context())
  )
  expect_identical(out$provenance, "inferred")
})

test_that("an NA producer provenance keeps the (code,ruleset) default", {
  # a producer that attaches the column but leaves a row NA must not clobber the
  # per-code default; PROTOCOL_URL_OUT_OF_SCOPE stays "documented" under google.
  parts <- list(page_part(provenance = NA_character_))
  out <- assemble_findings(
    parts,
    "strict",
    ruleset = findings_ruleset_spec("google", ruleset_context())
  )
  expect_identical(out$provenance, "documented")
})

test_that("producer optional columns do not leak into the baseline schema", {
  # context / provenance are v2-additive; on the NULL baseline path a producer
  # that attaches them must still yield the frozen 10-column contract.
  parts <- list(page_part(
    context = list(list(status_code = 404L)),
    provenance = "inferred"
  ))
  out <- assemble_findings(parts, "strict", ruleset = NULL)
  expect_named(out, contract_cols)
  expect_false("context" %in% names(out))
  expect_false("provenance" %in% names(out))
})

test_that("defaults are byte-identical whether or not a producer opts in", {
  # the same logical part with vs. without the (empty) optional columns must
  # assemble to an identical tibble -- padding + merge collapse to the stamp.
  base <- protocol_findings(
    code = "PROTOCOL_URL_OUT_OF_SCOPE",
    severity = "warning",
    subject_type = "entry",
    subject_ref = "sitemap://e.com/s.xml#entry:1",
    message = "page finding",
    evidence = list(finding_evidence()),
    is_strict_only = FALSE
  )
  spec <- findings_ruleset_spec("google", ruleset_context())
  plain <- assemble_findings(list(base), "strict", ruleset = spec)
  opted <- assemble_findings(
    list(page_part(
      context = vector("list", 1L),
      provenance = NA_character_,
      remediation_hint = NA_character_
    )),
    "strict",
    ruleset = spec
  )
  expect_identical(plain, opted)
})
