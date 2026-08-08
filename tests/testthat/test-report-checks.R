# Unit tests for the report's checks section (R/report-checks.R).
#
# The section's whole value is that it may not overstate: a check reported as
# passed must be one this port implements AND one whose layer demonstrably ran.
# These tests pin both halves — the eligibility filter and the per-layer
# evidence rules, including the layers that are deliberately understated.

layer_ran <- function(urls, sources, findings) {
  sitemapr_test_call("report_layer_ran", urls, sources, findings)
}

check_states <- function(urls, sources, findings) {
  sitemapr_test_call("report_check_states", urls, sources, findings)
}

no_findings <- function() {
  sitemapr_test_call("empty_findings_contract")
}

# ---- per-layer run evidence --------------------------------------------------

test_that("the evidence vector covers every layer the assembler can emit", {
  # Lockstep guard: report_check_states() indexes this vector by the registry's
  # `layer` column, so a layer missing here would subscript with NA rather than
  # mislabel silently -- but a layer whose evidence rule was never written is a
  # gap either way.
  ran <- layer_ran(report_urls_fixture(character(0)), NULL, no_findings())
  expect_named(ran, sitemapr_test_ns$findings_layer_order)
})

test_that("a local single-file run proves only what it exercised", {
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture(
    "/tmp/sitemap.xml",
    "/tmp/sitemap.xml",
    "xml-urlset"
  )
  sources$status <- NA_integer_
  ran <- layer_ran(urls, sources, no_findings())

  expect_true(ran[["classification"]]) # bytes were sniffed
  expect_true(ran[["schema"]]) # a urlset root is XSD-validated
  expect_true(ran[["protocol"]]) # rows exist, so they were checked
  expect_true(ran[["report"]]) # the cap runs at every assembly
  expect_false(ran[["fetch"]]) # no HTTP status and no error class
  expect_false(ran[["decompression"]]) # nothing was inflated
  expect_false(ran[["index-expansion"]]) # not an index
  expect_false(ran[["page"]]) # no page_coverage attribute
  expect_false(ran[["robots"]]) # leaves no trace when clean
})

test_that("an HTTP status or a recorded error class proves a fetch", {
  urls <- report_urls_fixture("https://ex.com/a")
  fetched <- report_sources_fixture(
    "https://ex.com/s.xml",
    "https://ex.com/s.xml",
    "xml-urlset"
  )
  expect_true(layer_ran(urls, fetched, no_findings())[["fetch"]])

  failed <- fetched
  failed$status <- NA_integer_
  failed$error_class <- "sitemapr_fetch_failed"
  ran <- layer_ran(urls, failed, no_findings())
  expect_true(ran[["fetch"]])
  # A source that never parsed reached neither the sniffer nor the XSD.
  expect_false(ran[["classification"]])
  expect_false(ran[["schema"]])
})

test_that("gzip proves decompression but leaves the inner root unproven", {
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture("/tmp/s.xml.gz", "/tmp/s.xml.gz", "gzip")
  ran <- layer_ran(urls, sources, no_findings())

  expect_true(ran[["decompression"]])
  # The source record keeps the OUTER format, so nothing here proves the
  # inflated document was schema-validated. Understating is the safe direction.
  expect_false(ran[["schema"]])
  # URL rows still prove the protocol layer ran over them.
  expect_true(ran[["protocol"]])
})

test_that("a sitemapindex root proves index expansion", {
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture(
    c("https://ex.com/i.xml", "https://ex.com/c.xml"),
    c("https://ex.com/i.xml", "https://ex.com/c.xml"),
    c("xml-sitemapindex", "xml-urlset")
  )
  ran <- layer_ran(urls, sources, no_findings())

  expect_true(ran[["index-expansion"]])
  expect_true(ran[["schema"]])
})

test_that("the page_coverage attribute is what proves page inspection ran", {
  urls <- report_urls_fixture("https://ex.com/a")
  findings <- no_findings()
  expect_false(layer_ran(urls, NULL, findings)[["page"]])

  attr(findings, "page_coverage") <- list(schema_version = "1", selected = 1L)
  expect_true(layer_ran(urls, NULL, findings)[["page"]])
})

test_that("a fired finding proves its own layer ran", {
  urls <- report_urls_fixture("https://ex.com/a")
  findings <- report_findings_fixture(
    "ROBOTS_DISALLOWED",
    "warning",
    "robots"
  )
  expect_true(layer_ran(urls, NULL, findings)[["robots"]])
})

test_that("the run manifest proves a clean robots run ran (SITE-ysoqjxpm)", {
  # check_robots = TRUE emits nothing when every URL is allowed, so the stamp is
  # the only evidence that distinguishes it from a skipped check.
  urls <- report_urls_fixture("https://ex.com/a")
  findings <- no_findings()
  expect_false(layer_ran(urls, NULL, findings)[["robots"]])

  attr(findings, "layers_run") <- "robots"
  expect_true(layer_ran(urls, NULL, findings)[["robots"]])
})

test_that("the manifest proves schema for a source whose format hides it", {
  # A gzip source records the outer format, so the inference cannot see that the
  # inflated document was schema-validated.
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture(
    "https://ex.com/s.xml.gz",
    "https://ex.com/s.xml.gz",
    "gzip"
  )
  findings <- no_findings()
  expect_false(layer_ran(urls, sources, findings)[["schema"]])

  attr(findings, "layers_run") <- "schema"
  expect_true(layer_ran(urls, sources, findings)[["schema"]])
})

test_that("the manifest only adds evidence and never widens the table", {
  urls <- report_urls_fixture("https://ex.com/a")
  findings <- no_findings()
  attr(findings, "layers_run") <- c("robots", "not-a-layer")
  ran <- layer_ran(urls, NULL, findings)

  expect_named(ran, report_layer_order)
  expect_true(ran[["robots"]])
  # An unstamped layer is untouched by the union.
  expect_false(ran[["discovery"]])
})

test_that("a clean robots run reports its checks as passed, not not-run", {
  # The end-to-end statement of the fix, at the level the report renders.
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture("/tmp/s.xml", "/tmp/s.xml", "xml-urlset")
  findings <- no_findings()

  before <- report_check_states(urls, sources, findings)
  robots_before <- before$state[before$layer == "robots"]
  expect_true(all(robots_before == "not-run"))

  attr(findings, "layers_run") <- "robots"
  after <- report_check_states(urls, sources, findings)
  robots_after <- after$state[after$layer == "robots"]
  expect_gt(length(robots_after), 0L)
  expect_true(all(robots_after == "passed"))
})

test_that("a NULL sources attribute proves nothing rather than erroring", {
  urls <- report_urls_fixture(character(0))
  ran <- layer_ran(urls, NULL, no_findings())

  expect_false(ran[["fetch"]])
  expect_false(ran[["classification"]])
  expect_false(ran[["protocol"]])
})

# ---- per-code outcome --------------------------------------------------------

test_that("states are one of fired/passed/not-run, and only for active codes", {
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture("/tmp/s.xml", "/tmp/s.xml", "xml-urlset")
  findings <- report_findings_fixture(
    "PROTOCOL_URL_FRAGMENT",
    "warning",
    "protocol"
  )
  states <- check_states(urls, sources, findings)

  active <- sitemapr_test_call("findings_active_codes")
  expect_equal(nrow(states), nrow(active))
  expect_true(all(states$state %in% c("fired", "passed", "not-run")))
  expect_equal(
    states$state[states$code == "PROTOCOL_URL_FRAGMENT"],
    "fired"
  )
  # A protocol sibling that did not fire passed; a page check never ran.
  expect_equal(
    states$state[states$code == "PROTOCOL_URL_USERINFO"],
    "passed"
  )
  expect_equal(
    states$state[states$code == "PAGE_CANONICAL_MISSING"],
    "not-run"
  )
  # Rows read in pipeline order, not registry order.
  expect_equal(
    unique(states$layer),
    sitemapr_test_ns$report_layer_order[
      sitemapr_test_ns$report_layer_order %in% states$layer
    ]
  )
})

# ---- the ruleset gate (SITE-lbhbltzf) ---------------------------------------

# Layer membership was once the only gate, so a baseline run reported all four
# engine-gated codes as checks that ran and found nothing. The layer HAD run in
# each case; the emitter was simply unreachable without an overlay selected.
gated_codes <- function() {
  reg <- sitemapr_test_call("findings_registry")
  reg$code[reg$status == "active" & reg$ruleset != "baseline"]
}

test_that("a baseline run reports every engine-gated code as not-run", {
  # A sitemapindex, so index-expansion, classification and protocol all run and
  # the layer gate alone would wave all four through.
  findings <- validate_sitemap(test_path("fixtures", "valid-index.xml"))
  urls <- read_sitemap(test_path("fixtures", "valid-index.xml"))
  states <- check_states(urls, attr(urls, "sources"), findings)

  gated <- states[states$code %in% gated_codes(), ]
  expect_gt(nrow(gated), 0L)
  expect_true(all(gated$state == "not-run"))
  # Their layers did run: this is the ruleset gate firing, not the layer one.
  expect_true(any(gated$reason == "ruleset"))
  # And the summary's numerator drops with them.
  expect_false(any(states$state[states$code %in% gated_codes()] == "passed"))
})

test_that("an overlay run that finds NOTHING still vouches for its own codes", {
  # The case the additive `ruleset` COLUMN cannot answer: zero rows means zero
  # values in it, so the engine is recoverable only from the run stamp.
  path <- test_path("fixtures", "index-simple.xml")
  findings <- validate_sitemap_ruleset(path, "yandex")
  expect_equal(nrow(findings), 0L)
  expect_length(findings$ruleset, 0L)
  expect_equal(sitemapr_test_call("findings_ruleset_run", findings), "yandex")

  urls <- read_sitemap(path)
  states <- check_states(urls, attr(urls, "sources"), findings)
  state_of <- function(code) states$state[states$code == code]

  # yandex's own classification check, and the overlay tier that applies under
  # every engine, both passed.
  expect_equal(state_of("ENGINE_UNSUPPORTED_SITEMAP_FORMAT"), "passed")
  expect_equal(state_of("INDEX_CHILD_OUT_OF_SCOPE"), "passed")
})

test_that("another engine's codes stay not-run under a selected overlay", {
  path <- test_path("fixtures", "index-simple.xml")
  findings <- validate_sitemap_ruleset(path, "google")
  urls <- read_sitemap(path)
  states <- check_states(urls, attr(urls, "sources"), findings)
  row <- states[states$code == "ENGINE_UNSUPPORTED_SITEMAP_FORMAT", ]

  # google ran the classification layer, but this check is yandex's.
  expect_equal(row$state, "not-run")
  expect_equal(row$reason, "ruleset")
  # The `overlay` tier is every engine, so google reaches that one.
  overlay <- states$state[states$code == "INDEX_CHILD_OUT_OF_SCOPE"]
  expect_equal(overlay, "passed")
})

test_that("a fired code outranks the ruleset gate", {
  # Belt and braces: a findings tibble carrying an engine-gated code but no run
  # stamp must still report it "fired" rather than contradicting itself.
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture("/tmp/s.xml", "/tmp/s.xml", "xml-urlset")
  findings <- report_findings_fixture(
    "PROTOCOL_URL_DECODED_TOO_LONG",
    "error",
    "protocol"
  )
  states <- check_states(urls, sources, findings)

  expect_length(sitemapr_test_call("findings_ruleset_run", findings), 0L)
  expect_equal(
    states$state[states$code == "PROTOCOL_URL_DECODED_TOO_LONG"],
    "fired"
  )
})

test_that("a validator-only code never appears as a passed check", {
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture("/tmp/s.xml", "/tmp/s.xml", "xml-urlset")
  states <- check_states(urls, sources, no_findings())

  reg <- sitemapr_test_call("findings_registry")
  # INPUT_INVALID is the sibling's; this port has no input-layer emitter at all.
  expect_equal(reg$status[reg$code == "INPUT_INVALID"], "validator-only")
  expect_false("INPUT_INVALID" %in% states$code)
})

# ---- rendering --------------------------------------------------------------

test_that("a clean local run reports what passed and what was not exercised", {
  html <- render_string(core_fixture())

  expect_match(html, "<h2>Checks</h2>", fixed = TRUE)
  expect_match(html, "checks passed", fixed = TRUE)
  expect_match(html, "0 reported an issue", fixed = TRUE)
  # The layers that were not exercised are named, so the omission is explicit.
  expect_match(html, "Not exercised", fixed = TRUE)
  expect_match(html, "neither passed nor failed", fixed = TRUE)
  # An active code from a layer that ran is enumerated...
  expect_match(html, "PROTOCOL_URL_USERINFO", fixed = TRUE)
  # ...and one from a layer that did not is never called passed.
  passed_block <- sub("^.*<details class=\"smr-checks\">", "", html)
  passed_block <- sub("</details>.*$", "", passed_block)
  expect_no_match(passed_block, "PAGE_CANONICAL_MISSING", fixed = TRUE)
})

test_that("a fired code is counted as reported, not as passed", {
  findings <- validate_sitemap(findings_fixture())
  expect_true("PROTOCOL_PRIORITY_OUT_OF_RANGE" %in% findings$code)

  html <- render_string(findings_fixture())
  expect_match(html, "reported an issue", fixed = TRUE)
  passed_block <- sub("^.*<details class=\"smr-checks\">", "", html)
  passed_block <- sub("</details>.*$", "", passed_block)
  expect_no_match(passed_block, "PROTOCOL_PRIORITY_OUT_OF_RANGE", fixed = TRUE)
})

test_that("the singular passed-check label and an all-unknown run render", {
  # Nothing parsed and no rows: only the always-on report-layer cap can be
  # reported as passed, which also exercises the singular label.
  urls <- report_urls_fixture(character(0))
  html <- render_string("nothing", urls = urls, findings = no_findings())

  expect_match(html, "1 check passed", fixed = TRUE)
  expect_match(html, "REPORT_TRUNCATED", fixed = TRUE)
})

test_that("with nothing left to report as passed the table is omitted", {
  # The report-layer cap is the last check standing when no source parsed; fire
  # it and the passed set is empty, so the collapsible table must disappear
  # rather than render an empty shell.
  urls <- report_urls_fixture(character(0))
  findings <- report_findings_fixture("REPORT_TRUNCATED", "info", "report")
  html <- render_string("truncated", urls = urls, findings = findings)

  expect_match(html, "<h2>Checks</h2>", fixed = TRUE)
  # The class name still appears in the inlined CSS; the element must not.
  expect_no_match(html, "<details class=\"smr-checks\">", fixed = TRUE)
  expect_match(html, "Not exercised", fixed = TRUE)
})

test_that("a run that exercises every layer has no not-exercised note", {
  urls <- report_urls_fixture("https://ex.com/a")
  sources <- report_sources_fixture(
    c("https://ex.com/i.xml", "https://ex.com/c.xml.gz"),
    c("https://ex.com/i.xml", "https://ex.com/c.xml.gz"),
    c("xml-sitemapindex", "gzip")
  )
  attr(urls, "sources") <- sources
  findings <- report_findings_fixture(
    c("ROBOTS_DISALLOWED", "PAGE_CANONICAL_MISSING"),
    c("warning", "warning"),
    c("robots", "page")
  )
  html <- render_string("full", urls = urls, findings = findings)

  expect_match(html, "checks passed", fixed = TRUE)
  expect_no_match(html, "Not exercised", fixed = TRUE)
  # Every LAYER ran, so the layer note is gone -- but the engine-gated checks
  # still did not run, and they are reported under their own reason rather than
  # folded into a note that would name layers whose checks demonstrably passed.
  expect_match(html, "Gated on a ruleset this run did not select", fixed = TRUE)
  expect_match(html, "run used the sitemaps.org baseline", fixed = TRUE)
  expect_match(html, "applying under: any engine, yandex", fixed = TRUE)
})

test_that("the ruleset note names the selected engine on an overlay run", {
  path <- test_path("fixtures", "index-simple.xml")
  urls <- read_sitemap(path)
  html <- render_string(
    path,
    urls = urls,
    findings = validate_sitemap_ruleset(path, "google")
  )

  expect_match(html, "This run used the google", fixed = TRUE)
  # Only yandex's remain gated; the overlay tier is reachable under google.
  expect_match(html, "applying under: yandex", fixed = TRUE)
})
