# Tests for the consultable robots facts/decisions producer (R/robots-facts.R;
# E.1b, SITE-kwkggijf; design §7, §5.4, §0.3).
#
# The point of E.1b is that ONE evaluation feeds both the ROBOTS_* findings and
# the §5.4 synthesis. So the tests pin three things: the axes are carried
# explicitly, the consult trichotomy agrees with the derived row view (including
# the case where the v1 fields alone cannot tell them apart), and the refactor
# left E.5's findings byte-identical. Since SITE-fsawklnl that row view is
# sitemapr's own derivation rather than the sibling's Google-bounded legacy
# shim, so two further pins matter: the view must still agree with the shim
# under a Google context, and a non-Google context must produce findings rather
# than abort. Everything runs offline against httr2-mocked robots.txt
# transports.

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

test_that("robots_context defaults to the Google axes", {
  ctx <- robots_context()
  expect_identical(ctx$product_token, "*")
  expect_identical(ctx$policy_ruleset, "google")
  expect_identical(ctx$matcher_backend, "google")
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

  # A non-Google preset carries its axes as-is rather than being quietly
  # collapsed onto Google.
  y <- robots_context_preset("yandex")
  expect_identical(y$product_token, "Yandex")
  expect_identical(y$policy_ruleset, "yandex")
  expect_identical(y$matcher_backend, "yandex")
})

test_that("every preset's product token is honoured by its own backend", {
  skip_if_not_installed("robotstxtr")
  # A preset whose token its own backend refuses is silently useless: every row
  # comes back `unsupported_product_token`, so the whole sitemap reads as
  # indeterminate. That is exactly what the `yandex` preset did until
  # SITE-fsawklnl — its token was "YandexBot", but the bounded Yandex profile
  # accepts only "Yandex" — and nothing caught it, because no findings were
  # ever derived under a non-Google context.
  #
  # Backends the installed build cannot run are skipped rather than failed:
  # `capability_unavailable` is a fact about the sibling, not a broken preset.
  availability <- robotstxtr_engine_contract()$matcher_availability
  checked <- 0L
  for (name in robots_context_presets()) {
    ctx <- robots_context_preset(name)
    if (!identical(availability[[ctx$matcher_backend]], "available")) {
      next
    }
    facts <- rf_with(robots_evaluate_facts(
      "https://disallow.example/private/x",
      context = ctx
    ))
    expect_identical(
      facts$decisions$results$matcher_status,
      "evaluated",
      info = name
    )
    checked <- checked + 1L
  }
  # Guard against the loop vacuously passing if availability ever reads empty.
  expect_gt(checked, 0L)
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

test_that("the trichotomy agrees with the view's allowed column", {
  skip_if_not_installed("robotstxtr")
  # The anti-drift pin: the v1 fields alone cannot separate the 403 and 404
  # cases (both report not_needed / allow / policy_allow_all), so the
  # trichotomy mirrors the shim's status rule. This asserts they agree.
  facts <- rf_with(robots_evaluate_facts(rf_locs()))
  view <- facts$view
  # Lookup rather than nested ifelse: FALSE -> 1, TRUE -> 2, NA stays NA.
  expected <- c("disallow", "allow")[view$allowed + 1L]
  expected[is.na(view$allowed)] <- "undetermined"
  expect_identical(robots_decision_for(facts, view$url), expected)
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

# The columns the ROBOTS_* producers read off the facts' row view. The rest of
# the legacy schema has no reader in sitemapr and is deliberately not built.
rf_view_cols <- function() {
  c(
    "url",
    "allowed",
    "fetch_outcome",
    "matched_rule_type",
    "matched_rule_value",
    "matched_line"
  )
}

test_that("the facts row view matches the legacy facade row-for-row", {
  skip_if_not_installed("robotstxtr")
  locs <- rf_locs()
  # NEW path: v1 evaluation, then sitemapr's own context-agnostic derivation.
  new <- rf_with(robots_evaluate_facts(locs))$view
  # OLD path: the legacy facade E.5 called before E.1b.
  old <- rf_with(
    robotstxtr::allowed_by_robots_url(locs, user_agent = "*", ssrf_guard = TRUE)
  )$results

  for (col in rf_view_cols()) {
    expect_identical(new[[col]], old[[col]], info = col)
  }
})

test_that("the facts row view matches the sibling's legacy shim", {
  skip_if_not_installed("robotstxtr")
  # The anti-drift pin SITE-fsawklnl rests on. `robots_findings_view()`
  # reproduces `as_legacy_robots_decisions_v1()`'s arithmetic so that a
  # non-Google context can derive findings the Google-bounded shim refuses to
  # produce. Under a Google context the two must therefore agree exactly, or
  # sitemapr's copy has drifted away from the semantics it borrowed.
  facts <- rf_with(robots_evaluate_facts(rf_locs()))
  shim <- robotstxtr::as_legacy_robots_decisions_v1(facts$decisions)$results

  for (col in rf_view_cols()) {
    expect_identical(facts$view[[col]], shim[[col]], info = col)
  }
})

test_that("findings derived from facts equal the pre-refactor findings", {
  skip_if_not_installed("robotstxtr")
  locs <- rf_locs()
  base <- "https://s.example/sitemap.xml"

  new <- rf_with(validate_robots(locs, context = robots_context(), base = base))

  # Reconstruct the pre-E.1b derivation directly off the legacy facade.
  old_decisions <- rf_with(
    robotstxtr::allowed_by_robots_url(locs, user_agent = "*", ssrf_guard = TRUE)
  )
  res <- old_decisions$results
  # The per-row builders are inlined here on purpose. SITE-wlmodqza replaced
  # them with one vectorized pass (~245x faster on a high-cardinality result);
  # keeping the pre-refactor form in the test is what proves the vectorized
  # build is byte-identical, row order and all, rather than merely equivalent.
  old_disallowed <- function(row) {
    robots_findings(
      code = "ROBOTS_DISALLOWED",
      severity = "warning",
      subject_ref = page_url_subject_ref(base, row$url),
      message = sprintf(
        "Sitemap-listed URL %s is disallowed by robots.txt (matched %s '%s').",
        row$url,
        row$matched_rule_type,
        row$matched_rule_value
      ),
      evidence = list(finding_evidence(
        excerpt = sprintf(
          "%s: %s",
          row$matched_rule_type,
          row$matched_rule_value
        ),
        line = row$matched_line
      )),
      is_strict_only = FALSE
    )
  }
  old_indeterminate <- function(row) {
    robots_findings(
      code = "ROBOTS_INDETERMINATE",
      severity = "info",
      subject_ref = page_url_subject_ref(base, row$url),
      message = sprintf(
        paste0(
          "robots.txt for %s could not be evaluated (fetch outcome: %s); ",
          "allow/disallow is undetermined."
        ),
        row$url,
        row$fetch_outcome
      ),
      evidence = list(finding_evidence(excerpt = row$fetch_outcome)),
      is_strict_only = FALSE
    )
  }
  parts <- list()
  for (i in seq_len(nrow(res))) {
    row <- res[i, , drop = FALSE]
    if (isFALSE(row$allowed)) {
      parts[[length(parts) + 1L]] <- old_disallowed(row)
    } else if (is.na(row$allowed)) {
      parts[[length(parts) + 1L]] <- old_indeterminate(row)
    }
  }
  old <- do.call(rbind, parts)

  expect_identical(new, old)
  # Sanity: this fixture really does exercise both codes.
  expect_setequal(new$code, c("ROBOTS_DISALLOWED", "ROBOTS_INDETERMINATE"))
})

# ---- findings under a non-Google context (SITE-fsawklnl) ---------------------

test_that("a non-Google context derives findings rather than refusing", {
  skip_if_not_installed("robotstxtr")
  # The boundary SITE-fsawklnl removed. Evaluation always honoured every
  # engine; only the FINDINGS derivation was bounded to the sibling's
  # Google-only legacy shim, so a Yandex context used to abort here.
  facts <- rf_with(robots_evaluate_facts(
    rf_locs(),
    context = robots_context_preset("yandex")
  ))
  f <- robots_findings_from_facts(facts, base = "https://s.xml")

  expect_identical(facts$context$policy_ruleset, "yandex")
  expect_identical(facts$context$matcher_backend, "yandex")
  expect_setequal(f$code, c("ROBOTS_DISALLOWED", "ROBOTS_INDETERMINATE"))
  expect_true(all(f$layer == "robots"))
  # The disallow really is the Yandex matcher's verdict on the rule, not a
  # Google verdict relabelled: the matched rule rides the evidence.
  dis <- f[f$code == "ROBOTS_DISALLOWED", ]
  expect_identical(nrow(dis), 1L)
  expect_match(dis$evidence[[1L]]$excerpt, "disallow: /private")
})

test_that("a backend with no matcher capability yields indeterminate rows", {
  skip_if_not_installed("robotstxtr")
  # `rfc9309` is published as a policy/backend but reports
  # `capability_unavailable` in this build, so no row is ever `evaluated`.
  # That must surface as ROBOTS_INDETERMINATE — the honest "cannot decide" —
  # never as a silently empty findings tibble or a manufactured allow.
  skip_if(
    robotstxtr_engine_contract()$matcher_availability[["rfc9309"]] ==
      "available"
  )
  facts <- rf_with(robots_evaluate_facts(
    rf_locs(),
    context = robots_context_preset("rfc9309")
  ))
  f <- robots_findings_from_facts(facts, base = "https://s.xml")

  # Every loc except the 404 origin (an allow-all by policy, not by matcher).
  expect_identical(unique(f$code), "ROBOTS_INDETERMINATE")
  expect_identical(nrow(f), length(rf_locs()) - 1L)
})

test_that("a merged facts object is refused as a findings source", {
  skip_if_not_installed("robotstxtr")
  # A merged object drops its row view on purpose: it exists to be CONSULTED,
  # and each finding must anchor to its own advertising sitemap base. Deriving
  # from one would silently emit zero rows, so it aborts.
  merged <- robots_facts_merge(list(
    rf_with(robots_evaluate_facts("https://disallow.example/private/x"))
  ))
  expect_error(
    robots_findings_from_facts(merged, base = "https://s.xml"),
    class = "sitemapr_robots_findings_unsupported"
  )
  # The document-level producer refuses it on the same grounds.
  expect_error(
    robots_sitemap_findings_from_facts(merged, base = "https://s.xml"),
    class = "sitemapr_robots_findings_unsupported"
  )
  # The decision itself stays consultable — that is the whole point of E.1b.
  expect_true(robots_facts_consultable(merged))
  expect_identical(
    robots_decision_for(merged, "https://disallow.example/private/x"),
    "disallow"
  )
})

# ---- one evaluation, both consumers ------------------------------------------

test_that("one evaluation serves findings AND the synthesis consult", {
  skip_if_not_installed("robotstxtr")
  facts <- rf_with(robots_evaluate_facts(rf_locs()))
  findings <- robots_findings_from_facts(facts, base = "https://s.xml")

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

test_that("a zero-row result set yields no decisions", {
  empty <- robots_decision_trichotomy(
    tibble::tibble(source_id = character(0), matcher_status = character(0)),
    tibble::tibble(source_id = character(0), final_http_status = integer(0))
  )
  expect_identical(empty, character(0))
})
