# Behavioural tests for compare_sitemap_audits() (R/audit-compare.R). Audits are
# assembled from the package's internal component constructors so the tests are
# fully offline and exercise the comparison contract directly: determinism,
# order-independence, volatile-field insensitivity, and each change class.

# Build a urls component (a read_sitemap()-style row tibble) from parallel
# vectors, defaulting the optional fields.
make_urls <- function(loc, lastmod = NA_character_, priority = NA_character_) {
  sitemap_rows(loc = loc, lastmod = lastmod, priority = priority)
}

# Build a one-row findings tibble carrying the full findings contract.
make_finding <- function(code, subject_ref, severity = "warning") {
  tibble::tibble(
    code = code,
    severity = severity,
    layer = "protocol",
    subject_type = "url",
    subject_ref = subject_ref,
    message = "example finding",
    evidence = list(finding_evidence(excerpt = "x")),
    mode = "non-strict",
    is_strict_only = FALSE,
    remediation_hint = NA_character_
  )
}

test_that("an audit compared with itself yields an empty diff", {
  audit <- sitemap_audit(
    urls = make_urls(c("https://example.com/", "https://example.com/a")),
    findings = make_finding("PROTOCOL_LASTMOD_LOOKS_GENERATED", "https://e/"),
    sources = source_metadata(requested_url = "https://example.com/sitemap.xml")
  )

  d <- compare_sitemap_audits(audit, audit)

  expect_s3_class(d, "sitemap_audit_diff")
  expect_true(audit_unchanged(d))
  counts <- summary(d)
  expect_identical(sum(counts$added, counts$removed, counts$changed), 0L)
})

test_that("an independently rebuilt identical audit yields an empty diff", {
  build <- function() {
    sitemap_audit(
      urls = make_urls(
        c("https://example.com/", "https://example.com/a"),
        priority = c("0.5", "0.8")
      )
    )
  }

  expect_true(audit_unchanged(compare_sitemap_audits(build(), build())))
})

test_that("a diff on a volatile-only field (timing) is empty", {
  old <- sitemap_audit(
    sources = source_metadata(
      requested_url = "https://example.com/sitemap.xml",
      status = 200L,
      timing = 0.01
    )
  )
  new <- sitemap_audit(
    sources = source_metadata(
      requested_url = "https://example.com/sitemap.xml",
      status = 200L,
      timing = 42.5
    )
  )

  expect_true(audit_unchanged(compare_sitemap_audits(old, new)))
})

test_that("a non-volatile source change is detected as changed", {
  old <- sitemap_audit(
    sources = source_metadata(requested_url = "https://e/s.xml", status = 200L)
  )
  new <- sitemap_audit(
    sources = source_metadata(requested_url = "https://e/s.xml", status = 404L)
  )

  counts <- summary(compare_sitemap_audits(old, new))
  src <- counts[counts$component == "sources", ]
  expect_identical(c(src$added, src$removed, src$changed), c(0L, 0L, 1L))
})

test_that("an added URL is reported as exactly one addition", {
  old <- sitemap_audit(urls = make_urls("https://example.com/"))
  new <- sitemap_audit(
    urls = make_urls(c("https://example.com/", "https://example.com/new"))
  )

  d <- compare_sitemap_audits(old, new)
  urls <- d$components$urls
  expect_identical(nrow(urls$added), 1L)
  expect_identical(urls$added$loc, "https://example.com/new")
  expect_identical(nrow(urls$removed), 0L)
  expect_identical(nrow(urls$changed), 0L)
  expect_false(audit_unchanged(d))
})

test_that("a removed URL is reported as exactly one removal", {
  old <- sitemap_audit(
    urls = make_urls(c("https://example.com/", "https://example.com/gone"))
  )
  new <- sitemap_audit(urls = make_urls("https://example.com/"))

  urls <- compare_sitemap_audits(old, new)$components$urls
  expect_identical(nrow(urls$removed), 1L)
  expect_identical(urls$removed$loc, "https://example.com/gone")
  expect_identical(nrow(urls$added), 0L)
  expect_identical(nrow(urls$changed), 0L)
})

test_that("a same-loc content change is reported as changed, not add/remove", {
  old <- sitemap_audit(
    urls = make_urls("https://example.com/", priority = "0.5")
  )
  new <- sitemap_audit(
    urls = make_urls("https://example.com/", priority = "0.9")
  )

  urls <- compare_sitemap_audits(old, new)$components$urls
  expect_identical(nrow(urls$changed), 1L)
  expect_identical(urls$changed$loc, "https://example.com/")
  expect_identical(nrow(urls$added), 0L)
  expect_identical(nrow(urls$removed), 0L)
})

test_that("added and removed findings are detected", {
  finding <- make_finding("PROTOCOL_LASTMOD_LOOKS_GENERATED", "https://e/p")
  none <- sitemap_audit()
  one <- sitemap_audit(findings = finding)

  added <- compare_sitemap_audits(none, one)$components$findings
  expect_identical(nrow(added$added), 1L)
  expect_identical(nrow(added$removed), 0L)

  removed <- compare_sitemap_audits(one, none)$components$findings
  expect_identical(nrow(removed$removed), 1L)
  expect_identical(nrow(removed$added), 0L)
})

test_that("a source-tree node change is detected", {
  tree_node <- function(status) {
    sitemap_tree_rows(
      depth = 0L,
      parent_sitemap = NA_character_,
      sitemap_url = "https://example.com/sitemap.xml",
      page_count = 3L,
      gzip = FALSE,
      status = status,
      reason = NA_character_,
      provenance = "discovered"
    )
  }
  old <- sitemap_audit(tree = tree_node("ok"))
  new <- sitemap_audit(tree = tree_node("error"))

  tree <- compare_sitemap_audits(old, new)$components$tree
  expect_identical(nrow(tree$changed), 1L)
  expect_identical(nrow(tree$added), 0L)
  expect_identical(nrow(tree$removed), 0L)
})

test_that("shuffling a component's rows does not produce a diff", {
  locs <- c("https://e/1", "https://e/2", "https://e/3", "https://e/4")
  ordered <- sitemap_audit(urls = make_urls(locs))
  shuffled <- sitemap_audit(urls = make_urls(rev(locs)))

  expect_true(audit_unchanged(compare_sitemap_audits(ordered, shuffled)))
})

test_that("the diff is deterministic and independent of input order", {
  a <- sitemap_audit(
    urls = make_urls(c("https://e/a", "https://e/b", "https://e/c"))
  )
  b <- sitemap_audit(
    urls = make_urls(c("https://e/c", "https://e/b", "https://e/z"))
  )

  first <- summary(compare_sitemap_audits(a, b))
  second <- summary(compare_sitemap_audits(a, b))
  expect_identical(first, second)

  # Added rows come out sorted by key regardless of the new audit's row order.
  b_shuffled <- sitemap_audit(
    urls = make_urls(c("https://e/z", "https://e/c", "https://e/b"))
  )
  added_a <- compare_sitemap_audits(a, b)$components$urls$added
  added_b <- compare_sitemap_audits(a, b_shuffled)$components$urls$added
  expect_identical(added_a$loc, added_b$loc)
  expect_identical(added_a$loc, "https://e/z")
})

test_that("non-audit arguments raise a classed error", {
  audit <- sitemap_audit()
  expect_error(
    compare_sitemap_audits(audit, list()),
    class = "sitemapr_bad_input"
  )
  expect_error(
    compare_sitemap_audits("nope", audit),
    class = "sitemapr_bad_input"
  )
  expect_error(audit_unchanged(list()), class = "sitemapr_bad_input")
})
