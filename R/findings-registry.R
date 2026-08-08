# The finding-code registry, readable at run time (Layer F contract surface).
#
# `docs/findings-registry.csv` is the language-neutral source of truth for the
# finding-code contract, shared byte-for-byte with the sibling TypeScript port
# (sitemap-validator) and guarded by `tools/check-findings-registry.R`. But
# `docs/` is `.Rbuildignore`d, so an INSTALLED package cannot see it: package
# code that needs the registry at run time (the report's passed-checks table,
# SITE-sftfhtlv) would have nothing to read.
#
# The same file is therefore also SHIPPED, at `inst/findings-registry.csv`, and
# read from there via `system.file()` — the arrangement the bundled XSDs already
# use (`inst/schemas`, R/schema-catalog.R). The duplication cannot drift: the
# registry guard asserts the two copies are byte-identical, so the `docs/` copy
# stays the cross-port artifact and the shipped copy is what run-time code sees.

# Session cache for the parsed registry. The file is read-only package content,
# so a re-read can only ever produce the same rows; the cache exists so a report
# render does not re-parse it per section. Injectable for testing.
findings_registry_cache <- new.env(parent = emptyenv())

# The shipped registry as a data frame, with the CSV's own column names
# (`code`, `severity`, `layer`, `subject_type`, `is_strict_only`, `status`,
# `reconcile`, `validator_code`, `ruleset`). Blank cells read as NA.
findings_registry <- function(cache = findings_registry_cache) {
  hit <- cache$registry
  if (!is.null(hit)) {
    return(hit)
  }
  reg <- utils::read.csv(
    system.file("findings-registry.csv", package = "sitemapr"),
    stringsAsFactors = FALSE,
    na.strings = ""
  )
  cache$registry <- reg
  reg
}

# The `active` codes only, as `code`/`severity`/`layer`/`ruleset` rows in
# registry order.
#
# Status is the eligibility gate for any "this check ran" claim: a
# `validator-only` row names a check the sibling has and this port does NOT,
# and `reserved` / `deferred-*` rows name codes nothing emits yet. Reporting one
# of those as a check that passed would claim a check that does not exist here,
# which is worse than saying nothing.
#
# `ruleset` is the second gate, and the reason this returns four columns rather
# than three: status says the emitter EXISTS here, `ruleset` says which calls
# can reach it (SITE-lbhbltzf). Without it the report reads layer membership
# alone and claims an engine-gated check passed on a baseline run.
findings_active_codes <- function() {
  reg <- findings_registry()
  cols <- c("code", "severity", "layer", "ruleset")
  reg[reg$status == "active", cols, drop = FALSE]
}
