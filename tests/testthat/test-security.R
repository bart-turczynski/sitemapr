# OSS Index dependency vulnerability audit (oysteR / Sonatype).
#
# `oysteR::expect_secure("sitemapr")` resolves the installed DESCRIPTION and
# audits sitemapr's declared dependencies against the Sonatype OSS Index. It
# is a network test that requires OSS Index credentials (OSSINDEX_USER /
# OSSINDEX_TOKEN):
# the API rejects unauthenticated requests with HTTP 401, so the test is
# guarded to skip wherever those preconditions are absent (CRAN, offline,
# missing credentials, oysteR not installed). Nothing supplies those
# credentials automatically any more -- the security-audit.yml workflow that
# held them as repository secrets, and the README badge it drove, went with the
# deleted GitHub Actions tree (SITE-kgpdfhoh). So this audit runs only when a
# local environment sets OSSINDEX_USER / OSSINDEX_TOKEN, and skips cleanly
# rather than failing everywhere else.

test_that("declared dependencies have no known OSS Index vulnerabilities", {
  skip_on_cran()
  skip_if_not_installed("oysteR")
  skip_if_offline()
  skip_if(
    Sys.getenv("OSSINDEX_USER") == "" || Sys.getenv("OSSINDEX_TOKEN") == "",
    "OSS Index credentials (OSSINDEX_USER / OSSINDEX_TOKEN) not set"
  )

  oysteR::expect_secure("sitemapr")
})
