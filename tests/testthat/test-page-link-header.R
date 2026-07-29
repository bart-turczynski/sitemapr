# Offline tests for the shared RFC 8288 `Link` header parser
# (R/page-link-header.R; Layer E, Contract B extraction).
#
# The parser is pure — a named header list in, raw link-values out — so every
# case here is a literal. The two producers that consume it are covered in
# test-page-canonical.R (rel=canonical) and test-page-hreflang.R (rel=alternate
# + hreflang); this file pins the grammar itself.

lh <- function(...) page_link_header_entries(list(...))

# ---- link-value segmentation -------------------------------------------------

test_that("a missing or empty Link header yields no link-values", {
  expect_identical(page_link_header_entries(list()), list())
  expect_identical(lh("Content-Type" = "text/html"), list())
})

test_that("repeated Link fields are all consulted", {
  # Repeated fields arrive as repeated names, which a literal `list()` call
  # cannot express.
  entries <- page_link_header_entries(stats::setNames(
    list(
      "<https://example.com/a>; rel=\"canonical\"",
      "<https://example.com/b>; rel=\"alternate\""
    ),
    c("Link", "Link")
  ))
  expect_length(entries, 2L)
  expect_identical(
    vapply(entries, function(e) e$uri, character(1)),
    c("https://example.com/a", "https://example.com/b")
  )
})

test_that("a comma inside the target or a quoted value does not split", {
  # The `,(?=\\s*<)` lookahead splits only on a comma that precedes the next
  # bracketed reference.
  entries <- lh(Link = "<https://e.com/a,b>; title=\"one, two\"")
  expect_length(entries, 1L)
  expect_identical(entries[[1L]]$uri, "https://e.com/a,b")
})

test_that("a segment with no bracketed reference is not a link-value", {
  expect_identical(lh(Link = "notalink; rel=canonical"), list())
})

# ---- parameter parsing -------------------------------------------------------

test_that("a link-value with no parameters parses with an empty set", {
  entry <- lh(Link = "<https://example.com/a>")[[1L]]
  expect_identical(entry$params, list())
  expect_identical(page_link_param_values(entry, "rel"), character(0))
})

test_that("quoted, bare and spaced parameter forms all parse", {
  quoted <- lh(Link = "<https://e.com/a>; rel=\"canonical\"")[[1L]]
  bare <- lh(Link = "<https://e.com/a>; rel=canonical")[[1L]]
  spaced <- lh(Link = "<https://e.com/a>; rel = \"canonical\" ")[[1L]]
  for (entry in list(quoted, bare, spaced)) {
    expect_identical(page_link_param_values(entry, "rel"), "canonical")
  }
})

test_that("a parameter name matches case-insensitively", {
  entry <- lh(Link = "<https://e.com/a>; REL=\"canonical\"")[[1L]]
  expect_identical(page_link_param_values(entry, "rel"), "canonical")
  expect_identical(page_link_param_values(entry, "Rel"), "canonical")
})

test_that("a semicolon inside a quoted value does not split a parameter", {
  header <- "<https://e.com/a>; title=\"a; b\"; rel=\"canonical\""
  entry <- lh(Link = header)[[1L]]
  expect_identical(page_link_param_values(entry, "title"), "a; b")
  expect_identical(page_link_param_values(entry, "rel"), "canonical")
})

test_that("a quoted-pair is unescaped, not read as a terminator", {
  header <- "<https://e.com/a>; title=\"a \\\" b\"; rel=canonical"
  entry <- lh(Link = header)[[1L]]
  expect_identical(page_link_param_values(entry, "title"), "a \" b")
  expect_identical(page_link_param_values(entry, "rel"), "canonical")
})

test_that("an empty parameter chunk is dropped, not read as a parameter", {
  entry <- lh(Link = "<https://e.com/a>; ; rel=\"canonical\"")[[1L]]
  expect_length(entry$params, 1L)
  expect_identical(page_link_param_values(entry, "rel"), "canonical")
})

test_that("a valueless parameter reads as an empty value", {
  entry <- lh(Link = "<https://e.com/a>; noval; rel=canonical")[[1L]]
  expect_identical(page_link_param_values(entry, "noval"), "")
})

test_that("a repeated parameter keeps every occurrence in order", {
  # RFC 8288 3.4 — `hreflang` may name several languages for one target.
  entry <- lh(
    Link = "<https://e.com/a>; rel=alternate; hreflang=\"de\"; hreflang=de-AT"
  )[[1L]]
  expect_identical(
    page_link_param_values(entry, "hreflang"),
    c("de", "de-AT")
  )
})

# ---- rel is a token list, not a substring ------------------------------------

test_that("rel matches as a token in any position", {
  # RFC 8288 3.3 — a whitespace-separated list whose order is not significant.
  for (rel in c("canonical", "canonical alternate", "alternate canonical")) {
    entry <- lh(Link = sprintf("<https://e.com/a>; rel=\"%s\"", rel))[[1L]]
    expect_true(page_link_has_rel(entry, "canonical"))
  }
})

test_that("rel tokens compare case-insensitively", {
  entry <- lh(Link = "<https://e.com/a>; rel=\"CANONICAL\"")[[1L]]
  expect_identical(page_link_rel_tokens(entry), "canonical")
  expect_true(page_link_has_rel(entry, "canonical"))
})

test_that("a merely canonical-prefixed relation type does not match", {
  for (rel in c("canonical-ish", "not-canonical", "canonicalize")) {
    entry <- lh(Link = sprintf("<https://e.com/a>; rel=\"%s\"", rel))[[1L]]
    expect_false(page_link_has_rel(entry, "canonical"))
  }
})

test_that("only the first rel parameter counts", {
  # RFC 8288 3.3 — occurrences after the first MUST be ignored.
  entry <- lh(Link = "<https://e.com/a>; rel=alternate; rel=canonical")[[1L]]
  expect_identical(page_link_rel_tokens(entry), "alternate")
  expect_false(page_link_has_rel(entry, "canonical"))
})

test_that("an absent or blank rel yields no relation types", {
  no_rel <- lh(Link = "<https://e.com/a>; type=\"text/html\"")[[1L]]
  expect_identical(page_link_rel_tokens(no_rel), character(0))
  expect_false(page_link_has_rel(no_rel, "canonical"))

  blank <- lh(Link = "<https://e.com/a>; rel=\"  \"")[[1L]]
  expect_identical(page_link_rel_tokens(blank), character(0))
})
