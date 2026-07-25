# Offline tests for the robots.txt Disallow x noindex trap synthesis
# (R/page-robots-trap.R; E.3b, SITE-zbpfswsz; design §5.4, sitemap-spec §13.5).
#
# The synthesis is a DECORATOR over the E.3 noindex findings, so the tests are
# layered the same way: the two gates (documented mechanic, own-matcher
# attribution) first, then the message discipline, then the decorator, then
# end-to-end through validate_sitemap_ruleset() with both robots.txt and the
# page fetch mocked.

# A facts object built directly, so the gate/decorator tests need no evaluation.
prt_facts <- function(
  urls = "https://example.com/a",
  decision = "disallow",
  context = robots_context()
) {
  structure(
    list(
      context = context,
      urls = urls,
      decision = decision,
      decisions = NULL,
      legacy = NULL
    ),
    class = "sitemapr_robots_facts"
  )
}

# The E.3 noindex findings for one page carrying an X-Robots-Tag noindex.
prt_findings <- function(loc = "https://example.com/a", engine = "google") {
  art <- page_fetch_artifact(
    requested_url = loc,
    final_url = loc,
    hops = list(list(url = loc, status = 200L, location = NA_character_)),
    terminal_headers = list(
      "Content-Type" = "text/html; charset=UTF-8",
      "X-Robots-Tag" = "noindex"
    ),
    body = charToRaw("<html><head></head></html>"),
    outcome = "usable_body",
    request_user_agent = "inspector/test"
  )
  entry <- list(fetch_url = loc, advertised = loc, artifact = art)
  run <- structure(
    list(artifacts = stats::setNames(list(entry), loc), coverage = list()),
    class = "page_inspection_run"
  )
  page_noindex_findings(run, ruleset = list(ruleset = engine))
}

# ---- gate 1: the mechanic must be documented for the engine ----------------

test_that("the trap mechanic is documented for google and bing only", {
  expect_identical(page_trap_mechanic_provenance("google"), "documented")
  expect_identical(page_trap_mechanic_provenance("bing"), "documented")
  expect_identical(page_trap_mechanic_provenance(NULL), NA_character_)
})

test_that("yandex stays a documentation_gap and never stamps", {
  # §13.5: the Yandex URL-only-indexing case has no primary source, so it must
  # not be inferred from the Google/Bing mechanics.
  skip_if_not_installed("robotstxtr")
  expect_identical(
    page_trap_mechanic_provenance("yandex"),
    "documentation_gap"
  )
  facts <- prt_facts(context = robots_context_preset("yandex"))
  expect_false(page_trap_stampable("yandex", facts))
})

# ---- gate 2: own-matcher attribution -----------------------------------------

test_that("google stamps when its own matcher produced the decision", {
  skip_if_not_installed("robotstxtr")
  expect_true(page_trap_stampable("google", prt_facts()))
})

test_that("a decision from another engine's matcher is never laundered", {
  skip_if_not_installed("robotstxtr")
  # The Google matcher evaluated the access decision; claiming it as Bing's
  # would be a Google verdict wearing a Bing label (§13.1 anti-laundering).
  expect_false(page_trap_stampable("bing", prt_facts()))
})

test_that("an unavailable matcher declines even for a documented engine", {
  skip_if_not_installed("robotstxtr")
  contract <- robotstxtr_engine_contract()
  contract$matcher_availability[["google"]] <- "capability_unavailable"
  local_mocked_bindings(robotstxtr_engine_contract = function() contract)
  expect_false(page_trap_stampable("google", prt_facts()))
})

test_that("a matcher whose semantics are not its own engine declines", {
  skip_if_not_installed("robotstxtr")
  contract <- robotstxtr_engine_contract()
  contract$matcher_capability[["google"]]$matcher_semantics <- "rfc9309"
  local_mocked_bindings(robotstxtr_engine_contract = function() contract)
  expect_false(page_trap_stampable("google", prt_facts()))
})

test_that("no engine and non-consultable facts both decline", {
  skip_if_not_installed("robotstxtr")
  expect_false(page_trap_stampable(NULL, prt_facts()))
  expect_false(page_trap_stampable("google", NULL))
  expect_false(page_trap_stampable(
    "google",
    robots_facts_empty(
      robots_context()
    )
  ))
})

test_that("the synthesis declines when robotstxtr is unavailable", {
  skip_if_not_installed("robotstxtr")
  facts <- prt_facts()
  local_mocked_bindings(robotstxtr_available = function() FALSE)
  expect_false(page_trap_stampable("google", facts))
})

# ---- message discipline (§5.4) -----------------------------------------------

test_that("the hint states both intents and never says remove the block", {
  msg <- page_trap_message("google", "PAGE_XROBOTSTAG_NOINDEX", "*")
  expect_match(msg, "If the intent is to keep the page out of the index")
  expect_match(msg, "if the intent is only to block crawling")
  expect_false(grepl("remove the block", msg, fixed = TRUE))
})

test_that("the hint names the engine, its admin panel, and the group", {
  msg <- page_trap_message("google", "PAGE_META_ROBOTS_NOINDEX", "Googlebot")
  expect_match(msg, "Per Google documentation", fixed = TRUE)
  expect_match(msg, "Google Search Console", fixed = TRUE)
  # The evaluated robots GROUP is named: a `*` decision is not a claim about a
  # crawler that may carry a group of its own.
  expect_match(msg, "the 'Googlebot' group", fixed = TRUE)
  expect_match(msg, "<meta name=robots> noindex", fixed = TRUE)
})

test_that("the channel phrase follows the code", {
  bing <- page_trap_message("bing", "PAGE_XROBOTSTAG_NOINDEX", "*")
  expect_match(bing, "an X-Robots-Tag noindex", fixed = TRUE)
  expect_match(bing, "Bing Webmaster Tools", fixed = TRUE)
})

# ---- the decorator -----------------------------------------------------------

test_that("a disallowed noindex URL gains the trap hint and context", {
  skip_if_not_installed("robotstxtr")
  out <- page_noindex_attach_trap(prt_findings(), prt_facts(), "google")
  expect_identical(nrow(out), 1L)
  expect_match(out$remediation_hint[[1L]], "never sees the noindex")
  ctx <- out$context[[1L]]
  expect_true(ctx$page_noindex_trap)
  expect_identical(ctx$page_noindex_trap_engine, "google")
  expect_identical(ctx$page_noindex_trap_provenance, "documented")
})

test_that("an allowed or undetermined URL gains no hint column at all", {
  skip_if_not_installed("robotstxtr")
  for (decision in c("allow", "undetermined")) {
    out <- page_noindex_attach_trap(
      prt_findings(),
      prt_facts(decision = decision),
      "google"
    )
    expect_null(out[["remediation_hint"]])
    expect_null(out$context[[1L]]$page_noindex_trap)
  }
})

test_that("a URL the robots facts never saw gains no hint", {
  skip_if_not_installed("robotstxtr")
  out <- page_noindex_attach_trap(
    prt_findings(loc = "https://example.com/a"),
    prt_facts(urls = "https://example.com/other"),
    "google"
  )
  expect_null(out[["remediation_hint"]])
})

test_that("the decorator adds and removes no rows", {
  skip_if_not_installed("robotstxtr")
  before <- prt_findings()
  after <- page_noindex_attach_trap(before, prt_facts(), "google")
  expect_identical(after$code, before$code)
  expect_identical(after$severity, before$severity)
  expect_identical(after$message, before$message)
  expect_identical(after$provenance, before$provenance)
})

test_that("a zero-row noindex tibble passes through untouched", {
  skip_if_not_installed("robotstxtr")
  empty <- empty_page_findings()
  expect_identical(
    page_noindex_attach_trap(empty, prt_facts(), "google"),
    empty
  )
})

# ---- the facts merge (the call-wide sink) ------------------------------------

test_that("per-source facts merge into one consultable object", {
  skip_if_not_installed("robotstxtr")
  merged <- robots_facts_merge(list(
    prt_facts("https://example.com/a", "disallow"),
    prt_facts("https://example.com/b", "allow")
  ))
  expect_true(robots_facts_consultable(merged))
  expect_identical(
    robots_decision_for(merged, c("https://example.com/b", "x")),
    c("allow", "undetermined")
  )
})

test_that("a URL two sitemaps both advertise is merged once", {
  skip_if_not_installed("robotstxtr")
  merged <- robots_facts_merge(list(
    prt_facts("https://example.com/a", "disallow"),
    prt_facts("https://example.com/a", "disallow")
  ))
  expect_identical(merged$urls, "https://example.com/a")
})

test_that("merging nothing yields NULL, which is non-consultable", {
  expect_null(robots_facts_merge(list()))
  expect_null(robots_facts_merge(list(NULL)))
  expect_false(robots_facts_consultable(robots_facts_merge(list())))
})

# ---- end-to-end through the entry points -------------------------------------

# One mock serving both halves of the trap: robots.txt blocks /private, and the
# page itself answers with an X-Robots-Tag noindex. sitemapr fetches the body
# the engine cannot -- that is what makes the trap detectable.
prt_mock <- function(req) {
  parsed <- httr2::url_parse(req$url)
  if (identical(parsed$path, "/robots.txt")) {
    return(httr2::response(
      status_code = 200L,
      url = req$url,
      body = charToRaw("User-agent: *\nDisallow: /private\n")
    ))
  }
  httr2::response(
    status_code = 200L,
    url = req$url,
    headers = list(
      "Content-Type" = "text/html; charset=UTF-8",
      "X-Robots-Tag" = "noindex"
    ),
    body = charToRaw("<html><head></head></html>")
  )
}

prt_urlset <- function(locs) {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    paste0("<url><loc>", locs, "</loc></url>", collapse = ""),
    "</urlset>"
  )
  path <- withr::local_tempfile(fileext = ".xml", .local_envir = parent.frame())
  writeLines(xml, path)
  path
}

test_that("the trap hint reaches the assembled findings under google", {
  skip_if_not_installed("robotstxtr")
  path <- prt_urlset("https://blocked.example/private/x")
  out <- httr2::with_mocked_responses(
    prt_mock,
    validate_sitemap_ruleset(
      path,
      "google",
      mode = "non-strict",
      check_robots = TRUE,
      inspect_pages = TRUE
    )
  )
  row <- out[out$code == "PAGE_XROBOTSTAG_NOINDEX", , drop = FALSE]
  expect_identical(nrow(row), 1L)
  expect_match(row$remediation_hint[[1L]], "never sees the noindex")
  expect_true(row$context[[1L]]$page_noindex_trap)
  # D2: both component findings still fire independently.
  expect_identical(sum(out$code == "ROBOTS_DISALLOWED"), 1L)
})

test_that("an allowed noindex URL carries no hint end-to-end", {
  skip_if_not_installed("robotstxtr")
  path <- prt_urlset("https://blocked.example/public/x")
  out <- httr2::with_mocked_responses(
    prt_mock,
    validate_sitemap_ruleset(
      path,
      "google",
      mode = "non-strict",
      check_robots = TRUE,
      inspect_pages = TRUE
    )
  )
  row <- out[out$code == "PAGE_XROBOTSTAG_NOINDEX", , drop = FALSE]
  expect_identical(nrow(row), 1L)
  expect_true(is.na(row$remediation_hint[[1L]]))
  expect_identical(sum(out$code == "ROBOTS_DISALLOWED"), 0L)
})

test_that("no robots check means no synthesis, and the noindex row stands", {
  skip_if_not_installed("robotstxtr")
  path <- prt_urlset("https://blocked.example/private/x")
  out <- httr2::with_mocked_responses(
    prt_mock,
    validate_sitemap_ruleset(path, "google", inspect_pages = TRUE)
  )
  row <- out[out$code == "PAGE_XROBOTSTAG_NOINDEX", , drop = FALSE]
  expect_identical(nrow(row), 1L)
  expect_true(is.na(row$remediation_hint[[1L]]))
})

test_that("inspect_pages = FALSE stays byte-identical with the sink live", {
  skip_if_not_installed("robotstxtr")
  path <- prt_urlset("https://blocked.example/private/x")
  off <- httr2::with_mocked_responses(
    prt_mock,
    validate_sitemap(path, mode = "non-strict", check_robots = TRUE)
  )
  explicit <- httr2::with_mocked_responses(
    prt_mock,
    validate_sitemap(
      path,
      mode = "non-strict",
      check_robots = TRUE,
      inspect_pages = FALSE
    )
  )
  expect_identical(off, explicit)
  expect_identical(ncol(off), 10L)
  expect_false("page" %in% off$layer)
  # The robots findings are unaffected by the E.1b/E.3b evaluation split.
  expect_identical(sum(off$code == "ROBOTS_DISALLOWED"), 1L)
})
