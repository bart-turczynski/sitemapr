# Decompression-layer diagnostics (Layer F; docs/findings-contract.md). Internal
# only.
#
# The decompression layer inflates a gzip stream and extracts a bounded local
# `.tar.gz` archive (R/decompress.R, R/parse-archive.R). Those modules signal
# failure as CLASSED CONDITIONS (never findings) so the parse API
# (`read_sitemap()`) can keep its throw-on-malformed contract. This file is the
# validate-flow side of that split: `validate_sitemap()` (Layer F) catches the
# same conditions and turns them into contract-shaped FINDINGS, exactly as the
# classification producers (R/classification-validate.R) turn an unsupported
# root or an HTML masquerade into a finding rather than an error.
#
# The four decompression finding codes (docs/findings-registry.csv):
#   - UNSUPPORTED_MALFORMED_GZIP   (error, subject_type source)          — a
#     corrupt/truncated gzip stream (`sitemapr_decompression_error`).
#   - UNSUPPORTED_MALFORMED_ARCHIVE(error, subject_type archive-member)  — a
#     truncated/garbage tar (`sitemapr_malformed_archive`).
#   - DECOMPRESS_TOO_MANY_FILES    (error, subject_type source)          — the
#     ADR-003 100-file archive cap was exceeded (`sitemapr_archive_limit`,
#     limit == "file_count").
#   - DECOMPRESS_NOT_SITEMAP       (info,  subject_type archive-member)  — an
#     archive member that is not a parseable sitemap was skipped (one per
#     member; mapped from the archive extractor's info-severity `problems`).
#
# sitemapr keeps its container distinction (gzip vs archive) on the
# `UNSUPPORTED_` axis and adopts the validator's failure-mode codes on the
# `DECOMPRESS_` axis — a net superset, no specificity dropped
# (docs/findings-contract.md, resolved reconciliation).
#
# Like every other producer these emit contract-shaped rows only and never
# assemble: no `mode`, no strict-severity adjustment, no dedup/sort. All carry
# `layer = "decompression"` (findings-contract.md layer vocabulary).

# Construct the decompression-layer findings tibble. Same column contract as the
# other producers, but `layer = "decompression"`.
decompression_findings <- function(
  code = character(0),
  severity = character(0),
  subject_type = character(0),
  subject_ref = character(0),
  message = character(0),
  evidence = list(),
  is_strict_only = logical(0)
) {
  n <- length(code)
  tibble::tibble(
    code = as.character(code),
    severity = as.character(severity),
    layer = rep("decompression", n),
    subject_type = as.character(subject_type),
    subject_ref = as.character(subject_ref),
    message = as.character(message),
    evidence = if (length(evidence) > 0L) evidence else vector("list", n),
    is_strict_only = as.logical(is_strict_only)
  )
}

# A zero-row decompression-findings tibble (no diagnostic).
empty_decompression_findings <- function() {
  decompression_findings()
}

# One source-level decompression finding (`subject_type = "source"`, the
# unfragmented `sitemap://…` base) — used for the whole-source failures
# (a malformed gzip stream, the archive file-count cap).
decompression_source_finding <- function(
  code,
  base,
  message,
  excerpt = NA_character_
) {
  decompression_findings(
    code = code,
    severity = "error",
    subject_type = "source",
    subject_ref = if (is.null(base)) NA_character_ else base,
    message = message,
    evidence = list(finding_evidence(excerpt = excerpt)),
    is_strict_only = FALSE
  )
}

# One archive-member decompression finding. `member_path` scopes it to a member
# via the `#archive-member:<path>` subject_ref fragment (findings-contract.md);
# `NA` (a whole-archive failure such as a truncated tar, which has no single
# offending member) leaves the ref at the archive base.
decompression_member_finding <- function(
  code,
  base,
  message,
  member_path = NA_character_,
  severity = "info"
) {
  ref <- if (is.na(member_path)) {
    if (is.null(base)) NA_character_ else base
  } else {
    protocol_ref_fragment(base, paste0("#archive-member:", member_path))
  }
  decompression_findings(
    code = code,
    severity = severity,
    subject_type = "archive-member",
    subject_ref = ref,
    message = message,
    evidence = list(finding_evidence(excerpt = member_path)),
    is_strict_only = FALSE
  )
}

# Map an archive extractor's `problems` table (R/parse-archive.R) to
# DECOMPRESS_NOT_SITEMAP findings: one per INFO-severity problem (a member that
# was not a parseable sitemap and was skipped). The problem's `subject_ref` is
# already the contract's `<base>#archive-member:<path>` form when the extractor
# is called with `source_ref = base`, so it is reused verbatim; the member path
# is recovered from it for the evidence excerpt. Warning-severity problems
# (path-traversal rejections) are a distinct concern and are not mapped here.
# Returns a (possibly empty) decompression-findings tibble.
decompression_findings_from_problems <- function(problems) { # nolint: object_length_linter, line_length_linter.
  if (is.null(problems) || nrow(problems) == 0L) {
    return(empty_decompression_findings())
  }
  info <- problems[problems$severity == "info", , drop = FALSE]
  if (nrow(info) == 0L) {
    return(empty_decompression_findings())
  }
  member_path <- sub("^.*#archive-member:", "", info$subject_ref)
  decompression_findings(
    code = rep("DECOMPRESS_NOT_SITEMAP", nrow(info)),
    severity = rep("info", nrow(info)),
    subject_type = rep("archive-member", nrow(info)),
    subject_ref = info$subject_ref,
    message = info$message,
    evidence = lapply(member_path, function(p) finding_evidence(excerpt = p)),
    is_strict_only = rep(FALSE, nrow(info))
  )
}
