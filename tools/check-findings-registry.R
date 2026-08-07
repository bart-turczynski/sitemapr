#!/usr/bin/env Rscript

# Findings-registry guard (mirrors CI; run by the pre-push verify gate).
#
# docs/findings-registry.csv is the language-neutral source of truth for the
# finding-code contract, shared with the sibling TypeScript implementation
# (sitemap-validator). This guard keeps it honest in two ways:
#
#   1. WELL-FORMED: unique canonical codes; severity/layer/subject_type/status/
#      ruleset drawn from the fixed vocabularies; is_strict_only a logical;
#      reconcile blank/"open"/"done".
#   2. NO DRIFT: the set of finding-code string literals emitted by R/ must
#      equal the set of codes marked status == "active" in the registry. A new
#      code emitted without a registry row (or a row marked active with no
#      emitter) fails the build. This is the code-enforcement the scattered
#      string literals otherwise lack. The drift check is active-only, so the
#      three not-yet-emitted statuses ("reserved", "deferred-v0.2",
#      "deferred-ruleset") are skipped — they carry no rows today, but stay in
#      the vocabulary for the next code registered ahead of its emitter. The
#      additive "ruleset" column marks each code's applicability: "baseline"
#      (shared, applies under every ruleset by inheritance) or an engine name
#      for a genuinely engine-specific rule; an engine-specific code is emitted
#      only when that overlay is selected, which is orthogonal to its status.
#
# Run from the package root (as the verify gate and lint.yaml do).

registry_path <- "docs/findings-registry.csv"
if (!file.exists(registry_path)) {
  stop(
    sprintf("%s not found (run from the package root).", registry_path),
    call. = FALSE
  )
}

reg <- utils::read.csv(registry_path, stringsAsFactors = FALSE, na.strings = "")

# The registry has to be readable at RUN time too (the report's passed-checks
# table reads it), and `docs/` is .Rbuildignore'd — so the same file ships at
# inst/findings-registry.csv and is read from there through system.file()
# (R/findings-registry.R). Assert the two copies are byte-identical: that is
# what makes the duplication safe. The docs copy stays the cross-port artifact.
shipped_path <- "inst/findings-registry.csv"
if (!file.exists(shipped_path)) {
  stop(
    sprintf(
      "%s not found: the registry must also ship for run-time reads.",
      shipped_path
    ),
    call. = FALSE
  )
}
if (
  !identical(
    readBin(registry_path, "raw", file.size(registry_path)),
    readBin(shipped_path, "raw", file.size(shipped_path))
  )
) {
  stop(
    sprintf(
      "%s and %s differ; copy the docs registry over the shipped one.",
      registry_path,
      shipped_path
    ),
    call. = FALSE
  )
}

# The PUBLISHED revision must describe the registry that is actually committed.
# `sitemap_contract()$registry_revision` is what a sibling port pins against
# (ADR-009 §7), so a registry edit that leaves the revision string behind
# publishes a stale identity. The digest pairs the two: change the CSV and this
# fails until both `findings_registry_revision()` and
# `findings_registry_digest()` are updated together. Sourced rather than
# imported so the guard runs without installing the package.
source("R/contract-version.R")
actual_digest <- unname(tools::md5sum(registry_path))
if (!identical(actual_digest, findings_registry_digest())) {
  stop(
    sprintf(
      paste0(
        "%s changed (md5 %s) but R/contract-version.R still publishes digest ",
        "%s for revision %s. Bump findings_registry_revision() to today and ",
        "set findings_registry_digest() to the new md5."
      ),
      registry_path,
      actual_digest,
      findings_registry_digest(),
      findings_registry_revision()
    ),
    call. = FALSE
  )
}

expected_cols <- c(
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
if (!identical(names(reg), expected_cols)) {
  stop(
    sprintf(
      "findings-registry.csv columns drifted.\n  expected: %s\n  got:      %s",
      toString(expected_cols),
      toString(names(reg))
    ),
    call. = FALSE
  )
}

vocab <- list(
  severity = c("fatal", "error", "warning", "info"),
  layer = c(
    "input",
    "fetch",
    "discovery",
    "classification",
    "decompression",
    "schema",
    "protocol",
    "index-expansion",
    "page",
    "robots",
    "report"
  ),
  subject_type = c(
    "document",
    "entry",
    "field",
    "index-child",
    "archive-member",
    "source",
    "report",
    "page-url"
  ),
  status = c(
    "active",
    "reserved",
    "deferred-v0.2",
    "deferred-ruleset",
    "validator-only"
  ),
  ruleset = c("baseline", "google", "bing", "yandex")
)

# Every check below appends to one list so a bad registry reports all of its
# problems at once rather than one per run. The accumulator lives in an
# environment because `add()` has to write to a caller's binding, and `<<-` is
# on this project's undesirable-operator list (.lintr).
state <- new.env(parent = emptyenv())
state$problems <- character(0)
add <- function(...) {
  state$problems <- c(state$problems, sprintf(...))
}

if (anyDuplicated(reg$code)) {
  add(
    "duplicate canonical codes: %s",
    toString(reg$code[duplicated(reg$code)])
  )
}
for (col in names(vocab)) {
  bad <- reg$code[!reg[[col]] %in% vocab[[col]]]
  if (length(bad)) {
    add("invalid %s value on: %s", col, toString(bad))
  }
}
if (!all(reg$is_strict_only %in% c("TRUE", "FALSE"))) {
  add(
    "is_strict_only must be TRUE/FALSE; offenders: %s",
    toString(reg$code[!reg$is_strict_only %in% c("TRUE", "FALSE")])
  )
}
reconcile_values <- c("open", "done")
if (!all(is.na(reg$reconcile) | reg$reconcile %in% reconcile_values)) {
  add(
    "reconcile must be blank, 'open', or 'done'; offenders: %s",
    toString(
      reg$code[!(is.na(reg$reconcile) | reg$reconcile %in% reconcile_values)]
    )
  )
}

# validator_code is the cross-port join key: it must be INJECTIVE where present.
# Two sitemapr codes sharing one target silently collapses a genuine
# classification difference into apparent agreement, which is worse for a
# conformance harness than no mapping at all. Two such collapses shipped
# undetected (ENCODING_BOM_DECLARATION_CONFLICT + ENCODING_CONFLICT, and
# UNSUPPORTED_MALFORMED_ARCHIVE + UNSUPPORTED_MALFORMED_GZIP) precisely because
# nothing checked this. A blank validator_code means "not comparable" and is
# exempt — several codes legitimately have no counterpart.
mapped <- reg$validator_code[!is.na(reg$validator_code)]
if (anyDuplicated(mapped)) {
  collapsed <- unique(mapped[duplicated(mapped)])
  add(
    "validator_code must be unique where present (join collapse): %s",
    paste(
      vapply(
        collapsed,
        function(v) {
          sprintf(
            "%s <- {%s}",
            v,
            toString(
              reg$code[!is.na(reg$validator_code) & reg$validator_code == v]
            )
          )
        },
        character(1)
      ),
      collapse = "; "
    )
  )
}

# Drift: emitted literals vs active-status codes. Finding codes carry
# distinctive layer-oriented prefixes; match those as double-quoted literals in
# R/ source. Keep this prefix set in sync when a new code family is introduced.
code_pattern <- paste0(
  '"(SCHEMA_|PROTOCOL_|HREFLANG_|INDEX_|SITEMAP_INDEX|ENGINE_|',
  'UNSUPPORTED_|ENCODING_|FETCH_|DECOMPRESS_|ROBOTS_|PAGE_|REPORT_)[A-Z0-9_]+"'
)
src <- unlist(lapply(
  list.files("R", pattern = "[.]R$", full.names = TRUE),
  readLines,
  warn = FALSE
))
emitted <- sort(unique(gsub(
  '"',
  "",
  unlist(regmatches(src, gregexpr(code_pattern, src))),
  fixed = TRUE
)))
active <- sort(reg$code[reg$status == "active"])

missing_row <- setdiff(emitted, active)
if (length(missing_row)) {
  add(
    "emitted in R/ but not status=active in the registry: %s",
    toString(missing_row)
  )
}
orphan_active <- setdiff(active, emitted)
if (length(orphan_active)) {
  add(
    "status=active in the registry but never emitted in R/: %s",
    toString(orphan_active)
  )
}

if (length(state$problems)) {
  stop(
    "findings-registry.csv is out of sync:\n",
    paste0("  - ", state$problems, collapse = "\n"),
    call. = FALSE
  )
}

cat(sprintf(
  "findings registry OK (%d codes; %d active, matched to R/ emitters)\n",
  nrow(reg),
  length(active)
))
