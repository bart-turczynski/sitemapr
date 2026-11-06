#!/usr/bin/env Rscript

# sitemapr's tests against robotstxtr's main branch (the x-robotstxtr-head job).
#
# The gate and every other CI leg resolve robotstxtr from a release: the
# DESCRIPTION pin, or CRAN. robotstxtr's main can break sitemapr long before it
# reaches them. Its move to ssrfr did: the robots tests mocked httr2, which it
# no longer calls. robotstxtr's next submission has to pass sitemapr as a
# reverse dependency, so this says so early.
#
# The fleet's r-universe builds main, and supplies ssrfr, which is on no other
# repository yet. Both go in a temporary library. Run from the package root,
# with sitemapr's dependencies installed.

universe <- "https://bart-turczynski.r-universe.dev"
lib <- tempfile("robotstxtr-head-")
dir.create(lib)
utils::install.packages(
  c("ssrfr", "robotstxtr"),
  lib = lib,
  repos = c(universe, getOption("repos"))
)
.libPaths(c(lib, .libPaths()))

# install.packages() only warns when a package fails, and the release already
# in the normal library would then pass unnoticed.
installed <- rownames(utils::installed.packages(lib.loc = lib))
if (!all(c("ssrfr", "robotstxtr") %in% installed)) {
  stop("robotstxtr or ssrfr did not install from ", universe, call. = FALSE)
}
message(
  "robotstxtr ",
  utils::packageVersion("robotstxtr", lib.loc = lib),
  ", ssrfr ",
  utils::packageVersion("ssrfr", lib.loc = lib)
)

Sys.setenv(NOT_CRAN = "true")
testthat::test_local(".", reporter = "summary", load_package = "source")
