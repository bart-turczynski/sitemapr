# Shared "problems" tibble for the parse layer (Layer C; PRD §1, §9).
#
# Internal only. `problems` is the non-fatal companion to the parsed-row output:
# a tidy record of things that were skipped or downgraded rather than failing
# the whole read (a non-sitemap file inside an archive, a path-traversal entry
# rejected for safety, a child that could not be fetched, ...). The
# read_sitemap() entrypoint attaches the accumulated table to its result as the
# `problems` attribute (architecture.md §7 / PRD §1).
#
# IMPORTANT: problems are NOT validation findings. The parse API never emits a
# findings tibble (architecture.md §3); `validate_sitemap()` owns that contract
# (docs/findings-contract.md). This is a deliberately lightweight,
# parse-internal shape that borrows the findings *vocabulary* (severity,
# category, a stable subject ref) without the validation machinery (no `code`,
# no profile, no rule engine).
#
# Columns (fixed order/types):
#   severity     character  "info" | "warning"  (parse never downgrades an
#                           error to a problem; fatal conditions are raised)
#   category     character  coarse area, e.g. "decompression", "classification"
#   subject_ref  character  stable reference to the subject, e.g. an
#                           "<archive>#archive-member:<path>" ref
#   message      character  human-readable explanation

#' Construct a parse-problems tibble
#'
#' The single constructor for the `problems` attribute companion table. Scalars
#' recycle to the row count implied by the longest argument; an all-default call
#' yields the zero-row schema.
#'
#' @param severity,category,subject_ref,message Character vectors (recycled).
#' @return A tibble with the four `problems` columns.
#' @keywords internal
#' @noRd
parse_problems <- function(
  severity = character(0),
  category = character(0),
  subject_ref = character(0),
  message = character(0)
) {
  tibble::tibble(
    severity = as.character(severity),
    category = as.character(category),
    subject_ref = as.character(subject_ref),
    message = as.character(message)
  )
}

# A zero-row problems tibble.
empty_problems <- function() {
  parse_problems()
}

# Row-bind a list of problems tibbles (or a mix with NULLs) into one table,
# preserving the schema when the list is empty.
combine_problems <- function(parts) {
  parts <- parts[!vapply(parts, is.null, logical(1L))]
  if (length(parts) == 0L) {
    return(empty_problems())
  }
  do.call(rbind, parts)
}
