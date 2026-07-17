# Per-engine validation context data layer (ADR-009 §1, sitemap-spec §12.0/
# §12.1). This file is the pure vocabulary layer: the `sitemap_ruleset` engine
# axis, its published revision, and the four independent per-source context
# axes. It defines value sets, constructors, and validators only; it does NOT
# wire anything into the validation pipeline (that is a later slice) and it does
# NOT evaluate scope or authority (S4/S5 own that).

# Raise the shared invalid-context abort, mirroring request_policy_reject(). One
# classed condition (`sitemapr_invalid_ruleset_context`) covers every context
# constructor so a caller can catch a single class.
ruleset_context_reject <- function(message) {
  rlang::abort(message, class = "sitemapr_invalid_ruleset_context")
}

# --- The sitemap_ruleset engine axis (§12.0) --------------------------------

#' Supported `sitemap_ruleset` values
#'
#' The engine axis of the ADR-009 validation context: the sitemaps.org baseline
#' plus the opt-in `google`, `bing`, and `yandex` overlays (sitemap-spec §12.0).
#' `sitemapr` owns this value set and it is extensible; this accessor is the one
#' canonical source vector every ruleset-aware surface validates against. The
#' baseline `"sitemaps.org"` is deliberately first so it is the default choice.
#'
#' @return A character vector of the supported ruleset names, baseline first.
#' @seealso [ruleset_revision()] for the published revision of a ruleset and
#'   [ruleset_context()] for the per-source context axes.
#' @export
#' @examples
#' sitemap_rulesets()
sitemap_rulesets <- function() {
  c("sitemaps.org", "google", "bing", "yandex")
}

# Validate a single `sitemap_ruleset` value against the canonical set and return
# it unchanged. Factored out so callers (e.g. ruleset_revision()) share one
# membership check instead of repeating the value set.
check_sitemap_ruleset <- function(ruleset) {
  if (!is.character(ruleset) || length(ruleset) != 1L || is.na(ruleset)) {
    ruleset_context_reject("`ruleset` must be a single ruleset name.")
  }
  if (!ruleset %in% sitemap_rulesets()) {
    ruleset_context_reject(
      sprintf(
        "`ruleset` must be one of %s.",
        paste(sitemap_rulesets(), collapse = ", ")
      )
    )
  }
  ruleset
}

# Published revision string per ruleset (ADR-009 §1/§7) for cross-repo pinning.
# One documented constant map is the single source of truth. All four rulesets
# were published together by ADR-009 / sitemap-spec §12 (2026-07-16), so they
# share that date-stamped revision until an overlay's rules change independently.
ruleset_revisions <- function() {
  c(
    "sitemaps.org" = "2026-07-16",
    "google" = "2026-07-16",
    "bing" = "2026-07-16",
    "yandex" = "2026-07-16"
  )
}

#' Published revision of a `sitemap_ruleset`
#'
#' Returns the published revision string for a ruleset (ADR-009 §1/§7) so
#' cross-repo consumers can pin a compatible version. The revisions live in one
#' documented constant map (a single source of truth); a ruleset's revision
#' advances only when that ruleset's own rules change.
#'
#' @param ruleset A single `sitemap_ruleset` name; see [sitemap_rulesets()].
#'   Defaults to the baseline `"sitemaps.org"`.
#' @return A length-1 character revision string.
#' @seealso [sitemap_rulesets()] for the value set.
#' @export
#' @examples
#' ruleset_revision()
#' ruleset_revision("yandex")
ruleset_revision <- function(ruleset = sitemap_rulesets()) {
  ruleset <- match.arg(ruleset)
  ruleset_revisions()[[ruleset]]
}

# --- The four per-source context axes (§12.1) -------------------------------

# Value sets for the per-source axes. Each is one canonical source vector with
# its neutral value first so it is the constructor default. `discovered` is
# deliberately NOT a submission value (§12.1); authority evidence is structured,
# never boolean (§12.1).
submission_channels <- function() {
  c("absent", "search_console_api", "webmaster_tools", "user", "import")
}

discovery_provenances <- function() {
  c(
    "organic",
    "robots_txt_reference",
    "supplied",
    "guessed_path",
    "index_child",
    "archive_derived"
  )
}

authority_evidence_values <- function() {
  c(
    "absent",
    "verified_property_set",
    "target_host_robots_reference",
    "same_location_default",
    "conflicting"
  )
}

# Validate `property_scope`: a single verified property/site string (a URL) or
# NA. It does not by itself grant authority beyond that property (§12.1); this
# check only guards its shape.
check_property_scope <- function(property_scope) {
  if (length(property_scope) != 1L) {
    ruleset_context_reject("`property_scope` must be a single string or NA.")
  }
  if (is.na(property_scope)) {
    return(NA_character_)
  }
  if (!is.character(property_scope) || !nzchar(property_scope)) {
    ruleset_context_reject(
      "`property_scope` must be a non-empty property/site string or NA."
    )
  }
  property_scope
}

#' Construct a per-source validation context (ADR-009 §1, §12.1)
#'
#' Bundles the four **independent** per-source context axes into a validated
#' object. There is deliberately no single `profile` scalar (ADR-009 §1);
#' `profile` stays reserved for the XSD schema-profile sense. Each axis carries
#' its own exact, extensible value set (`sitemapr` owns them):
#'
#' - `submission_channel` — how the artifact was submitted. `"discovered"` is
#'   **not** a submission value and is rejected; a child that inherits no
#'   submission facts is `"absent"`.
#' - `discovery_provenance` — how the artifact was found. A robots.txt reference
#'   used as cross-site trust is distinct from robots.txt *discovery*.
#' - `property_scope` — the verified property/site a submission is bound to (a
#'   URL/site string or `NA`); it does not by itself grant authority beyond that
#'   property.
#' - `authority_evidence` — **structured, never boolean**: the kind of evidence
#'   that establishes cross-site authority for this source.
#'
#' These are **per-source** facts: a sitemap-index child inherits nothing
#' implicitly (§12.1). Build a child's context from its own evidence with
#' [ruleset_context_for_child()], which takes no parent context. This
#' constructor is the pure data layer; it does not evaluate scope or authority.
#'
#' @param submission_channel One of `search_console_api`, `webmaster_tools`,
#'   `user`, `import`, or `absent` (default). `"discovered"` is rejected.
#' @param discovery_provenance One of `organic` (default), `robots_txt_reference`,
#'   `supplied`, `guessed_path`, `index_child`, or `archive_derived`.
#' @param property_scope The verified property/site string (a URL) or `NA`
#'   (default).
#' @param authority_evidence One of `absent` (default), `verified_property_set`,
#'   `target_host_robots_reference`, `same_location_default`, or `conflicting`.
#' @return An object of class `sitemapr_ruleset_context`: a named list of the
#'   four axes, the shape the findings `context` list-column carries
#'   (`docs/findings-contract.md`).
#' @seealso [ruleset_context_for_child()] for the per-source invariant helper
#'   and [sitemap_rulesets()] for the engine axis.
#' @export
#' @examples
#' ruleset_context()
#' ruleset_context(
#'   submission_channel = "search_console_api",
#'   property_scope = "https://example.com/",
#'   authority_evidence = "verified_property_set"
#' )
ruleset_context <- function(
  submission_channel = "absent",
  discovery_provenance = "organic",
  property_scope = NA_character_,
  authority_evidence = "absent"
) {
  submission_channel <- match.arg(submission_channel, submission_channels())
  discovery_provenance <- match.arg(
    discovery_provenance,
    discovery_provenances()
  )
  authority_evidence <- match.arg(
    authority_evidence,
    authority_evidence_values()
  )
  structure(
    list(
      submission_channel = submission_channel,
      discovery_provenance = discovery_provenance,
      property_scope = check_property_scope(property_scope),
      authority_evidence = authority_evidence
    ),
    class = "sitemapr_ruleset_context"
  )
}

#' Per-source context for a sitemap-index child (ADR-009 §1, §12.1 invariant)
#'
#' Expresses the per-source invariant that **a sitemap-index child inherits
#' nothing implicitly**: this helper takes **no parent context**, so a child's
#' context can only be established by its own evidence. The defaults encode a
#' child with no submission facts (`submission_channel = "absent"`), found as an
#' index child (`discovery_provenance = "index_child"`), no bound property, and
#' no authority evidence (`authority_evidence = "absent"`). A caller supplies
#' the child's own evidence via the arguments.
#'
#' This is the invariant-respecting context primitive only; it does **not**
#' evaluate scope or authority (§12.2; S4/S5 own those). Because there is no
#' parent parameter, a submitted or verified parent index cannot confer scope or
#' authority on a child by construction.
#'
#' @inheritParams ruleset_context
#' @return An object of class `sitemapr_ruleset_context` built solely from the
#'   child's own evidence.
#' @seealso [ruleset_context()] for the general constructor.
#' @export
#' @examples
#' # A child with no evidence of its own: nothing is inherited from the parent.
#' ruleset_context_for_child()
#'
#' # A child that carries its own verified-property evidence.
#' ruleset_context_for_child(
#'   property_scope = "https://cdn.example.com/",
#'   authority_evidence = "verified_property_set"
#' )
ruleset_context_for_child <- function(
  submission_channel = "absent",
  discovery_provenance = "index_child",
  property_scope = NA_character_,
  authority_evidence = "absent"
) {
  ruleset_context(
    submission_channel = submission_channel,
    discovery_provenance = discovery_provenance,
    property_scope = property_scope,
    authority_evidence = authority_evidence
  )
}
