# OSS Index dependency vulnerability audit (oysteR / Sonatype).
#
# `oysteR::audit_description()` resolves the installed DESCRIPTION and audits
# sitemapr's hard dependencies against the Sonatype OSS Index. It is a network
# test that requires OSS Index credentials (OSSINDEX_USER / OSSINDEX_TOKEN):
# the API rejects unauthenticated requests with HTTP 401, so the test is
# guarded to skip wherever those preconditions are absent (CRAN, offline,
# missing credentials, oysteR not installed). Nothing supplies those
# credentials automatically any more -- the security-audit.yml workflow that
# held them as repository secrets, and the README badge it drove, went with
# the deleted GitHub Actions tree (SITE-kgpdfhoh). So this audit runs only
# when a local environment sets OSSINDEX_USER / OSSINDEX_TOKEN, and skips
# cleanly rather than failing everywhere else.
#
# Scope: hard dependencies only -- `Depends` + `Imports`, never `Suggests`.
#
# `oysteR::expect_secure()` audits `Suggests` as well, which drags in the
# recursive dependency trees of the dev tooling -- including oysteR's own. A
# vulnerability in the auditor is not a vulnerability in what sitemapr makes
# users install, and a package's security posture is the latter. Measured
# 2026-09-10: `Depends` + `Imports` audits 34 packages, the Suggests-inclusive
# scope 86. `audit_description()` is called directly because only it exposes
# `fields`; `expect_secure()` sets a CRAN mirror internally and
# `audit_description()` does not, hence the explicit `repos` option.
#
# The allow-list and rules A/B/C live in helper-security.R, next to the data
# they govern. Read that file before adding a row.

test_that("every OSS Index allow-list row is well formed", {
  expect_gt(length(oss_index_allowlist), 0)

  for (row in oss_index_allowlist) {
    expect_setequal(
      names(row),
      c("id", "package", "version_seen", "review", "reason")
    )
    expect_match(row$id, "^CVE-[0-9]{4}-[0-9]+$")
    expect_type(row$package, "character")
    expect_s3_class(row$review, "Date")
    # A reason long enough to be an argument rather than a placeholder.
    expect_gt(nchar(row$reason), 80)
  }

  ids <- vapply(oss_index_allowlist, function(row) row$id, character(1))
  expect_equal(anyDuplicated(ids), 0L)
})

test_that("hard dependencies report only allow-listed OSS Index advisories", {
  skip_on_cran()
  skip_if_not_installed("oysteR")
  skip_if_offline()
  skip_if(
    Sys.getenv("OSSINDEX_USER") == "" || Sys.getenv("OSSINDEX_TOKEN") == "",
    "OSS Index credentials (OSSINDEX_USER / OSSINDEX_TOKEN) not set"
  )

  old_repos <- getOption("repos")
  on.exit(options(repos = old_repos), add = TRUE)
  options(repos = c(CRAN = "https://cran.rstudio.com"))

  audit <- oysteR::audit_description(
    dirname(system.file("DESCRIPTION", package = "sitemapr")),
    fields = c("Depends", "Imports"),
    verbose = FALSE
  )
  found <- oss_index_reported(audit)
  allowed <- vapply(oss_index_allowlist, function(row) row$id, character(1))

  # Rule A -- an advisory reported and not allow-listed.
  expect_equal(sort(setdiff(found$id, allowed)), character())

  # Rule B -- an allow-listed advisory no longer reported. The list may not
  # over-permit, so a row that has outlived its justification fails here.
  expect_equal(sort(setdiff(allowed, found$id)), character())

  # Rule C -- drift warns, never fails. See helper-security.R.
  for (row in oss_index_allowlist) {
    if (Sys.Date() > row$review) {
      warning(
        sprintf(
          "OSS Index allow-list row %s is past its %s review date.",
          row$id,
          format(row$review)
        ),
        call. = FALSE
      )
    }
    hit <- found[found$id == row$id, ]
    if (
      nrow(hit) > 0 &&
        package_version(hit$version[1]) > package_version(row$version_seen)
    ) {
      warning(
        sprintf(
          paste(
            "OSS Index allow-list row %s was written against %s %s;",
            "the audit now reports %s. Re-read the advisory."
          ),
          row$id,
          row$package,
          row$version_seen,
          hit$version[1]
        ),
        call. = FALSE
      )
    }
  }
})
