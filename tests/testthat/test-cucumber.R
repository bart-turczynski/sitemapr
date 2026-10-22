# Runs the .feature files in tests/testthat/ as part of `R CMD check`. The
# feature set is frozen (no new .feature file or scenario): new tests are plain
# testthat files, and a scenario that gets in the way of a change is replaced by
# a plain test of the same outcome, then deleted.
test_that("acceptance specs pass", {
  skip_if_not_installed("cucumber")
  # Working directory during the test run is tests/testthat/, where the .feature
  # files live; steps were registered by the setup-steps-*.R files.
  cucumber::run(".")
})
