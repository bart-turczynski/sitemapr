# Findings assembler, Layer F core (architecture.md §3;
# docs/findings-contract.md). Internal only.
#
# `assemble_findings()` is the deterministic, side-effect-free core that turns
# the per-producer finding tibbles (Layer C schema, Layer D protocol,
# classification, index-expansion) into `validate_sitemap()`'s final output
# contract. It is pure assembly: it does NOT read sources, parse, or call the
# producers (that is F.2). The producers each emit the same 8-column shape
# (`code, severity, layer, subject_type, subject_ref, message, evidence,
# is_strict_only`); this function row-binds them, stamps the `mode` column,
# applies the strict/non-strict severity model (findings-contract.md
# "Strict-vs-non-strict"; sitemap-spec.md §6), adds the `remediation_hint`
# column, de-duplicates, and sorts into the contract's stable order.

# The fixed layer order from the findings-contract layer vocabulary. The `layer`
# column is sorted by this order (NOT alphabetically); encoded as factor levels.
findings_layer_order <- c(
  "input",
  "fetch",
  "discovery",
  "classification",
  "decompression",
  "schema",
  "protocol",
  "index-expansion",
  "report"
)

# The severity ranking, most-severe first. Sorting is by severity DESCENDING
# (fatal > error > warning > info), so these levels are reversed before use as
# factor levels (a smaller integer code sorts first).
findings_severity_order <- c("fatal", "error", "warning", "info")

# Codes elevated from `info` to `warning` in strict mode (findings-contract.md;
# producers emit them at their non-strict `info` baseline with
# is_strict_only = FALSE, and Layer F owns the elevation).
findings_strict_elevations <- c(
  "ENCODING_BOM_DECLARATION_CONFLICT",
  "PROTOCOL_LASTMOD_LOOKS_GENERATED"
)

# A zero-row 10-column contract tibble with the exact column types. Used when
# there is nothing to assemble, and as the type template the row-bound parts
# extend with `mode` and `remediation_hint`.
empty_findings_contract <- function() {
  tibble::tibble(
    code = character(0),
    severity = character(0),
    layer = character(0),
    subject_type = character(0),
    subject_ref = character(0),
    message = character(0),
    evidence = list(),
    mode = character(0),
    is_strict_only = logical(0),
    remediation_hint = character(0)
  )
}

# One `evidence` cell for a finding, with the excerpt clamped to the contract's
# 500-char cap (findings-contract.md). Shared by every producer (schema,
# protocol, classification, index-expansion) so the evidence shape is defined
# in exactly one place.
finding_evidence <- function(
  excerpt = NA_character_,
  line = NA_integer_,
  column = NA_integer_
) {
  if (!is.na(excerpt)) {
    excerpt <- substr(excerpt, 1L, 500L)
  }
  list(excerpt = excerpt, line = as.integer(line), column = as.integer(column))
}

# Apply the strict/non-strict severity model to the row-bound, mode-stamped
# findings (findings-contract.md "Strict-vs-non-strict"; sitemap-spec.md §6).
findings_apply_mode <- function(findings, mode) {
  if (identical(mode, "non-strict")) {
    findings <- findings[!findings$is_strict_only, , drop = FALSE]
    schema_violation <- findings$layer == "schema" &
      findings$severity %in% c("fatal", "error")
    findings$severity[schema_violation] <- "warning"
    return(findings)
  }
  elevate <- findings$code %in%
    findings_strict_elevations &
    findings$severity == "info"
  findings$severity[elevate] <- "warning"
  findings
}

# Drop exact-duplicate rows, keyed on code + subject_ref + severity + message.
# Stable: keeps the first occurrence (producers should not emit duplicates
# within one source, but cross-producer/assembly dedup is Layer F's contract).
findings_dedup <- function(findings) {
  key <- paste(
    findings$code,
    findings$subject_ref,
    findings$severity,
    findings$message,
    sep = ""
  )
  findings[!duplicated(key), , drop = FALSE]
}

# Sort into the contract's stable order: layer (per the layer vocabulary, not
# alphabetical), then severity descending (fatal first), then subject_ref
# lexicographically, then code. Layer and severity ranks are fixed factor
# levels so the order never depends on the data present.
findings_sort <- function(findings) {
  layer_rank <- factor(findings$layer, levels = findings_layer_order)
  severity_rank <- factor(findings$severity, levels = findings_severity_order)
  ord <- order(
    as.integer(layer_rank),
    as.integer(severity_rank),
    findings$subject_ref,
    findings$code,
    method = "radix"
  )
  findings[ord, , drop = FALSE]
}

#' Assemble producer finding tibbles into the final contract tibble (Layer F)
#'
#' The deterministic, side-effect-free assembler core. Row-binds the
#' per-producer finding tibbles, stamps `mode`, applies the strict/non-strict
#' severity model, adds `remediation_hint`, de-duplicates, and sorts into the
#' contract's stable order. Pure assembly only — it does not read sources,
#' parse, or call the producers (that is F.2).
#'
#' @param parts A list of producer finding tibbles, each the 8-column shape
#'   (`code, severity, layer, subject_type, subject_ref, message, evidence,
#'   is_strict_only`); some may be zero-row, and the list itself may be empty.
#' @param mode `"strict"` or `"non-strict"`. In `non-strict`, rows with
#'   `is_strict_only == TRUE` are dropped and schema violations are downgraded
#'   to `warning`; in `strict`, the two documented info->warning codes are
#'   elevated.
#' @return The 10-column contract tibble (`code, severity, layer, subject_type,
#'   subject_ref, message, evidence, mode, is_strict_only, remediation_hint`),
#'   in the contract's stable order. Same `parts` + `mode` yields a row-for-row
#'   identical tibble across calls.
#' @keywords internal
#' @noRd
assemble_findings <- function(parts, mode) {
  parts <- parts[vapply(parts, nrow, integer(1)) > 0L]
  if (length(parts) == 0L) {
    return(empty_findings_contract())
  }

  findings <- do.call(rbind, parts)
  findings$mode <- rep(mode, nrow(findings))
  findings <- findings_apply_mode(findings, mode)
  findings$remediation_hint <- rep(NA_character_, nrow(findings))

  if (nrow(findings) == 0L) {
    return(empty_findings_contract())
  }

  findings <- findings_dedup(findings)
  findings <- findings_sort(findings)

  cols <- names(empty_findings_contract())
  findings <- findings[, cols, drop = FALSE]
  tibble::new_tibble(findings, nrow = nrow(findings))
}
