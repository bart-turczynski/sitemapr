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
  "page",
  "robots",
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
    sep = "\x1f"
  )
  findings[!duplicated(key), , drop = FALSE]
}

# The four additive schema-v2 columns (findings-contract.md "Additive
# output-tibble fields (schema v2)"), appended AFTER the ten pinned columns in
# this order. They appear ONLY under an engine overlay; the baseline path never
# sees them, so the schema-v1 ten-column contract holds byte-for-byte.
findings_additive_cols <- function() {
  c("ruleset", "ruleset_revision", "context", "provenance")
}

# The single default provenance for a finding produced under an engine overlay
# in this slice. No per-engine evaluators exist yet, so every finding is a
# reused baseline code explicitly inherited from the sitemaps.org baseline (an
# ADR-009 §0 executable class; findings-contract.md "Provenance vocabulary").
# Later slices override this per code where an engine evaluator produces a
# genuinely engine-specific verdict; keeping it a single named default is the
# hook they extend.
findings_default_provenance <- function() {
  "inherited_protocol"
}

# Per-(ruleset, code) provenance overrides for the §12 provenance tables. A
# finding's provenance defaults to `findings_default_provenance()`
# (`inherited_protocol`); an entry here overrides it where §12 assigns a
# different §0 tag to a specific code under an engine. §12.2a page-scope
# (`PROTOCOL_URL_OUT_OF_SCOPE`) and §12.2b index-child scope
# (`INDEX_CHILD_OUT_OF_SCOPE`): google/yandex `documented`, bing the inherited
# baseline. §12.5 yandex decoded-URL-length rule
# (`PROTOCOL_URL_DECODED_TOO_LONG`): an `application_choice` verdict yandex
# alone emits (google/bing do not, so no entry there). §12.5/§12.7 yandex
# per-tag data-limit guard (`PROTOCOL_TAG_DATA_LIMIT_EXCEEDED`): an `advisory`
# (tool-observed) verdict yandex alone emits. §12.3 yandex sitemap-format
# acceptance (`ENGINE_UNSUPPORTED_SITEMAP_FORMAT`): a `documented` verdict
# yandex alone emits (its rejected-format list is documented; the
# parse-then-reject mechanism is a message detail, not the provenance). §12.6
# inherited file-limit rules (`PROTOCOL_URL_COUNT_EXCEEDED`,
# `INDEX_CHILD_COUNT_EXCEEDED`, `PROTOCOL_SIZE_EXCEEDED`): all three engines
# independently document the 50,000-URL / 50 MB caps, so `documented` under
# each. §12.5 yandex raw-IRI acceptance (`PROTOCOL_URL_NOT_ESCAPED`): an
# explicit `inherited_protocol` record (equals the default, changes nothing)
# that a raw-IRI `<loc>` is engine-accepted under the RFC-3987 baseline. §12.7
# yandex metadata-acceptance rules (`PROTOCOL_LASTMOD_INVALID`,
# `PROTOCOL_CHANGEFREQ_INVALID`, `PROTOCOL_PRIORITY_OUT_OF_RANGE`): `documented`
# (Yandex's error dictionary lists these accepted_advisory cases as Warnings).
# Later slices extend this map.
findings_provenance_overrides <- function() {
  list(
    google = c(
      PROTOCOL_URL_OUT_OF_SCOPE = "documented",
      INDEX_CHILD_OUT_OF_SCOPE = "documented",
      PROTOCOL_URL_COUNT_EXCEEDED = "documented",
      INDEX_CHILD_COUNT_EXCEEDED = "documented",
      PROTOCOL_SIZE_EXCEEDED = "documented"
    ),
    bing = c(
      PROTOCOL_URL_OUT_OF_SCOPE = "inherited_protocol",
      INDEX_CHILD_OUT_OF_SCOPE = "inherited_protocol",
      PROTOCOL_URL_COUNT_EXCEEDED = "documented",
      INDEX_CHILD_COUNT_EXCEEDED = "documented",
      PROTOCOL_SIZE_EXCEEDED = "documented"
    ),
    yandex = c(
      PROTOCOL_URL_OUT_OF_SCOPE = "documented",
      INDEX_CHILD_OUT_OF_SCOPE = "documented",
      PROTOCOL_URL_DECODED_TOO_LONG = "application_choice",
      PROTOCOL_TAG_DATA_LIMIT_EXCEEDED = "advisory",
      ENGINE_UNSUPPORTED_SITEMAP_FORMAT = "documented",
      PROTOCOL_URL_COUNT_EXCEEDED = "documented",
      INDEX_CHILD_COUNT_EXCEEDED = "documented",
      PROTOCOL_SIZE_EXCEEDED = "documented",
      # spec 12.5: a raw-IRI <loc> is engine-accepted under the RFC-3987
      # baseline; this explicit inherited_protocol entry equals the default
      # and is an auditable record only -- it changes no behavior.
      PROTOCOL_URL_NOT_ESCAPED = "inherited_protocol",
      PROTOCOL_LASTMOD_INVALID = "documented",
      PROTOCOL_CHANGEFREQ_INVALID = "documented",
      PROTOCOL_PRIORITY_OUT_OF_RANGE = "documented"
    )
  )
}

# Per-(ruleset, code) severity relabels for the spec-12.7 metadata-acceptance
# rules. A finding keeps its emitted severity unless an entry here overrides it
# under the given ruleset. Under yandex an invalid lastmod / changefreq /
# priority is surfaced as a warning with the URL still valid (accepted_advisory,
# spec 12.7) rather than the baseline error -- never a hard failure. Later
# slices may extend this map.
findings_severity_overrides <- function() {
  list(
    yandex = c(
      PROTOCOL_LASTMOD_INVALID = "warning",
      PROTOCOL_CHANGEFREQ_INVALID = "warning",
      PROTOCOL_PRIORITY_OUT_OF_RANGE = "warning"
    )
  )
}

# Resolve the per-finding severity vector for a code vector under a ruleset,
# applying findings_severity_overrides() over each finding's emitted severity.
findings_severity_for <- function(code, ruleset, severity) {
  ov <- findings_severity_overrides()[[ruleset]]
  if (is.null(ov)) {
    return(severity)
  }
  hit <- match(code, names(ov))
  matched <- !is.na(hit)
  severity[matched] <- unname(ov[hit[matched]])
  severity
}

# Resolve the per-finding provenance vector for a code vector under a ruleset,
# applying findings_provenance_overrides() over the inherited-protocol default.
findings_provenance_for <- function(code, ruleset) {
  prov <- rep(findings_default_provenance(), length(code))
  ov <- findings_provenance_overrides()[[ruleset]]
  if (!is.null(ov)) {
    hit <- match(code, names(ov))
    matched <- !is.na(hit)
    prov[matched] <- unname(ov[hit[matched]])
  }
  prov
}

# Optional per-finding columns a producer MAY attach on top of the 8-column
# producer shape. `context` and `provenance` ride the schema-v2 additive
# surface; `remediation_hint` is already a pinned column. Absent by default:
# every current (baseline / protocol / schema / classification / index) producer
# attaches none, so the byte-identical path is preserved until a page producer
# opts in. When at least one part carries one of these, `findings_bind_parts()`
# pads the rest so heterogeneous parts row-bind cleanly.
findings_producer_optional_cols <- function() {
  c("context", "provenance", "remediation_hint")
}

# Row-bind the producer parts. When no part carries a producer-optional column
# this is the original `do.call(rbind, parts)` verbatim, so existing callers hit
# the exact baseline path. When a producer opts in, every part is padded with
# the absent optional columns (empty per-finding context, NA provenance, NA
# hint) so the parts share a column set and `rbind` matches them by name.
findings_bind_parts <- function(parts) {
  has_optional <- any(vapply(
    parts,
    function(p) any(findings_producer_optional_cols() %in% names(p)),
    logical(1)
  ))
  if (!has_optional) {
    return(do.call(rbind, parts))
  }
  parts <- lapply(parts, function(p) {
    n <- nrow(p)
    if (is.null(p[["context"]])) {
      p$context <- vector("list", n)
    }
    if (is.null(p[["provenance"]])) {
      p$provenance <- rep(NA_character_, n)
    }
    if (is.null(p[["remediation_hint"]])) {
      p$remediation_hint <- rep(NA_character_, n)
    }
    p
  })
  do.call(rbind, parts)
}

# Build the per-finding `context` list-column: each row's context is the uniform
# ruleset `base_ctx` MERGED with that finding's own contribution (if any).
# Producer keys WIN on collision (`modifyList` overlays `extra` onto `base`), so
# a page producer can refine an axis the ruleset also stamps. A finding that
# supplies no contribution (NULL / empty) gets the uniform `base_ctx` unchanged,
# which is exactly the pre-merge behavior.
findings_merge_context <- function(base_ctx, producer_context, n) {
  base_list <- rep(list(base_ctx), n)
  if (is.null(producer_context)) {
    return(base_list)
  }
  Map(
    function(base, extra) {
      if (is.null(extra) || length(extra) == 0L) {
        return(base)
      }
      utils::modifyList(base, extra)
    },
    base_list,
    producer_context
  )
}

# Resolve the per-finding `provenance`: it DEFAULTS to the `(code, ruleset)`
# value from `findings_provenance_for()`; a producer-supplied non-NA provenance
# OVERRIDES the default for those rows (§0.10 option (a)). A producer that
# supplies none (NULL, or all-NA) keeps the `(code, ruleset)` default, so the
# per-code provenance tables stay authoritative for every current producer.
findings_override_provenance <- function(default_prov, producer_provenance) {
  if (is.null(producer_provenance)) {
    return(default_prov)
  }
  supplied <- !is.na(producer_provenance)
  default_prov[supplied] <- as.character(producer_provenance[supplied])
  default_prov
}

# Stamp the additive engine-aware columns onto an assembled findings tibble.
# `ruleset` is a ruleset spec (a list of `ruleset`, `ruleset_revision`,
# `context`) or NULL for the baseline path. When NULL the tibble is returned
# UNCHANGED so the schema-v1 contract is byte-identical. When non-NULL the four
# columns are appended per row: the `ruleset` / `ruleset_revision` scalars, a
# `context` list-column carrying the context object as a plain named list, and
# the per-finding `provenance`. `producer_context` / `producer_provenance` are
# the (row-aligned) per-finding contributions captured before the 10-column
# re-impose; both default to NULL, in which case the columns collapse to the
# uniform-stamp / `(code, ruleset)`-default behavior of every existing caller.
findings_stamp_ruleset <- function(
  findings,
  ruleset,
  producer_context = NULL,
  producer_provenance = NULL
) {
  if (is.null(ruleset)) {
    return(findings)
  }
  n <- nrow(findings)
  findings$ruleset <- rep(ruleset$ruleset, n)
  findings$ruleset_revision <- rep(ruleset$ruleset_revision, n)
  findings$context <- findings_merge_context(
    unclass(ruleset$context),
    producer_context,
    n
  )
  findings$provenance <- findings_override_provenance(
    findings_provenance_for(findings$code, ruleset$ruleset),
    producer_provenance
  )
  findings$severity <- findings_severity_for(
    findings$code,
    ruleset$ruleset,
    findings$severity
  )
  findings <- findings_sort(findings)
  tibble::new_tibble(findings, nrow = n)
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
#' @param ruleset A ruleset spec (a list of `ruleset`, `ruleset_revision`,
#'   `context`) for the engine-aware surface, or `NULL` (the default, baseline
#'   path). When `NULL` the ten-column contract is emitted UNCHANGED; when
#'   non-`NULL` the four additive schema-v2 columns are appended (ADR-009 §6).
#' @return The 10-column contract tibble (`code, severity, layer, subject_type,
#'   subject_ref, message, evidence, mode, is_strict_only, remediation_hint`),
#'   in the contract's stable order — plus the four additive columns when
#'   `ruleset` is non-`NULL`. Same `parts` + `mode` (+ `ruleset`) yields a
#'   row-for-row identical tibble across calls.
#' @keywords internal
#' @noRd
assemble_findings <- function(parts, mode, ruleset = NULL) {
  parts <- parts[vapply(parts, nrow, integer(1)) > 0L]
  if (length(parts) == 0L) {
    return(findings_stamp_ruleset(empty_findings_contract(), ruleset))
  }

  findings <- findings_bind_parts(parts)
  findings$mode <- rep(mode, nrow(findings))
  findings <- findings_apply_mode(findings, mode)
  # remediation_hint pass-through: a producer-supplied hint column (any non-NA
  # rows) is PRESERVED; producers that supply none get the all-NA default. The
  # column is pinned (col 10), so it survives the re-impose below unchanged.
  if (is.null(findings[["remediation_hint"]])) {
    findings$remediation_hint <- rep(NA_character_, nrow(findings))
  } else {
    findings$remediation_hint <- as.character(findings$remediation_hint)
  }

  if (nrow(findings) == 0L) {
    return(findings_stamp_ruleset(empty_findings_contract(), ruleset))
  }

  findings <- findings_dedup(findings)
  findings <- findings_sort(findings)

  # Capture the row-aligned producer-supplied context / provenance BEFORE the
  # 10-column re-impose drops them; they feed the stamp's per-finding merge /
  # override. `[[` is NULL when the producer attached none -> default behavior.
  producer_context <- findings[["context"]]
  producer_provenance <- findings[["provenance"]]

  cols <- names(empty_findings_contract())
  findings <- findings[, cols, drop = FALSE]
  findings_stamp_ruleset(
    tibble::new_tibble(findings, nrow = nrow(findings)),
    ruleset,
    producer_context,
    producer_provenance
  )
}
