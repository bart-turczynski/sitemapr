# Tests for the whole-sitemap hreflang findings producer
# (R/hreflang-findings.R). Fixtures are built in-line from parallel loc /
# alternates lists so each corpus is deterministic and self-contained. This
# producer is standalone (like the graph primitive it consumes); it is not run
# through validate_sitemap() here.

# One <xhtml:link> as the parser emits it (xml2::as_list() shape).
mk_link <- function(hreflang, href, rel = "alternate") {
  structure(list(), rel = rel, hreflang = hreflang, href = href)
}

mk_rows <- function(loc, alternates) {
  sitemap_rows(loc = loc, alternates = alternates)
}

codes_of <- function(findings) sort(findings$code)

test_that("a fully reciprocal, self-referencing cluster yields no findings", {
  rows <- mk_rows(
    loc = c("https://a.com/en", "https://a.com/de"),
    alternates = list(
      list(
        mk_link("en", "https://a.com/en"),
        mk_link("de", "https://a.com/de")
      ),
      list(
        mk_link("en", "https://a.com/en"),
        mk_link("de", "https://a.com/de")
      )
    )
  )
  f <- validate_hreflang_graph(rows, base = "sitemap://a.com/s.xml")
  expect_identical(nrow(f), 0L)
})

test_that("a corpus with no alternates yields no findings", {
  rows <- mk_rows(
    loc = c("https://a.com/x", "https://a.com/y"),
    alternates = list(NULL, NULL)
  )
  expect_identical(nrow(validate_hreflang_graph(rows)), 0L)
})

test_that("a URL missing its self-reference is flagged", {
  # en declares only a link to de (no self-ref); de self-refs and links back.
  rows <- mk_rows(
    loc = c("https://a.com/en", "https://a.com/de"),
    alternates = list(
      list(mk_link("de", "https://a.com/de")),
      list(
        mk_link("en", "https://a.com/en"),
        mk_link("de", "https://a.com/de")
      )
    )
  )
  f <- validate_hreflang_graph(rows, base = "sitemap://a.com/s.xml")
  expect_identical(codes_of(f), "HREFLANG_MISSING_SELF_REFERENCE")
  expect_identical(f$severity, "warning")
  expect_identical(f$layer, "protocol")
  expect_identical(f$subject_type, "document")
  expect_identical(f$subject_ref, "sitemap://a.com/s.xml")
  expect_true(grepl("https://a.com/en", f$message[[1L]], fixed = TRUE))
  expect_identical(f$evidence[[1L]]$excerpt, "https://a.com/en")
})

test_that("a one-way internal alternate is flagged as non-reciprocal", {
  # a self-refs and links to b; b self-refs but never links back to a.
  rows <- mk_rows(
    loc = c("https://a.com/a", "https://a.com/b"),
    alternates = list(
      list(
        mk_link("en", "https://a.com/a"),
        mk_link("de", "https://a.com/b")
      ),
      list(mk_link("de", "https://a.com/b"))
    )
  )
  f <- validate_hreflang_graph(rows, base = "sitemap://a.com/s.xml")
  expect_identical(codes_of(f), "HREFLANG_NON_RECIPROCAL")
  expect_true(grepl("reciprocal", f$message[[1L]], fixed = TRUE))
  expect_identical(
    f$evidence[[1L]]$excerpt,
    "https://a.com/a -> https://a.com/b"
  )
})

test_that("an external alternate target is not a false non-reciprocity", {
  # The only non-self alternate points outside the corpus -> unknown, not a
  # violation (corpus-boundary policy).
  rows <- mk_rows(
    loc = "https://a.com/en",
    alternates = list(list(
      mk_link("en", "https://a.com/en"),
      mk_link("de", "https://other.com/de")
    ))
  )
  f <- validate_hreflang_graph(rows, base = "sitemap://a.com/s.xml")
  expect_identical(nrow(f), 0L)
})

test_that("conflicting language tokens for one target are flagged", {
  # Two internal pages label the same (external) target differently.
  rows <- mk_rows(
    loc = c("https://a.com/1", "https://a.com/2"),
    alternates = list(
      list(
        mk_link("de", "https://a.com/1"),
        mk_link("en", "https://a.com/target")
      ),
      list(
        mk_link("de", "https://a.com/2"),
        mk_link("fr", "https://a.com/target")
      )
    )
  )
  f <- validate_hreflang_graph(rows, base = "sitemap://a.com/s.xml")
  expect_identical(codes_of(f), "HREFLANG_INCONSISTENT_LANGUAGE")
  expect_true(grepl("https://a.com/target", f$message[[1L]], fixed = TRUE))
  expect_true(grepl("'en'", f$message[[1L]], fixed = TRUE))
  expect_true(grepl("'fr'", f$message[[1L]], fixed = TRUE))
})

test_that("a pure casing difference is not a language conflict", {
  # en-US vs en-us: same tag (BCP 47 case-insensitive) -> no conflict.
  rows <- mk_rows(
    loc = c("https://a.com/1", "https://a.com/2"),
    alternates = list(
      list(
        mk_link("de", "https://a.com/1"),
        mk_link("en-US", "https://a.com/target")
      ),
      list(
        mk_link("de", "https://a.com/2"),
        mk_link("en-us", "https://a.com/target")
      )
    )
  )
  f <- validate_hreflang_graph(rows, base = "sitemap://a.com/s.xml")
  expect_false("HREFLANG_INCONSISTENT_LANGUAGE" %in% f$code)
})

test_that("findings are invariant to input row order", {
  loc <- c("https://a.com/a", "https://a.com/b", "https://a.com/c")
  alternates <- list(
    list(mk_link("de", "https://a.com/b")),
    list(mk_link("de", "https://a.com/b")),
    list(
      mk_link("en", "https://a.com/target"),
      mk_link("fr", "https://a.com/target")
    )
  )
  rows <- mk_rows(loc, alternates)
  perm <- c(3L, 1L, 2L)
  f1 <- validate_hreflang_graph(rows, base = "sitemap://a.com/s.xml")
  f2 <- validate_hreflang_graph(
    mk_rows(loc[perm], alternates[perm]),
    base = "sitemap://a.com/s.xml"
  )
  expect_identical(f1, f2)
  # It exercises all three codes at once.
  expect_setequal(
    unique(f1$code),
    c(
      "HREFLANG_MISSING_SELF_REFERENCE",
      "HREFLANG_NON_RECIPROCAL",
      "HREFLANG_INCONSISTENT_LANGUAGE"
    )
  )
})

test_that("the producer emits the contract-shaped producer columns", {
  rows <- mk_rows(
    loc = c("https://a.com/a", "https://a.com/b"),
    alternates = list(
      list(mk_link("de", "https://a.com/b")),
      list(mk_link("de", "https://a.com/b"))
    )
  )
  f <- validate_hreflang_graph(rows, base = "sitemap://a.com/s.xml")
  expect_named(
    f,
    c(
      "code",
      "severity",
      "layer",
      "subject_type",
      "subject_ref",
      "message",
      "evidence",
      "is_strict_only"
    )
  )
  expect_false(any(f$is_strict_only))
})
