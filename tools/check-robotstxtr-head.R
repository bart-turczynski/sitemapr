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
# repository yet. Everything goes in a temporary library. Run from the package
# root, with sitemapr's dependencies installed.

universe <- "https://bart-turczynski.r-universe.dev"
lib <- tempfile("robotstxtr-head-")
dir.create(lib)
# In CI the dependencies are in the template's run library (FLEET_RUN_LIB).
.libPaths(c(lib, Sys.getenv("FLEET_RUN_LIB"), .libPaths()))
# ssrfr's and robotstxtr's dependencies come from CRAN, so a failure here has to
# be robotstxtr's: r-universe builds every fleet package's main.
cran <- c("cpp11", "curl", "pslr", "raddr", "rurl")
head <- c("ssrfr", "robotstxtr")
utils::install.packages(cran, lib = lib)
utils::install.packages(
  head,
  lib = lib,
  repos = universe,
  dependencies = FALSE
)

# install.packages() only warns when a package fails, and the release already
# in the normal library would then pass unnoticed.
missing <- setdiff(c(cran, head), list.files(lib))
if (length(missing) > 0L) {
  stop("did not install: ", toString(missing), call. = FALSE)
}
message(
  "robotstxtr ",
  utils::packageVersion("robotstxtr", lib.loc = lib),
  ", ssrfr ",
  utils::packageVersion("ssrfr", lib.loc = lib)
)

Sys.setenv(NOT_CRAN = "true")
testthat::test_local(".", reporter = "summary", load_package = "source")
