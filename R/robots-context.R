# The robots policy/matcher axis carrier and its engine presets (ADR-009 §1,
# docs/sitemap-spec.md §13.0; E.1b, SITE-kwkggijf; promoted to public surface by
# SITE-fsawklnl).
#
# Kept separate from `ruleset_context()` on purpose. ADR-009 keeps its axes
# independent: `ruleset_context()` carries the four sitemap-SOURCE axes, and
# "which engine's robots semantics govern access" is a different question from
# "which engine's sitemap rules am I validating under". Nothing here derives a
# robots axis from `sitemap_ruleset`, and nothing there derives one from these.
#
# Axis values are validated against the value sets the INSTALLED `robotstxtr`
# publishes on its own contract, so an axis this build cannot honour fails here
# rather than deep inside the engine. Reading the sibling's published sets also
# means the accepted values follow it rather than a stale copy pinned here.

robots_context_reject <- function(message) {
  rlang::abort(message, class = "sitemapr_invalid_robots_context")
}

# A single non-NA, non-empty string, or reject naming the argument.
check_robots_axis <- function(value, arg) {
  if (
    !is.character(value) ||
      length(value) != 1L ||
      is.na(value) ||
      !nzchar(value)
  ) {
    robots_context_reject(
      sprintf("`%s` must be a single non-empty string.", arg)
    )
  }
  value
}

# Reject an axis value the INSTALLED robotstxtr does not publish. Read from the
# public contract, so the accepted sets follow the sibling rather than a stale
# copy pinned here.
check_robots_axis_value <- function(value, arg, allowed) {
  if (!value %in% allowed) {
    robots_context_reject(
      sprintf("`%s` must be one of %s.", arg, toString(allowed))
    )
  }
  value
}

#' Construct a robots evaluation context (ADR-009 §1, sitemap-spec §13.0)
#'
#' Bundles the three **independent** robots axes one allow/disallow evaluation
#' runs under. It is the carrier [validate_sitemap_robots()] accepts, and it is
#' deliberately separate from [ruleset_context()]: selecting a sitemap ruleset
#' does not select a robots policy (ADR-009 §1). A Bing *sitemap* ruleset does
#' not imply a Bing *robots* policy — the two are chosen independently.
#'
#' - `product_token` — the robots.txt group used for **matching**: `"*"` for
#'   the catch-all group, or a crawler token such as `"Googlebot"`. This is not
#'   the HTTP request user-agent sitemapr fetches with.
#' - `policy_ruleset` — whose HTTP-status → policy semantics govern (what a
#'   404, a 403 or a 5xx robots.txt *means*).
#' - `matcher_backend` — which matcher decides a rule against a URL.
#'
#' The vocabulary for the last two belongs to the sibling `robotstxtr` package,
#' not to sitemapr, and each value is validated against the set the
#' **installed** build publishes on its engine contract — so an axis this
#' build cannot honour is rejected here rather than deep inside the engine.
#' `robotstxtr` is an optional dependency; when it is absent only the shape of
#' each axis is checked.
#'
#' A backend whose published `token_policy` is `bounded_profiles` (Bing,
#' Yandex) accepts only its own vendor profile tokens, and the accepted set is
#' not published, so it cannot be validated here. An unsupported token is not an
#' error: every URL comes back undecided and surfaces as `ROBOTS_INDETERMINATE`.
#' Prefer [robots_context_preset()], whose tokens are known-good for their
#' backend.
#'
#' @param product_token The robots.txt group to match against; defaults to the
#'   catch-all `"*"`.
#' @param policy_ruleset The robots status-policy ruleset; defaults to
#'   `"google"`, the historical behavior of `validate_sitemap()`.
#' @param matcher_backend The robots matcher backend; defaults to `"google"`.
#' @return An object of class `sitemapr_robots_context`: a named list of the
#'   three axes.
#' @seealso [robots_context_preset()] for the per-engine presets,
#'   [validate_sitemap_robots()] for the entry point that accepts one, and
#'   [ruleset_context()] for the independent sitemap-source axes.
#' @export
#' @examples
#' robots_context()
#' robots_context(product_token = "Googlebot")
robots_context <- function(
  product_token = "*",
  policy_ruleset = "google",
  matcher_backend = "google"
) {
  check_robots_axis(product_token, "product_token")
  check_robots_axis(policy_ruleset, "policy_ruleset")
  check_robots_axis(matcher_backend, "matcher_backend")
  if (robotstxtr_available()) {
    contract <- robotstxtr_engine_contract()
    check_robots_axis_value(
      policy_ruleset,
      "policy_ruleset",
      contract$robots_policy_rulesets
    )
    check_robots_axis_value(
      matcher_backend,
      "matcher_backend",
      contract$matcher_backends
    )
  }
  structure(
    list(
      product_token = product_token,
      policy_ruleset = policy_ruleset,
      matcher_backend = matcher_backend
    ),
    class = "sitemapr_robots_context"
  )
}

# The preset table. Each entry is product_token / policy_ruleset /
# matcher_backend, in that order.
#
# The tokens are not decorative: a `bounded_profiles` backend refuses anything
# outside its own vendor profiles, and an unsupported token silently renders
# every URL indeterminate. Yandex's bounded profile accepts `"Yandex"` and not
# `"YandexBot"` — a test asserts each preset's token is honoured by its own
# backend, for every backend the installed sibling reports as available.
robots_preset_table <- function() {
  list(
    google = list("Googlebot", "google", "google"),
    bing = list("Bingbot", "bing", "bing"),
    yandex = list("Yandex", "yandex", "yandex"),
    rfc9309 = list("*", "rfc9309", "rfc9309")
  )
}

#' Supported [robots_context_preset()] names
#'
#' The engine presets of the naming bridge between the sitemap-ruleset and
#' robots-policy value sets (`docs/sitemap-spec.md` §13.0). `"google"` is
#' deliberately first so it is the default choice, matching the axis defaults
#' of [robots_context()].
#'
#' @return A character vector of the supported preset names.
#' @seealso [robots_context_preset()] to build one and [robots_context()] for
#'   the axes a preset expands to.
#' @export
#' @examples
#' robots_context_presets()
robots_context_presets <- function() {
  names(robots_preset_table())
}

#' Per-engine robots context preset (sitemap-spec §13.0)
#'
#' A construction-time preset selecting one engine's robots product token,
#' status policy and matcher together, so a caller need not know which token a
#' bounded matcher backend accepts. It is a thin wrapper over
#' [robots_context()]; every axis stays independently overridable by calling
#' that constructor directly.
#'
#' The preset's values are **expanded onto the returned context** rather than
#' re-derived at use time, so the result records exactly which product token,
#' policy ruleset and matcher backend the preset selected. The name is retained
#' on `$preset` for provenance.
#'
#' A preset selects a robots engine only. It does **not** select a sitemap
#' ruleset, and no sitemap ruleset selects it (ADR-009 §1): the bridge between
#' the two value sets is this documented preset, never a silent derivation.
#'
#' Not every preset is runnable on every install. `robotstxtr` publishes a
#' `matcher_availability` per backend, and one reporting
#' `capability_unavailable` decides nothing — a context on it evaluates
#' cleanly but reports every URL as `ROBOTS_INDETERMINATE` rather than
#' guessing.
#'
#' @param preset A single preset name; see [robots_context_presets()]. Defaults
#'   to `"google"`.
#' @return An object of class `sitemapr_robots_context`, the same shape
#'   [robots_context()] returns, carrying the expanded axis values plus the
#'   `preset` name.
#' @seealso [robots_context()] for the general constructor and
#'   [validate_sitemap_robots()] for the entry point that accepts the result.
#' @export
#' @examples
#' robots_context_preset("google")
#'
#' # The EXPANDED values are readable back off the context.
#' yandex <- robots_context_preset("yandex")
#' yandex$product_token
#' yandex$matcher_backend
robots_context_preset <- function(preset = robots_context_presets()) {
  preset <- match.arg(preset, robots_context_presets())
  spec <- robots_preset_table()[[preset]]
  ctx <- robots_context(
    product_token = spec[[1L]],
    policy_ruleset = spec[[2L]],
    matcher_backend = spec[[3L]]
  )
  ctx$preset <- preset
  ctx
}
