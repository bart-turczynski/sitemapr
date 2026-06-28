# Direct unit tests for the Layer D finding-producer (R/protocol-validate.R),
# D.1 slice: the per-<loc> URL rules. These exercise validate_protocol() over
# constructed rows; the cucumber feature (features/protocol_validation.feature)
# is deliberately NOT wired here — it activates in Layer F (SITE-ymzvnlpr) once
# validate_sitemap() exists (architecture.md §3; repo convention, mirroring the
# schema slice's S6.6 decision).

base <- "sitemap://example.com/sitemap.xml"
sm_url <- "https://example.com/sitemap.xml"

rows_for <- function(loc) sitemap_rows(loc = loc)

codes_for <- function(loc, sitemap_url = NA_character_) {
  validate_protocol(rows_for(loc), sitemap_url = sitemap_url)$code
}

# --- Absoluteness ----------------------------------------------------------

test_that("a clean absolute http(s) loc set produces no findings", {
  out <- validate_protocol(
    rows_for(c("https://example.com/a", "https://example.com/b")),
    sitemap_url = sm_url
  )
  expect_s3_class(out, "tbl_df")
  expect_identical(nrow(out), 0L)
})

test_that("a relative loc produces PROTOCOL_URL_NOT_ABSOLUTE", {
  expect_identical(codes_for("/page/one"), "PROTOCOL_URL_NOT_ABSOLUTE")
})

test_that("a non-http(s) scheme produces PROTOCOL_URL_NOT_ABSOLUTE", {
  expect_identical(
    codes_for("ftp://example.com/x"), "PROTOCOL_URL_NOT_ABSOLUTE"
  )
  expect_identical(
    codes_for("data:text/plain,hi"), "PROTOCOL_URL_NOT_ABSOLUTE"
  )
})

test_that("a scheme-relative loc produces PROTOCOL_URL_NOT_ABSOLUTE", {
  expect_identical(
    codes_for("//example.com/x"), "PROTOCOL_URL_NOT_ABSOLUTE"
  )
})

test_that("an uppercase scheme is still recognised as absolute", {
  cc <- codes_for("HTTPS://example.com/a", sm_url)
  expect_false("PROTOCOL_URL_NOT_ABSOLUTE" %in% cc)
})

test_that("a non-absolute loc is reported once, without follow-on URL rules", {
  out <- validate_protocol(rows_for("ftp://example.com/a#frag"))
  expect_identical(out$code, "PROTOCOL_URL_NOT_ABSOLUTE")
})

# --- Host / length / escaping ----------------------------------------------

test_that("an absolute URL with no host produces PROTOCOL_URL_NO_HOST", {
  expect_true("PROTOCOL_URL_NO_HOST" %in% codes_for("https://"))
})

test_that("a loc of 2048+ chars produces PROTOCOL_URL_TOO_LONG (warning)", {
  long <- paste0("https://example.com/", strrep("a", 2100L))
  out <- validate_protocol(rows_for(long), sitemap_url = sm_url)
  too_long <- out[out$code == "PROTOCOL_URL_TOO_LONG", ]
  expect_identical(nrow(too_long), 1L)
  expect_identical(too_long$severity, "warning")
})

test_that("invalid percent-escaping produces PROTOCOL_URL_INVALID_ESCAPE", {
  bad_hex <- codes_for("https://example.com/a%ZZb", sm_url)
  truncated <- codes_for("https://example.com/a%2", sm_url)
  expect_true("PROTOCOL_URL_INVALID_ESCAPE" %in% bad_hex)
  expect_true("PROTOCOL_URL_INVALID_ESCAPE" %in% truncated)
})

test_that("a valid percent-escape is not flagged", {
  cc <- codes_for("https://example.com/a%20b", sm_url)
  expect_false("PROTOCOL_URL_INVALID_ESCAPE" %in% cc)
})

# --- Fragment / userinfo (info) --------------------------------------------

test_that("a fragment produces an info PROTOCOL_URL_FRAGMENT", {
  out <- validate_protocol(
    rows_for("https://example.com/a#section"), sitemap_url = sm_url
  )
  frag <- out[out$code == "PROTOCOL_URL_FRAGMENT", ]
  expect_identical(nrow(frag), 1L)
  expect_identical(frag$severity, "info")
})

test_that("userinfo produces an info PROTOCOL_URL_USERINFO", {
  out <- validate_protocol(
    rows_for("https://user@example.com/a"), sitemap_url = sm_url
  )
  ui <- out[out$code == "PROTOCOL_URL_USERINFO", ]
  expect_identical(nrow(ui), 1L)
  expect_identical(ui$severity, "info")
})

# --- Scope -----------------------------------------------------------------

test_that("a different-host loc produces PROTOCOL_URL_OUT_OF_SCOPE", {
  cc <- codes_for("https://other.com/a", sm_url)
  expect_true("PROTOCOL_URL_OUT_OF_SCOPE" %in% cc)
})

test_that("a loc above the sitemap's directory is out of scope", {
  out <- validate_protocol(
    rows_for("https://example.com/page"),
    sitemap_url = "https://example.com/deep/sitemap.xml"
  )
  expect_true("PROTOCOL_URL_OUT_OF_SCOPE" %in% out$code)
})

test_that("a loc at or below the sitemap's directory is in scope", {
  out <- validate_protocol(
    rows_for(c("https://example.com/deep/a", "https://example.com/deep/sub/b")),
    sitemap_url = "https://example.com/deep/sitemap.xml"
  )
  expect_false("PROTOCOL_URL_OUT_OF_SCOPE" %in% out$code)
})

test_that("scope is not checked when the sitemap URL is unknown", {
  cc <- codes_for("https://other.com/a")
  expect_false("PROTOCOL_URL_OUT_OF_SCOPE" %in% cc)
})

# --- Duplicate detection (full-URL identity key) ---------------------------

test_that("two identical locs produce PROTOCOL_DUPLICATE_LOC", {
  out <- validate_protocol(
    rows_for(c("https://example.com/a", "https://example.com/a")),
    sitemap_url = sm_url
  )
  dup <- out[out$code == "PROTOCOL_DUPLICATE_LOC", ]
  expect_identical(nrow(dup), 1L)
  expect_identical(dup$severity, "warning")
})

test_that("the default port collapses to the same identity for dedup", {
  out <- validate_protocol(
    rows_for(c("https://example.com:443/a", "https://example.com/a")),
    sitemap_url = sm_url
  )
  expect_true("PROTOCOL_DUPLICATE_LOC" %in% out$code)
})

test_that("a contentful query keeps two locs distinct (no false duplicate)", {
  out <- validate_protocol(
    rows_for(c("https://example.com/s?page=1", "https://example.com/s?page=2")),
    sitemap_url = sm_url
  )
  expect_false("PROTOCOL_DUPLICATE_LOC" %in% out$code)
})

# --- IRI acceptance + identity ---------------------------------------------

test_that("an IRI loc is accepted and keyed in its percent-encoded URI form", {
  iri <- "https://example.com/パス"
  out <- validate_protocol(rows_for(iri))
  expect_identical(nrow(out), 0L)

  key <- build_loc_key(parse_url_adapter(iri))
  expect_match(key, "%E3%83%91%E3%82%B9", fixed = TRUE)

  # The IRI and its already-encoded URI form share one identity (dedup catches
  # them) — proving the percent-encoded form is the comparison key.
  out2 <- validate_protocol(
    rows_for(c(iri, "https://example.com/%E3%83%91%E3%82%B9"))
  )
  expect_true("PROTOCOL_DUPLICATE_LOC" %in% out2$code)
})

# --- Shape, refs, determinism ----------------------------------------------

test_that("findings carry the protocol layer and entry-scoped subject_ref", {
  out <- validate_protocol(
    rows_for(c("https://example.com/a", "/relative")), sitemap_url = sm_url
  )
  not_abs <- out[out$code == "PROTOCOL_URL_NOT_ABSOLUTE", ]
  expect_identical(not_abs$layer, "protocol")
  expect_identical(not_abs$subject_type, "entry")
  expect_identical(not_abs$subject_ref, paste0(base, "#entry:2"))
  expect_identical(not_abs$evidence[[1]]$excerpt, "/relative")
})

test_that("subject_ref is fragment-only when the sitemap URL is unknown", {
  out <- validate_protocol(rows_for("/relative"))
  expect_identical(out$subject_ref, "#entry:1")
})

test_that("empty input yields a zero-row protocol-findings tibble", {
  out <- validate_protocol(empty_sitemap_rows())
  expect_s3_class(out, "tbl_df")
  expect_identical(nrow(out), 0L)
  expect_identical(out$layer, character(0))
})

test_that("the same input produces an identical finding set twice", {
  loc <- c(
    "https://example.com/a", "ftp://example.com/b", "https://other.com/c",
    "https://example.com/a#frag", "https://example.com/a"
  )
  a <- validate_protocol(rows_for(loc), sitemap_url = sm_url)
  b <- validate_protocol(rows_for(loc), sitemap_url = sm_url)
  expect_identical(a, b)
})
