#!/usr/bin/env Rscript
# check-news-version v1
#
# The top NEWS.md heading is "(development version)" or the DESCRIPTION
# Version, so the two are bumped together.
#
#   Rscript scripts/check-news-version.R      # from the package root
#
# A cheap gate of the fleet-ci local gate (.fleet-ci.yml), run in the full
# tier. It was a step of the former CI `citation-version` job; copied from
# ssrfr's scripts/. Exit 1, naming both values, when they disagree.

version <- read.dcf("DESCRIPTION", fields = "Version")[[1L]]
news <- readLines("NEWS.md", warn = FALSE, encoding = "UTF-8")
top <- grep("^# ", news, value = TRUE)[1L]
heading <- sub("^#[[:space:]]+(sitemapr[[:space:]]+)?", "", top)
cat("DESCRIPTION Version: '", version, "'\n", sep = "")
cat("Top NEWS heading:    '", heading, "'\n", sep = "")
if (!heading %in% c("(development version)", version)) {
  cat(
    "The top NEWS.md heading is neither '(development version)' nor the ",
    "DESCRIPTION Version. Update NEWS.md.\n",
    sep = ""
  )
  quit(status = 1L)
}
