#!/usr/bin/env Rscript

# Reproducible-docs guard (mirrors CI; run by the pre-push verify gate).
#
# man/ and NAMESPACE are roxygen2-generated. Different roxygen2 versions emit
# subtly different output (whitespace reflows, stray .Rd files for internal
# functions), so a contributor on a different version regenerates spurious
# churn. This script makes that non-negotiable in two steps:
#
#   1. PIN: assert the installed roxygen2 matches Config/roxygen2/version in
#      DESCRIPTION. That field is the single source of truth for the pin.
#   2. REPRODUCIBILITY: regenerate the docs and fail if anything under man/ or
#      NAMESPACE changed — i.e. the committed output was not produced by the
#      pinned version, or the roxygen comments drifted from the generated docs.

desc <- read.dcf("DESCRIPTION")
pinned <- if ("Config/roxygen2/version" %in% colnames(desc)) {
  trimws(desc[, "Config/roxygen2/version"][[1L]])
} else {
  stop(
    "DESCRIPTION has no 'Config/roxygen2/version' field to pin against.",
    call. = FALSE
  )
}

installed <- as.character(utils::packageVersion("roxygen2"))
if (installed != pinned) {
  stop(
    sprintf(
      paste0(
        "roxygen2 version mismatch: installed %s, pinned %s ",
        "(DESCRIPTION Config/roxygen2/version).\n",
        "Install the pinned version so generated docs are reproducible:\n",
        "  Rscript -e 'pak::pak(\"roxygen2@%s\")'"
      ),
      installed,
      pinned,
      pinned
    ),
    call. = FALSE
  )
}

# Digest the generated files before and after regeneration. Comparing the
# working tree to itself (not to HEAD) measures exactly "did roxygenise change
# anything", so legitimate-but-uncommitted doc edits don't trip the guard while
# genuine drift (stale docs, wrong roxygen2 version output) still does.
generated <- c(
  "NAMESPACE",
  list.files("man", pattern = "\\.Rd$", full.names = TRUE)
)
digest <- function(paths) {
  paths <- paths[file.exists(paths)]
  stats::setNames(unname(tools::md5sum(paths)), paths)
}
before <- digest(generated)

roxygen2::roxygenise()

after <- digest(c(
  "NAMESPACE",
  list.files("man", pattern = "\\.Rd$", full.names = TRUE)
))

changed <- names(after)[
  is.na(before[names(after)]) | before[names(after)] != after
]
removed <- setdiff(names(before), names(after))
drift <- c(changed, removed)
if (length(drift)) {
  stop(
    paste0(
      "Generated docs are out of date with the roxygen comments in R/.\n",
      "roxygen2::roxygenise() changed:\n",
      paste0("  ", sort(drift), collapse = "\n"),
      "\nRun devtools::document() and commit the result."
    ),
    call. = FALSE
  )
}

cat(sprintf("docs reproducible (roxygen2 %s)\n", pinned))
