# Runs active top-level .feature files as part of `R CMD check`. The feature
# drafts in features/ are acceptance criteria for the fp tracer-bullet tickets
# and should be activated as those implementations land.
test_that("acceptance specs pass", {
  skip_if_not_installed("cucumber")
  # Working directory during the test run is tests/testthat/, where the .feature
  # files live; steps were registered by the setup-steps-*.R files.
  cucumber::run(".")
})
