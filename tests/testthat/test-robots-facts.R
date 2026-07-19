# Tests for the consultable robots facts/decisions producer (R/robots-facts.R;
# E.1b, SITE-kwkggijf; design §7, §5.4, §0.3).
#
# The point of E.1b is that ONE evaluation feeds both the ROBOTS_* findings and
# the §5.4 synthesis. So the tests pin three things: the axes are carried
# explicitly, the consult trichotomy agrees with the Google-bounded legacy view
# (including the case where the v1 fields alone cannot tell them apart), and
# the refactor left E.5's findings byte-identical. Everything runs offline
# against httr2-mocked robots.txt transports.

# A robots.txt transport covering the four outcomes plus the 403 case that the
# v1 fields alone cannot distinguish from a 404.
rf_mock <- function(req) {
  host <- httr2::url_parse(req$url)$hostname
  if (identical(host, "disallow.example")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      body = charToRaw("User-agent: *\nDisallow: /private\n")
    ))
  }
  if (identical(host, "allow.example")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      body = charToRaw("User-agent: *\nDisallow: /other\n")
    ))
  }
  if (identical(host, "missing.example")) {
    return(httr2::response(status_code = 404L, url = req$url, body = raw(0)))
  }
  if (identical(host, "forbidden.example")) {
    return(httr2::response(status_code = 403L, url = req$url, body = raw(0)))
  }
  httr2::response(status_code = 503L, url = req$url, body = raw(0))
}

rf_with <- function(code) httr2::with_mocked_responses(rf_mock, code)

rf_locs <- function() {
  c(
    "https://disallow.example/private/x",
    "https://allow.example/ok",
    "https://missing.example/a",
    "https://forbidden.example/f",
    "https://boom.example/y"
  )
}

# ---- the explicit axis carrier -----------------------------------------------

test_that("robots_context defaults to the Google-bounded legacy axes", {
  ctx <- robots_context()
  expect_identical(ctx$product_token, "*")
  expect_identical(ctx$policy_ruleset, "google")
  expect_identical(ctx$matcher_backend, "google")
  expect_true(robots_context_is_legacy(ctx))
})

test_that("robots_context rejects a malformed axis", {
  expect_error(
    robots_context(product_token = ""),
    class = "sitemapr_invalid_robots_context"
  )
  expect_error(
    robots_context(product_token = c("a", "b")),
    class = "sitemapr_invalid_robots_context"
  )
  expect_error(
    robots_context(policy_ruleset = NA_character_),
    class = "sitemapr_invalid_robots_context"
  )
})

test_that("robots_context rejects an axis the sibling does not publish", {
  skip_if_not_installed("robotstxtr")
  expect_error(
    robots_context(policy_ruleset = "altavista"),
    class = "sitemapr_invalid_robots_context"
  )
  expect_error(
    robots_context(matcher_backend = "altavista"),
    class = "sitemapr_invalid_robots_context"
  )
})

test_that("presets retain their EXPANDED axis values", {
  skip_if_not_installed("robotstxtr")
  g <- robots_context_preset("google")
  expect_identical(g$product_token, "Googlebot")
  expect_identical(g$policy_ruleset, "google")
  expect_identical(g$matcher_backend, "google")
  expect_identical(g$preset, "google")
  expect_true(robots_context_is_legacy(g))

  # A non-Google preset is NOT legacy-bounded: its axes are carried as-is
  # rather than being quietly collapsed onto Google.
  y <- robots_context_preset("yandex")
  expect_identical(y$product_token, "YandexBot")
  expect_identical(y$policy_ruleset, "yandex")
  expect_identical(y$matcher_backend, "yandex")
  expect_false(robots_context_is_legacy(y))
})

test_that("the robots axes are independent of the sitemap ruleset", {
  skip_if_not_installed("robotstxtr")
  # ADR-009 independence: nothing derives a robots axis from sitemap_ruleset.
  # A Bing SITEMAP ruleset does not imply a Bing ROBOTS policy.
  expect_identical(robots_context()$policy_ruleset, "google")
  expect_identical(
    robots_context(policy_ruleset = "rfc9309")$matcher_backend,
    "google"
  )
})

# ---- the consult trichotomy --------------------------------------------------

test_that("the trichotomy classifies all outcomes, 403 separately from 404", {
  skip_if_not_installed("robotstxtr")
  facts <- rf_with(robots_evaluate_facts(rf_locs()))
  decision <- robots_decision_for(facts, rf_locs())
  expect_identical(
    decision,
    c(
      "disallow", # matched Disallow rule
      "allow", # matched, default allow
      "allow", # 404 robots.txt is a policy allow-all
      "undetermined", # 403 is NOT an allow-all, despite v1 saying "allow"
      "undetermined" # 503: unfetchable
    )
  )
})

test_that("the trichotomy agrees with the legacy allowed column", {
  skip_if_not_installed("robotstxtr")
  # The anti-drift pin: the v1 fields alone cannot separate the 403 and 404
  # cases (both report not_needed / allow / policy_allow_all), so the
  # trichotomy mirrors the shim's status rule. This asserts they agree.
  facts <- rf_with(robots_evaluate_facts(rf_locs()))
  legacy <- facts$legacy$results
  # Lookup rather than nested ifelse: FALSE -> 1, TRUE -> 2, NA stays NA.
  expected <- c("disallow", "allow")[legacy$allowed + 1L]
  expected[is.na(legacy$allowed)] <- "undetermined"
  expect_identical(robots_decision_for(facts, legacy$url), expected)
})

test_that("consulting an unevaluated URL yields undetermined", {
  skip_if_not_installed("robotstxtr")
  facts <- rf_with(robots_evaluate_facts("https://allow.example/ok"))
  expect_identical(
    robots_decision_for(facts, "https://never.example/seen"),
    "undetermined"
  )
  # Vectorized, order-preserving, mixing known and unknown URLs.
  expect_identical(
    robots_decision_for(
      facts,
      c("https://never.example/x", "https://allow.example/ok")
    ),
    c("undetermined", "allow")
  )
})

# ---- the §7 consultability gate ----------------------------------------------

test_that("facts are not consultable when nothing testable was advertised", {
  facts <- robots_evaluate_facts(c("/relative", "ftp://h/x", NA_character_))
  expect_false(robots_facts_consultable(facts))
  expect_identical(
    robots_decision_for(facts, "https://a.example/x"),
    "undetermined"
  )
})

test_that("a NULL facts object (evaluation disabled) is not consultable", {
  # The synthesis gate: check_robots = FALSE means no facts at all.
  expect_false(robots_facts_consultable(NULL))
  expect_identical(
    robots_decision_for(NULL, "https://a.example/x"),
    "undetermined"
  )
})

# ---- byte-identity of E.5's findings across the refactor ---------------------

test_that("the facts legacy view matches the legacy facade row-for-row", {
  skip_if_not_installed("robotstxtr")
  locs <- rf_locs()
  # NEW path: v1 evaluation, then the exported Google-bounded shim.
  new <- rf_with(robots_evaluate_facts(locs))$legacy$results
  # OLD path: the legacy facade E.5 called before E.1b.
  old <- rf_with(
    robotstxtr::allowed_by_robots_url(locs, user_agent = "*", ssrf_guard = TRUE)
  )$results

  # The columns E.5's findings actually read.
  for (col in c(
    "url",
    "allowed",
    "decision_source",
    "fetch_outcome",
    "matched_rule_type",
    "matched_rule_value",
    "matched_line"
  )) {
    expect_identical(new[[col]], old[[col]], info = col)
  }
})

test_that("findings derived from facts equal the pre-refactor findings", {
  skip_if_not_installed("robotstxtr")
  locs <- rf_locs()
  base <- "sitemap://s.example/sitemap.xml"

  new <- rf_with(validate_robots(locs, user_agent = "*", base = base))

  # Reconstruct the pre-E.1b derivation directly off the legacy facade.
  old_decisions <- rf_with(
    robotstxtr::allowed_by_robots_url(locs, user_agent = "*", ssrf_guard = TRUE)
  )
  res <- old_decisions$results
  parts <- list()
  for (i in seq_len(nrow(res))) {
    row <- res[i, , drop = FALSE]
    if (isFALSE(row$allowed)) {
      parts[[length(parts) + 1L]] <- robots_disallowed_finding(
        base,
        row$url,
        row
      )
    } else if (is.na(row$allowed)) {
      parts[[length(parts) + 1L]] <- robots_indeterminate_finding(
        base,
        row$url,
        row
      )
    }
  }
  old <- do.call(rbind, parts)

  expect_identical(new, old)
  # Sanity: this fixture really does exercise both codes.
  expect_setequal(new$code, c("ROBOTS_DISALLOWED", "ROBOTS_INDETERMINATE"))
})

# ---- the Google-bounded findings boundary ------------------------------------

test_that("findings under a non-Google context are refused, not silent", {
  skip_if_not_installed("robotstxtr")
  # A hand-built facts object standing in for a non-Google evaluation: the
  # shim refuses those, so `legacy` is NULL and there is nothing to derive
  # findings from. That must abort rather than quietly return zero rows.
  facts <- structure(
    list(
      context = robots_context_preset("yandex"),
      urls = "https://a.example/x",
      decision = "disallow",
      decisions = NULL,
      legacy = NULL
    ),
    class = "sitemapr_robots_facts"
  )
  expect_error(
    robots_findings_from_facts(facts, base = "sitemap://s.xml"),
    class = "sitemapr_robots_findings_unsupported"
  )
  # The decision itself stays consultable — that is the whole point of E.1b.
  expect_true(robots_facts_consultable(facts))
  expect_identical(
    robots_decision_for(facts, "https://a.example/x"),
    "disallow"
  )
})

# ---- one evaluation, both consumers ------------------------------------------

test_that("one evaluation serves findings AND the synthesis consult", {
  skip_if_not_installed("robotstxtr")
  facts <- rf_with(robots_evaluate_facts(rf_locs()))
  findings <- robots_findings_from_facts(facts, base = "sitemap://s.xml")

  # The disallowed URL produces a finding AND is consultable.
  expect_true(any(findings$code == "ROBOTS_DISALLOWED"))
  expect_identical(
    robots_decision_for(facts, "https://disallow.example/private/x"),
    "disallow"
  )
  # The ALLOWED URL produces NO finding but is still consultable — exactly the
  # gap that made the pre-E.1b findings-only shape unusable for §5.4.
  expect_false(any(grepl(
    "https://allow.example/ok",
    findings$subject_ref,
    fixed = TRUE
  )))
  expect_identical(
    robots_decision_for(facts, "https://allow.example/ok"),
    "allow"
  )
})
