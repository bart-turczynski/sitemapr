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

# ===========================================================================
# D.2 — count & field-value rules (SITE-ysviepus)
# ===========================================================================

# --- URL count -------------------------------------------------------------

test_that("over 50000 URL entries produces PROTOCOL_URL_COUNT_EXCEEDED", {
  rows <- rows_for(sprintf("https://example.com/p%d", seq_len(3L)))
  out <- validate_protocol(
    rows, sitemap_url = sm_url, limits = protocol_limits(max_url_count = 2L)
  )
  cnt <- out[out$code == "PROTOCOL_URL_COUNT_EXCEEDED", ]
  expect_identical(nrow(cnt), 1L)
  expect_identical(cnt$severity, "error")
  expect_identical(cnt$subject_type, "document")
  expect_identical(cnt$subject_ref, base)
})

test_that("a URL count at the limit does not fire", {
  rows <- rows_for(sprintf("https://example.com/p%d", seq_len(2L)))
  out <- validate_protocol(
    rows, sitemap_url = sm_url, limits = protocol_limits(max_url_count = 2L)
  )
  expect_false("PROTOCOL_URL_COUNT_EXCEEDED" %in% out$code)
})

# --- Uncompressed size -----------------------------------------------------

test_that("an oversized document produces PROTOCOL_SIZE_EXCEEDED", {
  out <- validate_protocol(
    rows_for("https://example.com/a"), sitemap_url = sm_url,
    byte_size = 60 * 1024^2
  )
  sz <- out[out$code == "PROTOCOL_SIZE_EXCEEDED", ]
  expect_identical(nrow(sz), 1L)
  expect_identical(sz$severity, "error")
  expect_identical(sz$subject_type, "document")
})

test_that("size within the limit, or an unknown size, does not fire", {
  small <- validate_protocol(
    rows_for("https://example.com/a"), sitemap_url = sm_url, byte_size = 1024
  )
  unknown <- validate_protocol(
    rows_for("https://example.com/a"), sitemap_url = sm_url
  )
  expect_false("PROTOCOL_SIZE_EXCEEDED" %in% small$code)
  expect_false("PROTOCOL_SIZE_EXCEEDED" %in% unknown$code)
})

# --- priority --------------------------------------------------------------

test_that("priority outside [0,1] produces PROTOCOL_PRIORITY_OUT_OF_RANGE", {
  out <- validate_protocol(
    sitemap_rows(
      loc = c("https://example.com/a", "https://example.com/b"),
      priority = c(1.5, -0.2)
    ),
    sitemap_url = sm_url
  )
  pri <- out[out$code == "PROTOCOL_PRIORITY_OUT_OF_RANGE", ]
  expect_identical(nrow(pri), 2L)
  expect_identical(unique(pri$severity), "error")
  expect_identical(pri$subject_ref, paste0(base, c("#entry:1", "#entry:2")))
})

test_that("priority at the [0,1] bounds and absent priority are accepted", {
  out <- validate_protocol(
    sitemap_rows(
      loc = c("https://example.com/a", "https://example.com/b",
              "https://example.com/c"),
      priority = c(0, 1, NA)
    ),
    sitemap_url = sm_url
  )
  expect_false("PROTOCOL_PRIORITY_OUT_OF_RANGE" %in% out$code)
})

# --- changefreq ------------------------------------------------------------

test_that("an out-of-enum changefreq produces PROTOCOL_CHANGEFREQ_INVALID", {
  out <- validate_protocol(
    sitemap_rows(loc = "https://example.com/a", changefreq = "fortnightly"),
    sitemap_url = sm_url
  )
  cf <- out[out$code == "PROTOCOL_CHANGEFREQ_INVALID", ]
  expect_identical(nrow(cf), 1L)
  expect_identical(cf$severity, "error")
})

test_that("changefreq is case-sensitive (Daily is invalid)", {
  out <- validate_protocol(
    sitemap_rows(loc = "https://example.com/a", changefreq = "Daily"),
    sitemap_url = sm_url
  )
  expect_true("PROTOCOL_CHANGEFREQ_INVALID" %in% out$code)
})

test_that("every valid changefreq enum value is accepted", {
  vals <- c("always", "hourly", "daily", "weekly", "monthly", "yearly",
            "never")
  out <- validate_protocol(
    sitemap_rows(
      loc = sprintf("https://example.com/p%d", seq_along(vals)),
      changefreq = vals
    ),
    sitemap_url = sm_url
  )
  expect_false("PROTOCOL_CHANGEFREQ_INVALID" %in% out$code)
})

# --- lastmod format (needs the original strings) ---------------------------

test_that("a malformed lastmod produces PROTOCOL_LASTMOD_INVALID", {
  raw <- c("2004-12-23T18:00:15+00:00", "not-a-date")
  out <- validate_protocol(
    rows_for(c("https://example.com/a", "https://example.com/b")),
    sitemap_url = sm_url, lastmod_raw = raw
  )
  lm <- out[out$code == "PROTOCOL_LASTMOD_INVALID", ]
  expect_identical(nrow(lm), 1L)
  expect_identical(lm$severity, "error")
  expect_identical(lm$subject_ref, paste0(base, "#entry:2"))
})

test_that("a datetime lastmod without a timezone is invalid", {
  out <- validate_protocol(
    rows_for("https://example.com/a"), sitemap_url = sm_url,
    lastmod_raw = "2004-12-23T18:00:15"
  )
  expect_true("PROTOCOL_LASTMOD_INVALID" %in% out$code)
})

test_that("a date-only lastmod produces strict-only info DATE_ONLY", {
  out <- validate_protocol(
    rows_for("https://example.com/a"), sitemap_url = sm_url,
    lastmod_raw = "2004-12-23"
  )
  do <- out[out$code == "PROTOCOL_LASTMOD_DATE_ONLY", ]
  expect_identical(nrow(do), 1L)
  expect_identical(do$severity, "info")
  expect_true(do$is_strict_only)
  expect_false("PROTOCOL_LASTMOD_INVALID" %in% out$code)
})

test_that("a full datetime lastmod is clean and not flagged date-only", {
  out <- validate_protocol(
    rows_for("https://example.com/a"), sitemap_url = sm_url,
    lastmod_raw = "2004-12-23T18:00:15+00:00"
  )
  expect_false(any(grepl("LASTMOD", out$code)))
})

test_that("lastmod format checks are skipped when raw strings are absent", {
  # A malformed lastmod that the parser already collapsed to NA cannot be
  # re-flagged from the typed column — no raw strings, no format finding.
  out <- validate_protocol(rows_for("https://example.com/a"),
                           sitemap_url = sm_url)
  expect_false(any(grepl("LASTMOD_INVALID|LASTMOD_DATE_ONLY", out$code)))
})

test_that("an absent (NA/empty) lastmod string is not flagged", {
  out <- validate_protocol(
    rows_for(c("https://example.com/a", "https://example.com/b")),
    sitemap_url = sm_url, lastmod_raw = c(NA, "")
  )
  expect_false(any(grepl("LASTMOD", out$code)))
})

test_that("lastmod_raw of the wrong length is an error", {
  expect_error(
    validate_protocol(
      rows_for(c("https://example.com/a", "https://example.com/b")),
      lastmod_raw = "2004-12-23"
    ),
    class = "sitemapr_protocol_input_error"
  )
})

# --- corpus-level lastmod heuristics ---------------------------------------

test_that("uniformly identical lastmods produce ALL_IDENTICAL (warning)", {
  t <- as.POSIXct("2024-01-01T00:00:00", tz = "UTC")
  out <- validate_protocol(
    sitemap_rows(
      loc = c("https://example.com/a", "https://example.com/b",
              "https://example.com/c"),
      lastmod = rep(t, 3L)
    ),
    sitemap_url = sm_url
  )
  ai <- out[out$code == "PROTOCOL_LASTMOD_ALL_IDENTICAL", ]
  expect_identical(nrow(ai), 1L)
  expect_identical(ai$severity, "warning")
  expect_identical(ai$subject_type, "document")
})

test_that("varied lastmods do not trip ALL_IDENTICAL", {
  out <- validate_protocol(
    sitemap_rows(
      loc = c("https://example.com/a", "https://example.com/b"),
      lastmod = as.POSIXct(c("2024-01-01", "2024-06-01"), tz = "UTC")
    ),
    sitemap_url = sm_url
  )
  expect_false("PROTOCOL_LASTMOD_ALL_IDENTICAL" %in% out$code)
})

test_that("a single dated entry is too small a corpus to flag", {
  out <- validate_protocol(
    sitemap_rows(
      loc = "https://example.com/a",
      lastmod = as.POSIXct("2024-01-01", tz = "UTC")
    ),
    sitemap_url = sm_url
  )
  expect_false("PROTOCOL_LASTMOD_ALL_IDENTICAL" %in% out$code)
})

test_that("lastmods clustered at fetch time produce LOOKS_GENERATED (info)", {
  fetched <- as.POSIXct("2024-01-01T12:00:00", tz = "UTC")
  out <- validate_protocol(
    sitemap_rows(
      loc = c("https://example.com/a", "https://example.com/b"),
      lastmod = c(fetched - 60, fetched - 120)
    ),
    sitemap_url = sm_url, fetched_at = fetched
  )
  lg <- out[out$code == "PROTOCOL_LASTMOD_LOOKS_GENERATED", ]
  expect_identical(nrow(lg), 1L)
  expect_identical(lg$severity, "info")
})

test_that("LOOKS_GENERATED is skipped without a fetch time", {
  fetched <- as.POSIXct("2024-01-01T12:00:00", tz = "UTC")
  out <- validate_protocol(
    sitemap_rows(
      loc = c("https://example.com/a", "https://example.com/b"),
      lastmod = c(fetched - 60, fetched - 120)
    ),
    sitemap_url = sm_url
  )
  expect_false("PROTOCOL_LASTMOD_LOOKS_GENERATED" %in% out$code)
})

test_that("lastmods far from fetch time do not look generated", {
  fetched <- as.POSIXct("2024-06-01T12:00:00", tz = "UTC")
  out <- validate_protocol(
    sitemap_rows(
      loc = c("https://example.com/a", "https://example.com/b"),
      lastmod = as.POSIXct(c("2020-01-01", "2021-01-01"), tz = "UTC")
    ),
    sitemap_url = sm_url, fetched_at = fetched
  )
  expect_false("PROTOCOL_LASTMOD_LOOKS_GENERATED" %in% out$code)
})

# --- combined shape + determinism ------------------------------------------

test_that("count, field, and corpus findings combine in one tibble", {
  t <- as.POSIXct("2024-01-01", tz = "UTC")
  rows <- sitemap_rows(
    loc = c("https://example.com/a", "https://example.com/b"),
    changefreq = c("daily", "sometimes"),
    priority = c(0.5, 2),
    lastmod = c(t, t)
  )
  out <- validate_protocol(
    rows, sitemap_url = sm_url, lastmod_raw = c("2024-01-01", "2024-01-01"),
    byte_size = 60 * 1024^2,
    limits = protocol_limits(max_url_count = 1L)
  )
  expect_setequal(
    out$code,
    c("PROTOCOL_URL_COUNT_EXCEEDED", "PROTOCOL_SIZE_EXCEEDED",
      "PROTOCOL_PRIORITY_OUT_OF_RANGE", "PROTOCOL_CHANGEFREQ_INVALID",
      "PROTOCOL_LASTMOD_DATE_ONLY", "PROTOCOL_LASTMOD_ALL_IDENTICAL")
  )
  expect_identical(unique(out$layer), "protocol")
})

test_that("D.2 rules are deterministic across repeated calls", {
  t <- as.POSIXct("2024-01-01", tz = "UTC")
  rows <- sitemap_rows(
    loc = c("https://example.com/a", "https://example.com/b"),
    changefreq = c("daily", "nope"),
    priority = c(0.5, 2),
    lastmod = c(t, t)
  )
  call <- function() {
    validate_protocol(
      rows, sitemap_url = sm_url, lastmod_raw = c("bad", "2024-01-01"),
      byte_size = 60 * 1024^2
    )
  }
  expect_identical(call(), call())
})
