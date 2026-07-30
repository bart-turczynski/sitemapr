# Published cross-port contract identity (ADR-009 §7).
#
# ADR-009 §7 obliges each repo to publish BOTH its schema/ruleset revisions
# and its supported sibling-version ranges. `ruleset_revision()`
# (R/ruleset-context.R) publishes the per-ruleset half. This file publishes the
# rest, which was the outstanding half of the obligation (SITE-xptyuczr).
#
# The SHAPE is not invented here. The two sibling repos already publish a
# `sibling_versions` map and sitemapr was the only one of the three that did
# not:
#
#   robotstxtr        robots_engine_contract_v1()$sibling_versions
#                     (R/engine-contract-v1.R)
#   sitemap-validator SIBLING_VERSIONS
#                     (src/lib/services/robots/engine-contract.ts)
#
# Both are a named character map of package -> comma-separated range
# expression. sitemapr mirrors that shape exactly so a consumer reads all three
# the same way, rather than adding a third dialect to a three-repo contract.
#
# WHAT IS VERSIONED (the shape decision this file settles): one combined
# contract revision, not one per artifact. The findings registry, the contract's
# column set, and the ruleset set do not move independently in practice -- every
# change so far has been a coordinated cross-port event -- so three separately
# advancing revisions would be three chances to disagree. `sitemap_contract()`
# therefore publishes one identity with the per-ruleset map nested inside it.

# The findings-contract schema generation. "1" is the ten pinned legacy columns
# (findings-contract.md "Output tibble columns"); "2" is those plus the ADR-009
# additive ruleset fields. These deliberately mirror the sibling's
# FINDINGS_CONTRACT_VERSION / LEGACY_FINDINGS_CONTRACT_VERSION pair
# (src/lib/models/findings.ts) so the two ports name the same generations rather
# than each numbering its own.
contract_versions <- function() {
  c(current = "2", legacy = "1")
}

# Date-stamped revision of the finding-code registry this build publishes. It
# advances whenever docs/findings-registry.csv changes in a way a consumer can
# observe (a code added, a severity or subject_type changed, a status flipped).
#
# Kept honest by `tools/check-findings-registry.R`, which compares the
# registry's bytes against `findings_registry_digest()` below: editing the CSV
# without bumping BOTH values fails the verify gate. Without that guard the
# revision would be a string nobody is obliged to maintain, which is worse than
# publishing nothing.
findings_registry_revision <- function() {
  "2026-07-30"
}

# md5 of the registry bytes the revision above describes. Paired with it, never
# read on its own; see `findings_registry_revision()` for why it exists.
findings_registry_digest <- function() {
  "c8e6cbf89b849ad1d67e03788d5a67d8"
}

# Supported sibling-version ranges (ADR-009 §7). Ranges this build is KNOWN to
# work against, established by the integration actually exercised here -- not a
# guess at future compatibility:
#
#   sitemap-validator  the cross-port join is against its 1.x findings contract
#                      (FINDINGS_CONTRACT_VERSION "2"), so the range is its 1.x
#                      line. A 2.0.0 would be a contract generation sitemapr has
#                      not seen.
#   robotstxtr         sitemapr pins the engine contract
#                      "robotstxtr.engine-aware/v1" and gates on
#                      `matcher_capability` (R/robots-validate.R), which is a
#                      0.2.x build. 0.3.0 may carry the v2 contract, which
#                      sitemapr does not consume yet.
#
# Reciprocal by construction: both siblings declare sitemapr at
# ">= 0.0.0.9000, < 0.1.0", which this build's DESCRIPTION Version satisfies.
contract_sibling_versions <- function() {
  c(
    "sitemap-validator" = ">= 1.0.0, < 2.0.0",
    "robotstxtr" = ">= 0.2.0, < 0.3.0"
  )
}

#' Published cross-port contract of this sitemapr build
#'
#' Returns the contract identity that sibling implementations pin against
#' (ADR-009 §7): which findings-contract generation this build speaks, which
#' revision of the finding-code registry it ships, the per-ruleset revisions,
#' and the sibling-package version ranges it is known to work with.
#'
#' The `sibling_versions` map has the same shape as robotstxtr's
#' `robots_engine_contract_v1()$sibling_versions` and `sitemap-validator`'s
#' `SIBLING_VERSIONS`, so all three repos in the contract publish their ranges
#' identically.
#'
#' @return A named list:
#'   \describe{
#'     \item{`contract_id`}{Length-1 character. Stable identifier for the
#'       findings-contract generation, e.g. `"sitemapr.findings/v2"`.}
#'     \item{`contract_version`}{Length-1 character. The generation number.}
#'     \item{`legacy_contract_version`}{Length-1 character. The older generation
#'       still accepted by consumers.}
#'     \item{`registry_revision`}{Length-1 character. Date-stamped revision of
#'       `findings-registry.csv`.}
#'     \item{`ruleset_revisions`}{Named character. Per-ruleset revisions; the
#'       same values [ruleset_revision()] returns one at a time.}
#'     \item{`sibling_versions`}{Named character. Supported version range per
#'       sibling package.}
#'   }
#' @seealso [ruleset_revision()] for a single ruleset's revision.
#' @export
#' @examples
#' sitemap_contract()$sibling_versions
sitemap_contract <- function() {
  vers <- contract_versions()
  list(
    contract_id = paste0("sitemapr.findings/v", vers[["current"]]),
    contract_version = vers[["current"]],
    legacy_contract_version = vers[["legacy"]],
    registry_revision = findings_registry_revision(),
    ruleset_revisions = ruleset_revisions(),
    sibling_versions = contract_sibling_versions()
  )
}
