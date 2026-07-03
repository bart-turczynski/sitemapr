#!/usr/bin/env Rscript

# Findings-registry guard (mirrors CI; run by the pre-push verify gate).
#
# docs/findings-registry.csv is the language-neutral source of truth for the
# finding-code contract, shared with the sibling TypeScript implementation
# (sitemap-validator). This guard keeps it honest in two ways:
#
#   1. WELL-FORMED: unique canonical codes; severity/layer/subject_type/status
#      drawn from the fixed vocabularies; is_strict_only a logical; reconcile
#      either blank or "open".
#   2. NO DRIFT: the set of finding-code string literals emitted by R/ must
#      equal the set of codes marked status == "active" in the registry. A new
#      code emitted without a registry row (or a row marked active with no
#      emitter) fails the build. This is the code-enforcement the scattered
#      string literals otherwise lack.
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

expected_cols <- c(
  "code",
  "severity",
  "layer",
  "subject_type",
  "is_strict_only",
  "status",
  "reconcile",
  "validator_code"
)
if (!identical(names(reg), expected_cols)) {
  stop(
    sprintf(
      "findings-registry.csv columns drifted.\n  expected: %s\n  got:      %s",
      paste(expected_cols, collapse = ", "),
      paste(names(reg), collapse = ", ")
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
  status = c("active", "reserved", "deferred-v0.2", "validator-only")
)

problems <- character(0)
add <- function(...) problems <<- c(problems, sprintf(...))

if (anyDuplicated(reg$code)) {
  add(
    "duplicate canonical codes: %s",
    paste(
      reg$code[duplicated(reg$code)],
      collapse = ", "
    )
  )
}
for (col in names(vocab)) {
  bad <- reg$code[!reg[[col]] %in% vocab[[col]]]
  if (length(bad)) {
    add("invalid %s value on: %s", col, paste(bad, collapse = ", "))
  }
}
if (!all(reg$is_strict_only %in% c("TRUE", "FALSE"))) {
  add(
    "is_strict_only must be TRUE/FALSE; offenders: %s",
    paste(
      reg$code[!reg$is_strict_only %in% c("TRUE", "FALSE")],
      collapse = ", "
    )
  )
}
if (!all(is.na(reg$reconcile) | reg$reconcile == "open")) {
  add(
    "reconcile must be blank or 'open'; offenders: %s",
    paste(
      reg$code[!(is.na(reg$reconcile) | reg$reconcile == "open")],
      collapse = ", "
    )
  )
}

# Drift: emitted literals vs active-status codes. Finding codes carry
# distinctive layer-oriented prefixes; match those as double-quoted literals in
# R/ source. Keep this prefix set in sync when a new code family is introduced.
code_pattern <- paste0(
  '"(SCHEMA_|PROTOCOL_|HREFLANG_|INDEX_|SITEMAP_INDEX|',
  'UNSUPPORTED_|ENCODING_|FETCH_)[A-Z0-9_]+"'
)
src <- unlist(lapply(
  list.files("R", pattern = "[.]R$", full.names = TRUE),
  readLines,
  warn = FALSE
))
emitted <- sort(unique(gsub(
  '"',
  "",
  unlist(regmatches(src, gregexpr(code_pattern, src)))
)))
active <- sort(reg$code[reg$status == "active"])

missing_row <- setdiff(emitted, active)
if (length(missing_row)) {
  add(
    "emitted in R/ but not status=active in the registry: %s",
    paste(missing_row, collapse = ", ")
  )
}
orphan_active <- setdiff(active, emitted)
if (length(orphan_active)) {
  add(
    "status=active in the registry but never emitted in R/: %s",
    paste(orphan_active, collapse = ", ")
  )
}

if (length(problems)) {
  stop(
    paste0(
      "findings-registry.csv is out of sync:\n",
      paste0("  - ", problems, collapse = "\n")
    ),
    call. = FALSE
  )
}

cat(sprintf(
  "findings registry OK (%d codes; %d active, matched to R/ emitters)\n",
  nrow(reg),
  length(active)
))
