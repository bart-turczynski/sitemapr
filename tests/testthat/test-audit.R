# Unit tests for the sitemap_audit container, its accessors, and its print /
# summary methods (R/audit.R). Fully offline: audits are assembled from
# read_sitemap()/validate_sitemap() run over a local temp fixture, so no
# network is touched.

# A small valid urlset fixture written to a temp file; returns its path.
audit_fixture_path <- function() {
  xml <- paste0(
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    "<url><loc>https://example.com/</loc>",
    "<lastmod>2024-01-01</lastmod></url>",
    "<url><loc>https://example.com/about</loc></url>",
    "</urlset>"
  )
  path <- withr::local_tempfile(fileext = ".xml", .local_envir = parent.frame())
  writeLines(xml, path)
  path
}

test_that("sitemap_audit() with no arguments is a valid empty audit", {
  audit <- sitemap_audit()

  expect_s3_class(audit, "sitemap_audit")
  expect_identical(nrow(audit_urls(audit)), 0L)
  expect_identical(nrow(audit_findings(audit)), 0L)
  expect_identical(nrow(audit_sources(audit)), 0L)
  expect_identical(nrow(audit_problems(audit)), 0L)
  expect_identical(nrow(audit_tree(audit)), 0L)

  # Empty components still carry their full column contract.
  expect_named(audit_findings(audit), names(empty_findings_contract()))
  expect_named(audit_tree(audit), sitemap_tree_cols())
})

test_that("sitemap_audit() assembles precomputed read + validate outputs", {
  path <- audit_fixture_path()
  urls <- read_sitemap(path)
  findings <- validate_sitemap(path, mode = "non-strict")

  audit <- sitemap_audit(urls = urls, findings = findings)

  expect_s3_class(audit, "sitemap_audit")
  # Component values are the existing tidy shapes, unchanged.
  expect_identical(nrow(audit_urls(audit)), 2L)
  url_cols <- names(audit_urls(audit))
  expect_true(all(c("loc", "lastmod", "priority") %in% url_cols))
  expect_identical(audit_findings(audit), findings)
})

test_that("sources/problems are pulled from the urls attributes", {
  path <- audit_fixture_path()
  urls <- read_sitemap(path)

  audit <- sitemap_audit(urls = urls)

  # read_sitemap() carries one source record; audit promotes it.
  expect_identical(audit_sources(audit), attr(urls, "sources"))
  expect_identical(audit_problems(audit), attr(urls, "problems"))
  # The promoted attributes are stripped from the stored urls component.
  expect_null(attr(audit_urls(audit), "sources"))
  expect_null(attr(audit_urls(audit), "problems"))
})

test_that("explicit sources/problems override the urls attributes", {
  path <- audit_fixture_path()
  urls <- read_sitemap(path)
  probs <- parse_problems(
    severity = "info",
    category = "classification",
    subject_ref = "x",
    message = "custom"
  )

  audit <- sitemap_audit(urls = urls, problems = probs)

  expect_identical(audit_problems(audit), probs)
})

test_that("a partial audit (urls only, no findings) is valid", {
  path <- audit_fixture_path()

  audit <- sitemap_audit(urls = read_sitemap(path))

  expect_s3_class(audit, "sitemap_audit")
  expect_identical(nrow(audit_urls(audit)), 2L)
  expect_identical(nrow(audit_findings(audit)), 0L)
  expect_identical(nrow(audit_tree(audit)), 0L)
})

test_that("the validator rejects a malformed component shape", {
  bad <- new_sitemap_audit(
    urls = data.frame(wrong = 1),
    findings = empty_findings_contract(),
    sources = empty_source_metadata(),
    problems = empty_problems(),
    tree = empty_sitemap_tree()
  )

  expect_error(
    validate_sitemap_audit(bad),
    class = "sitemapr_bad_input"
  )
})

test_that("accessors reject a non-audit input", {
  expect_error(audit_urls(list()), class = "sitemapr_bad_input")
  expect_error(audit_findings(42), class = "sitemapr_bad_input")
})

test_that("print.sitemap_audit reports component counts", {
  path <- audit_fixture_path()
  audit <- sitemap_audit(urls = read_sitemap(path))

  expect_output(print(audit), "<sitemap_audit>")
  expect_output(print(audit), "urls:\\s+2")
  expect_output(print(audit), "findings: 0")
  # print() returns its argument invisibly.
  expect_identical(withVisible(print(audit))$value, audit)
  expect_false(withVisible(print(audit))$visible)
})

test_that("summary.sitemap_audit returns component and severity counts", {
  path <- audit_fixture_path()
  audit <- sitemap_audit(urls = read_sitemap(path))

  s <- summary(audit)

  expect_identical(s$n_urls, 2L)
  expect_named(
    s$findings,
    c("fatal", "error", "warning", "info")
  )
  expect_identical(unname(s$findings), rep(0L, 4L))
  expect_identical(s$n_sources, 1L)
})
