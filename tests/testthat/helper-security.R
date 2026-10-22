# Allow-list and helpers for the OSS Index dependency audit in
# test-security.R. The list lives here rather than in the test file because
# more than one test block reads it -- the offline well-formedness check and
# the network audit itself.
#
# Narrowing the audit to hard dependencies cleared five of the seven repos in
# this fleet. It does NOT clear sitemapr: `curl` is a genuine hard dependency
# here, reached through httr2. The advisories below name libcurl (or curl
# tool) version ranges that include CRAN's current `curl` 8.1.0 (OSS Index
# matches the R package's version number against those ranges), so there is
# no version to upgrade to and no local change that makes the audit clean. Each
# row says whether the advisory reaches a fetch sitemapr makes, citing the
# transport in R/fetch.R. Suppressing the
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
    version_seen = "8.1.0",
    review = as.Date("2026-12-01"),
    reason = paste(
      "CWE-416 use-after-free on HTTP/2 server push over a shared",
      "connection handle (CVSS 9.1, published 2026-09-06). Names a libcurl",
      "range covering CRAN's current curl 8.1.0, so no available version",
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
    version_seen = "8.1.0",
    review = as.Date("2026-12-01"),
    reason = paste(
      "CWE-522: an OAuth2 bearer token is leaked to a redirect target when",
      ".netrc carries a machine/default entry (CVSS 6.9). Names a libcurl",
      "range covering CRAN's current curl 8.1.0, so no available version",
      "clears it. The leak is in libcurl's own redirect following, which",
      "sitemapr never uses: fetch_build_request() (R/fetch.R) sets",
      "followlocation = 0 and maxredirs = 0 AFTER every policy field and",
      "the prepare hook, so no tls option can re-enable it, and redirects",
      "are followed manually, one fresh request per hop. Separate from this",
      "CVE and by design: that manual loop re-applies the policy's auth on",
      "every hop, cross-origin included. Re-check fetch_build_request()",
      "before renewing this row."
    )
  ),
  list(
    id = "CVE-2026-86410",
    package = "curl",
    version_seen = "8.1.0",
    review = as.Date("2026-12-01"),
    reason = paste(
      "CWE-297: the curl command-line tool sets its SSH host verification",
      "options only for a direct SFTP or SCP transfer, not for one reached",
      "by a redirect (CVSS 5.1). curl.se: only the command line tool is",
      "affected, not libcurl; the tool's range covers CRAN's current curl",
      "8.1.0, so no available version clears it. Unreachable through",
      "sitemapr: it drives libcurl through httr2 and never runs the curl",
      "tool, and it follows no redirect inside libcurl (followlocation = 0",
      "in fetch_build_request(), R/fetch.R). Re-check that sitemapr still",
      "shells out to no curl binary before renewing this row."
    )
  ),
  list(
    id = "CVE-2026-87865",
    package = "curl",
    version_seen = "8.1.0",
    review = as.Date("2026-12-01"),
    reason = paste(
      "CWE-295: libcurl built on libssh2, with a hashed known_hosts file,",
      "can report a host-key mismatch as a missing key to a",
      "CURLOPT_SSH_KEYFUNCTION callback; SFTP and SCP only (CVSS 6.9).",
      "Names a libcurl range covering CRAN's current curl 8.1.0, so no",
      "available version clears it. Unreachable through sitemapr: R/ sets",
      "no SSH option, the per-hop SSRF guard (ssrf_check(), R/ssrf.R)",
      "admits only http and https, and the callback the flaw needs cannot",
      "be installed from R -- curl 8.1.0's handle_setopt() rejects",
      "ssh_keyfunction as an unsupported option type, so neither a",
      "request_policy() tls list nor a prepare hook can set it, even with",
      "ssrf_guard = FALSE. Re-check that rejection before renewing."
    )
  )
)

# The fields every allow-list row carries, in the order they are documented.
oss_index_allowlist_fields <- c(
  "id",
  "package",
  "version_seen",
  "review",
  "reason"
)

# Problems with a set of allow-list rows, as a character vector; empty when the
# set is well formed. Written as a function returning findings rather than as a
# block of expectations so that it can be exercised against fixtures. The loop
# of expectations it replaces checked only the rows that happened to exist:
# nothing proved it would reject a malformed one, and with the list emptied it
# would assert nothing at all and still report as a passing test.
oss_index_allowlist_violations <- function(rows) {
  out <- character()

  parses_as_version <- function(x) {
    tryCatch(
      {
        package_version(x)
        TRUE
      },
      error = function(e) FALSE,
      warning = function(w) FALSE
    )
  }

  for (i in seq_along(rows)) {
    row <- rows[[i]]
    label <- sprintf("row %d", i)

    absent <- setdiff(oss_index_allowlist_fields, names(row))
    unknown <- setdiff(names(row), oss_index_allowlist_fields)
    if (length(absent) > 0) {
      out <- c(
        out,
        sprintf("%s: missing field(s): %s", label, toString(absent))
      )
    }
    if (length(unknown) > 0) {
      out <- c(
        out,
        sprintf("%s: unknown field(s): %s", label, toString(unknown))
      )
    }
    if (length(absent) > 0) {
      next
    }

    label <- sprintf("row %d (%s)", i, paste(row$id, collapse = " "))
    if (
      !is.character(row$id) ||
        length(row$id) != 1L ||
        !grepl("^CVE-[0-9]{4}-[0-9]+$", row$id)
    ) {
      out <- c(out, sprintf("%s: `id` is not a single CVE identifier", label))
    }
    if (
      !is.character(row$package) ||
        length(row$package) != 1L ||
        !nzchar(row$package)
    ) {
      out <- c(
        out,
        sprintf("%s: `package` is not a single package name", label)
      )
    }
    if (
      !is.character(row$version_seen) ||
        length(row$version_seen) != 1L ||
        !parses_as_version(row$version_seen)
    ) {
      out <- c(
        out,
        sprintf("%s: `version_seen` is not a parseable version", label)
      )
    }
    if (!inherits(row$review, "Date") || length(row$review) != 1L) {
      out <- c(out, sprintf("%s: `review` is not a single Date", label))
    }
    # A reason long enough to be an argument rather than a placeholder.
    if (
      !is.character(row$reason) ||
        length(row$reason) != 1L ||
        nchar(row$reason) <= 80
    ) {
      out <- c(
        out,
        sprintf("%s: `reason` is missing or too short to be an argument", label)
      )
    }
  }

  ids <- vapply(
    rows,
    function(row) {
      if (is.character(row$id) && length(row$id) == 1L) {
        row$id
      } else {
        NA_character_
      }
    },
    character(1)
  )
  duplicates <- unique(ids[duplicated(ids) & !is.na(ids)])
  if (length(duplicates) > 0) {
    out <- c(
      out,
      sprintf("duplicate allow-list id(s): %s", toString(duplicates))
    )
  }

  out
}

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
