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

test_that("a multi-element list cell is compared element-wise", {
  # `sources$redirect_chain` holds a bare character vector, so a multi-hop
  # chain exercises the vector arm of the cell serializer.
  src <- function(chain) {
    source_metadata(
      requested_url = "https://e/s.xml",
      redirect_chain = chain
    )
  }
  hops <- c("https://e/a", "https://e/b")

  same <- compare_sitemap_audits(
    sitemap_audit(sources = src(hops)),
    sitemap_audit(sources = src(hops))
  )
  expect_true(audit_unchanged(same))

  # Reordering the hops is a real content change, not a no-op: element order
  # is part of the chain's identity.
  reordered <- compare_sitemap_audits(
    sitemap_audit(sources = src(hops)),
    sitemap_audit(sources = src(rev(hops)))
  )
  chain <- reordered$components$sources
  expect_identical(nrow(chain$changed), 1L)
  expect_identical(nrow(chain$added), 0L)

  # A longer chain sharing its prefix is likewise a change, so the serializer
  # cannot be collapsing the vector to its first element.
  extended <- compare_sitemap_audits(
    sitemap_audit(sources = src(hops)),
    sitemap_audit(sources = src(c(hops, "https://e/c")))
  )
  expect_identical(nrow(extended$components$sources$changed), 1L)
})

test_that("an unnamed list cell serializes positionally", {
  # A chain supplied as an unnamed list (rather than a character vector) has
  # no element names to qualify its parts, so the cell serializer falls back
  # to bare positional values.
  src <- function(chain) {
    source_metadata(
      requested_url = "https://e/s.xml",
      redirect_chain = chain
    )
  }
  hops <- list("https://e/a", "https://e/b")

  expect_true(audit_unchanged(compare_sitemap_audits(
    sitemap_audit(sources = src(hops)),
    sitemap_audit(sources = src(hops))
  )))

  reordered <- compare_sitemap_audits(
    sitemap_audit(sources = src(hops)),
    sitemap_audit(sources = src(rev(hops)))
  )
  expect_identical(nrow(reordered$components$sources$changed), 1L)

  # Container shape is part of the signature: a list cell and the equivalent
  # character vector serialize differently ("{a,b}" vs "a;b") and so DO diff.
  # Harmless here because a given producer emits one shape consistently, but
  # it means the comparison is structural, not value-only.
  boxed <- compare_sitemap_audits(
    sitemap_audit(sources = src(hops)),
    sitemap_audit(sources = src(unlist(hops)))
  )
  expect_identical(nrow(boxed$components$sources$changed), 1L)
})

test_that("a named list cell compares on names as well as values", {
  # `sources$namespaces` is a named list; the prefix a URI is bound to is part
  # of the content, so rebinding it under a new prefix is a change.
  src <- function(ns) {
    source_metadata(requested_url = "https://e/s.xml", namespaces = ns)
  }
  ns <- list(sm = "http://www.sitemaps.org/schemas/sitemap/0.9")

  expect_true(audit_unchanged(compare_sitemap_audits(
    sitemap_audit(sources = src(ns)),
    sitemap_audit(sources = src(ns))
  )))

  renamed <- list(d1 = ns$sm)
  changed <- compare_sitemap_audits(
    sitemap_audit(sources = src(ns)),
    sitemap_audit(sources = src(renamed))
  )
  expect_identical(nrow(changed$components$sources$changed), 1L)
})

test_that("added and removed problems are detected", {
  problem <- parse_problems(
    severity = "warning",
    category = "classification",
    subject_ref = "https://e/s.xml",
    message = "not a sitemap"
  )
  none <- sitemap_audit()
  one <- sitemap_audit(problems = problem)

  added <- compare_sitemap_audits(none, one)$components$problems
  expect_identical(nrow(added$added), 1L)
  expect_identical(nrow(added$removed), 0L)

  removed <- compare_sitemap_audits(one, none)$components$problems
  expect_identical(nrow(removed$removed), 1L)
  expect_identical(nrow(removed$added), 0L)
})

test_that("printing an empty diff reports no changes", {
  audit <- sitemap_audit(urls = make_urls("https://example.com/"))
  d <- compare_sitemap_audits(audit, audit)

  expect_output(print(d), "<sitemap_audit_diff>")
  expect_output(print(d), "no changes")
  # The per-component count lines are suppressed entirely when nothing moved.
  expect_identical(
    capture.output(print(d)),
    c(
      "<sitemap_audit_diff>",
      "  no changes"
    )
  )
  expect_false(withVisible(print(d))$visible)
})

test_that("printing a non-empty diff reports per-component counts", {
  old <- sitemap_audit(
    urls = make_urls(c("https://e/keep", "https://e/gone"), priority = "0.5")
  )
  new <- sitemap_audit(
    urls = make_urls(
      c("https://e/keep", "https://e/new"),
      priority = c("0.9", "0.5")
    )
  )
  d <- compare_sitemap_audits(old, new)

  expect_output(print(d), "<sitemap_audit_diff>")
  expect_false(any(grepl("no changes", capture.output(print(d)), fixed = TRUE)))
  # urls: one added, one removed, one changed (the kept loc's priority moved).
  expect_output(print(d), "urls\\s+\\+1\\s+-1\\s+~1")
  # Every component gets a line, including the ones that did not move.
  out <- capture.output(print(d))
  expect_length(out, 1L + length(audit_component_names()))
  expect_output(print(d), "findings\\s+\\+0\\s+-0\\s+~0")
  expect_false(withVisible(print(d))$visible)
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
