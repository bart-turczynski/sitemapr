# Offline tests for the effective-noindex extractor + fold + finding producer
# (R/page-noindex.R; Layer E, Contract B/C, E.3; sitemap-spec §13.2).
#
# The three stages are tested separately — extraction, the crawler-applicability
# filter, and the per-engine fold — then together through the producer, then
# end-to-end through validate_sitemap()/validate_sitemap_ruleset(). Artifacts
# are constructed directly, so no network is involved.

pn_art <- function(
  body = "<html><head></head></html>",
  outcome = "usable_body",
  requested = "https://example.com/a",
  headers = list("Content-Type" = "text/html; charset=UTF-8")
) {
  page_fetch_artifact(
    requested_url = requested,
    final_url = requested,
    hops = list(list(url = requested, status = 200L, location = NA_character_)),
    terminal_headers = headers,
    body = charToRaw(body),
    outcome = outcome,
    request_user_agent = "inspector/test"
  )
}

pn_run <- function(art, advertised = art$requested_url) {
  key <- art$requested_url
  entry <- list(fetch_url = key, advertised = advertised, artifact = art)
  entries <- stats::setNames(list(entry), key)
  structure(
    list(artifacts = entries, coverage = list()),
    class = "page_inspection_run"
  )
}

pn_meta <- function(content, name = "robots") {
  sprintf(
    "<html><head><meta name=\"%s\" content=\"%s\"></head></html>",
    name,
    content
  )
}

pn_headers <- function(...) {
  c(list("Content-Type" = "text/html; charset=UTF-8"), list(...))
}

# A header list carrying REPEATED X-Robots-Tag fields, which a named list
# literal cannot express without a duplicate argument.
pn_repeated_xrobots <- function(...) {
  values <- list(...)
  c(
    list("Content-Type" = "text/html; charset=UTF-8"),
    stats::setNames(values, rep("X-Robots-Tag", length(values)))
  )
}

# ---- stage 1: extraction -----------------------------------------------------

test_that("a meta robots noindex is extracted as an unscoped meta fact", {
  ex <- page_noindex_extract(pn_art(pn_meta("noindex")))
  expect_identical(ex$status, "observed")
  expect_length(ex$facts, 1L)
  expect_identical(ex$facts[[1L]]$channel, "meta")
  expect_identical(ex$facts[[1L]]$scope, "*")
  expect_identical(ex$facts[[1L]]$tokens, "noindex")
})

test_that("comma-separated and mixed-case directives normalize to tokens", {
  ex <- page_noindex_extract(pn_art(pn_meta("NoIndex, NoFollow")))
  expect_identical(ex$facts[[1L]]$tokens, c("noindex", "nofollow"))
})

test_that("a crawler-scoped meta name is captured with its scope", {
  ex <- page_noindex_extract(pn_art(pn_meta("noindex", name = "googlebot")))
  expect_identical(ex$facts[[1L]]$scope, "googlebot")
})

test_that("X-Robots-Tag is extracted, bare and crawler-prefixed", {
  ex <- page_noindex_extract(pn_art(
    headers = pn_headers("X-Robots-Tag" = "noindex")
  ))
  expect_identical(ex$facts[[1L]]$channel, "header")
  expect_identical(ex$facts[[1L]]$scope, "*")

  ex2 <- page_noindex_extract(pn_art(
    headers = pn_headers("X-Robots-Tag" = "googlebot: noindex")
  ))
  expect_identical(ex2$facts[[1L]]$scope, "googlebot")
  expect_identical(ex2$facts[[1L]]$tokens, "noindex")
})

test_that("repeated X-Robots-Tag headers each yield a fact", {
  ex <- page_noindex_extract(pn_art(
    # Repeated field names, built positionally: a literal duplicate
    # argument is what the HTTP response actually carries.
    headers = pn_repeated_xrobots("noindex", "bingbot: nofollow")
  ))
  expect_length(ex$facts, 2L)
  expect_setequal(
    vapply(ex$facts, function(f) f$scope, character(1L)),
    c("*", "bingbot")
  )
})

test_that("an unknown colon prefix is NOT read as a crawler scope", {
  # "unavailable_after: ..." must not be mistaken for a crawler-scoped
  # directive; the prefix only scopes when it names a crawler we know.
  ex <- page_noindex_extract(pn_art(
    headers = pn_headers("X-Robots-Tag" = "unavailable_after: 2030-01-01")
  ))
  expect_identical(ex$facts[[1L]]$scope, "*")
})

test_that("no directives yields absent; a bodyless outcome not_applicable", {
  expect_identical(page_noindex_extract(pn_art())$status, "absent")
  expect_identical(
    page_noindex_extract(pn_art(outcome = "transport_fail"))$status,
    "not_applicable"
  )
})

test_that("a malformed body degrades to no facts rather than erroring", {
  ex <- page_noindex_extract(pn_art("<html><head><meta name=robots"))
  expect_true(ex$status %in% c("absent", "observed"))
})

# ---- stage 2: the crawler-applicability filter -------------------------------

test_that("unscoped directives always apply; scoped only to their engine", {
  facts <- page_noindex_extract(pn_art(paste0(
    "<html><head>",
    "<meta name=\"robots\" content=\"nofollow\">",
    "<meta name=\"googlebot\" content=\"noindex\">",
    "</head></html>"
  )))$facts
  expect_length(page_noindex_applicable(facts, "google"), 2L)
  # Under Bing the googlebot-scoped directive drops out.
  bing <- page_noindex_applicable(facts, "bing")
  expect_length(bing, 1L)
  expect_identical(bing[[1L]]$scope, "*")
})

test_that("with no engine, only unscoped directives apply", {
  facts <- page_noindex_extract(
    pn_art(pn_meta("noindex", name = "googlebot"))
  )$facts
  # A googlebot-scoped directive is not a fact about "the generic crawler".
  expect_length(page_noindex_applicable(facts, NULL), 0L)
})

# ---- stage 3: the engine fold ------------------------------------------------

test_that("none is a noindex token (shorthand for noindex,nofollow)", {
  facts <- page_noindex_extract(pn_art(pn_meta("none")))$facts
  fold <- page_noindex_fold(facts, "google")
  expect_true(fold$meta_noindex)
  expect_true(fold$effective_noindex)
})

test_that("Google and Bing fold most-restrictive: noindex wins a conflict", {
  facts <- page_noindex_extract(pn_art(
    pn_meta("noindex"),
    headers = pn_headers("X-Robots-Tag" = "index")
  ))$facts
  for (engine in c("google", "bing")) {
    fold <- page_noindex_fold(facts, engine)
    expect_true(fold$effective_noindex, info = engine)
    expect_identical(fold$path, "conflict")
  }
})

test_that("Yandex folds allow-wins: an explicit index overrides noindex", {
  facts <- page_noindex_extract(pn_art(
    pn_meta("noindex"),
    headers = pn_headers("X-Robots-Tag" = "index")
  ))$facts
  fold <- page_noindex_fold(facts, "yandex")
  # The divergence direction that makes a naive fold wrong.
  expect_false(fold$effective_noindex)
  expect_true(fold$explicit_index)
})

test_that("with no opposing directive all three engines agree", {
  facts <- page_noindex_extract(pn_art(pn_meta("noindex")))$facts
  for (engine in c("google", "bing", "yandex")) {
    expect_true(
      page_noindex_fold(facts, engine)$effective_noindex,
      info = engine
    )
  }
})

test_that("the baseline computes no effective verdict", {
  facts <- page_noindex_extract(pn_art(pn_meta("noindex")))$facts
  fold <- page_noindex_fold(facts, NULL)
  expect_true(is.na(fold$effective_noindex))
  # The channel fact is still reported.
  expect_true(fold$meta_noindex)
})

test_that("the fold path distinguishes single- from cross-channel", {
  single <- page_noindex_fold(
    page_noindex_extract(pn_art(pn_meta("noindex")))$facts,
    "google"
  )
  expect_identical(single$path, "single_channel")

  cross <- page_noindex_fold(
    page_noindex_extract(pn_art(
      pn_meta("noindex"),
      headers = pn_headers("X-Robots-Tag" = "noindex")
    ))$facts,
    "google"
  )
  expect_identical(cross$path, "cross_channel")
})

# ---- producer provenance -----------------------------------------------------

test_that("single-channel is documented, cross-channel inferred", {
  single <- page_noindex_fold(
    page_noindex_extract(pn_art(pn_meta("noindex")))$facts,
    "google"
  )
  cross <- page_noindex_fold(
    page_noindex_extract(pn_art(
      pn_meta("noindex"),
      headers = pn_headers("X-Robots-Tag" = "noindex")
    ))$facts,
    "google"
  )
  expect_identical(page_noindex_provenance(single, "google"), "documented")
  # Applying the fold ACROSS channels has no worked example -> diagnostic only.
  expect_identical(page_noindex_provenance(cross, "google"), "inferred")
  # No engine -> no producer provenance; the assembler default stands.
  expect_true(is.na(page_noindex_provenance(single, NULL)))
})

# ---- the producer ------------------------------------------------------------

test_that("a meta noindex emits PAGE_META_ROBOTS_NOINDEX only", {
  f <- page_noindex_findings(pn_run(pn_art(pn_meta("noindex"))))
  expect_identical(nrow(f), 1L)
  expect_identical(f$code, "PAGE_META_ROBOTS_NOINDEX")
  expect_identical(f$layer, "page")
  expect_identical(f$severity, "warning")
})

test_that("both channels fire independently when both carry a noindex", {
  f <- page_noindex_findings(pn_run(pn_art(
    pn_meta("noindex"),
    headers = pn_headers("X-Robots-Tag" = "noindex")
  )))
  # D2: the channel codes report provenance-of-signal, so BOTH rows appear.
  expect_setequal(
    f$code,
    c("PAGE_META_ROBOTS_NOINDEX", "PAGE_XROBOTSTAG_NOINDEX")
  )
})

test_that("a clean page emits nothing", {
  expect_identical(nrow(page_noindex_findings(pn_run(pn_art()))), 0L)
  expect_identical(
    nrow(page_noindex_findings(pn_run(pn_art(pn_meta("index, follow"))))),
    0L
  )
})

test_that("the finding carries the structured facts in context", {
  f <- page_noindex_findings(
    pn_run(pn_art(pn_meta("noindex"))),
    ruleset = list(ruleset = "google")
  )
  ctx <- f$context[[1L]]
  expect_identical(ctx$page_noindex_engine, "google")
  expect_true(ctx$page_noindex_effective)
  expect_identical(ctx$page_noindex_fold_path, "single_channel")
  expect_length(ctx$page_noindex_facts, 1L)
  # The raw directive rides evidence$excerpt (free-form), not context only.
  expect_match(f$evidence[[1L]]$excerpt, "noindex", fixed = TRUE)
})

test_that("Yandex allow-wins reaches the message and the verdict", {
  run <- pn_run(pn_art(
    pn_meta("noindex"),
    headers = pn_headers("X-Robots-Tag" = "index")
  ))
  y <- page_noindex_findings(run, ruleset = list(ruleset = "yandex"))
  expect_false(y$context[[1L]]$page_noindex_effective)
  expect_match(y$message[[1L]], "not effectively noindex", fixed = TRUE)

  g <- page_noindex_findings(run, ruleset = list(ruleset = "google"))
  expect_true(g$context[[1L]]$page_noindex_effective)
  expect_match(g$message[[1L]], "effectively noindex", fixed = TRUE)
})

test_that("interpretation does not require robotstxtr", {
  # §0.3: only the ACCESS checks may gate on the Suggests. The fold must run
  # with the sibling stubbed unavailable.
  local_mocked_bindings(robotstxtr_available = function() FALSE)
  f <- page_noindex_findings(
    pn_run(pn_art(pn_meta("noindex"))),
    ruleset = list(ruleset = "google")
  )
  expect_identical(nrow(f), 1L)
  expect_identical(f$context[[1L]]$page_noindex_engine, "google")
})

# ---- integration through the public entry points -----------------------------

pn_local_sitemap <- function(loc = "https://example.com/a") {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<url><loc>",
    loc,
    "</loc></url></urlset>"
  )
  path <- tempfile(fileext = ".xml")
  writeLines(xml, path)
  path
}

pn_mock_noindex <- function(url) {
  httr2::response(
    status_code = 200L,
    url = url,
    headers = list(
      "Content-Type" = "text/html; charset=UTF-8",
      "X-Robots-Tag" = "noindex"
    ),
    body = charToRaw(paste0(
      "<html><head><link rel=\"canonical\" href=\"",
      url,
      "\"></head></html>"
    ))
  )
}

test_that("validate_sitemap surfaces a noindex row under inspect_pages", {
  path <- pn_local_sitemap("https://example.com/a")
  httr2::local_mocked_responses(
    list(pn_mock_noindex("https://example.com/a"))
  )
  out <- validate_sitemap(path, inspect_pages = TRUE)
  rows <- out[out$code == "PAGE_XROBOTSTAG_NOINDEX", ]
  expect_identical(nrow(rows), 1L)
  # Baseline still emits the pinned ten columns.
  expect_identical(ncol(out), 10L)
})

test_that("the engine overlay stamps the fold provenance on the row", {
  path <- pn_local_sitemap("https://example.com/a")
  httr2::local_mocked_responses(
    list(pn_mock_noindex("https://example.com/a"))
  )
  out <- validate_sitemap_ruleset(path, "google", inspect_pages = TRUE)
  rows <- out[out$code == "PAGE_XROBOTSTAG_NOINDEX", ]
  expect_identical(nrow(rows), 1L)
  # Single-channel fold -> the producer's `documented`, overriding the
  # assembler's inherited_protocol default for this code.
  expect_identical(rows$provenance, "documented")
  expect_identical(rows$ruleset, "google")
})

test_that("inspect_pages = FALSE stays byte-identical with noindex active", {
  path <- pn_local_sitemap("https://example.com/a")
  off <- validate_sitemap(path)
  explicit_off <- validate_sitemap(path, inspect_pages = FALSE)
  expect_identical(off, explicit_off)
  expect_false("page" %in% off$layer)
})
