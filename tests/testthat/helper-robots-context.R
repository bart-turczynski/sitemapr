# The engine presets of docs/sitemap-spec.md §13.0, as test scaffolding.
#
# These lived in R/robots-facts.R until SITE-bxzclfqv. Nothing in R/ ever
# called them: every production call site builds its context as
# `robots_context(product_token = user_agent)` with the Google defaults
# (R/robots-validate.R:343, :415), because the public surface carries a bare
# `robots_user_agent` string and no exported function accepts a context object.
# A preset constructor reachable only from tests is test scaffolding, so it
# lives with the tests. SITE-fsawklnl covers promoting it to real public
# surface, which needs an entry point that can accept a context.
#
# Construction still routes through the package's own `robots_context()`, which
# validates each axis against the value sets the INSTALLED robotstxtr
# publishes. Building the contexts by hand here instead would let this table
# drift past an axis the sibling no longer honours without any test noticing.

# The preset table. Each entry is product_token / policy_ruleset /
# matcher_backend, in that order.
robots_context_presets <- function() {
  list(
    google = list("Googlebot", "google", "google"),
    bing = list("Bingbot", "bing", "bing"),
    yandex = list("YandexBot", "yandex", "yandex"),
    rfc9309 = list("*", "rfc9309", "rfc9309")
  )
}

# The EXPANDED values are retained on the returned context (not re-derived at
# use time), so a caller can read back exactly which product token / policy /
# backend a preset selected.
robots_context_preset <- function(preset) {
  presets <- robots_context_presets()
  preset <- match.arg(preset, names(presets))
  spec <- presets[[preset]]
  ctx <- robots_context(
    product_token = spec[[1L]],
    policy_ruleset = spec[[2L]],
    matcher_backend = spec[[3L]]
  )
  ctx$preset <- preset
  ctx
}
