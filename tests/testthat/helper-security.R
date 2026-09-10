# Allow-list and helpers for the OSS Index dependency audit in
# test-security.R. The list lives here rather than in the test file because
# both test blocks read it -- the offline well-formedness check and the
# network audit itself.
#
# Narrowing the audit to hard dependencies cleared five of the seven repos in
# this fleet. It does NOT clear sitemapr: `curl` is a genuine hard dependency
# here, reached through httr2. The two advisories below name libcurl version
# ranges that include CRAN's current `curl` 8.0.0, so there is no version to
# upgrade to and no local change that makes the audit clean. Suppressing the
# whole gate to get past them would retire it for every OTHER dependency too,
# so each advisory is allow-listed BY ID with the reason it is permitted
# (SITE-epezowxs, deciding SEOR-feqgnbwt route (a)).
#
# Three rules keep the list honest. test-security.R enforces them:
#
#   A  UNEXPECTED  an advisory reported and not allow-listed FAILS. This is
#                  the gate still doing its job: a new vulnerability in httr2,
#                  xml2 or anything else stops the push.
#   B  STALE       an allow-listed advisory NO LONGER reported FAILS. An
#                  allow-list may not over-permit; a row that has outlived its
#                  justification is deleted, not left to widen the exemption
#                  silently. Same rule as C0 in rurl's tools/curl-zero-gate.R.
#   C  DRIFT       past its review date, or audited at a package version later
#                  than `version_seen`, a row WARNS. Deliberately not a
#                  failure: a calendar date that turns every push red is how a
#                  gate teaches people to reach for --no-verify. The warning
#                  is visible in the testthat summary and in CI logs.
#
# Adding a row is a decision, not a formality. Rule B is what keeps it one.

oss_index_allowlist <- list(
  list(
    id = "CVE-2026-18924",
    package = "curl",
    version_seen = "8.0.0",
    review = as.Date("2026-12-01"),
    reason = paste(
      "CWE-416 use-after-free on HTTP/2 server push over a shared",
      "connection handle (CVSS 9.1, published 2026-09-06). Names a libcurl",
      "range covering CRAN's current curl 8.0.0, so no available version",
      "clears it. The vulnerable path is also unreachable from R:",
      "curl::curl_options() exposes no option matching `push`, and",
      "curl::multi_set() takes only total_con, host_con, max_streams,",
      "multiplex and pool -- CURLMOPT_PUSHFUNCTION is not settable, so",
      "server push cannot be enabled. Re-check with those two calls before",
      "renewing this row; sitemapr does share connection handles, through",
      "httr2::req_perform_parallel()."
    )
  ),
  list(
    id = "CVE-2026-3783",
    package = "curl",
    version_seen = "8.0.0",
    review = as.Date("2026-12-01"),
    reason = paste(
      "CWE-522: an OAuth2 bearer token is leaked to a redirect target when",
      ".netrc carries a machine/default entry (CVSS 6.9). Names a libcurl",
      "range covering CRAN's current curl 8.0.0, so no available version",
      "clears it. This one IS reachable here -- request_auth_bearer() sets",
      "a token via httr2::req_auth_bearer_token(), and httr2 follows",
      "redirects -- so it is allow-listed as unfixable, NOT as harmless.",
      "The precondition is a .netrc machine/default entry on the calling",
      "machine; a caller combining a bearer token with such a .netrc",
      "should pin the fetch to a single host until libcurl ships a fix."
    )
  )
)

# Flatten an oysteR::audit_description() result to one row per reported
# advisory. The `vulnerabilities` column is a list of per-package lists, empty
# for a clean package, so the zero-advisory case has to survive unlist().
oss_index_reported <- function(audit) {
  ids <- lapply(audit$vulnerabilities, function(v) {
    if (length(v) == 0) {
      return(character())
    }
    vapply(v, function(x) as.character(x$id), character(1))
  })
  data.frame(
    package = rep(as.character(audit$package), lengths(ids)),
    version = rep(as.character(audit$version), lengths(ids)),
    id = as.character(unlist(ids, use.names = FALSE)),
    stringsAsFactors = FALSE
  )
}
