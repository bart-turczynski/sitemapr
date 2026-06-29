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
    codes_for("ftp://example.com/x"),
    "PROTOCOL_URL_NOT_ABSOLUTE"
  )
  expect_identical(
    codes_for("data:text/plain,hi"),
    "PROTOCOL_URL_NOT_ABSOLUTE"
  )
})

test_that("a scheme-relative loc produces PROTOCOL_URL_NOT_ABSOLUTE", {
  expect_identical(
    codes_for("//example.com/x"),
    "PROTOCOL_URL_NOT_ABSOLUTE"
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

test_that("rows whose locs are all NA/empty yield no URL findings", {
  out <- validate_loc_urls(
    rows_for(c(NA_character_, "")),
    sitemap_url = NA_character_,
    base = base
  )
  expect_s3_class(out, "tbl_df")
  expect_identical(nrow(out), 0L)
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
    rows_for("https://example.com/a#section"),
    sitemap_url = sm_url
  )
  frag <- out[out$code == "PROTOCOL_URL_FRAGMENT", ]
  expect_identical(nrow(frag), 1L)
  expect_identical(frag$severity, "info")
})

test_that("userinfo produces an info PROTOCOL_URL_USERINFO", {
  out <- validate_protocol(
    rows_for("https://user@example.com/a"),
    sitemap_url = sm_url
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
    rows_for(c("https://example.com/a", "/relative")),
    sitemap_url = sm_url
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
    "https://example.com/a",
    "ftp://example.com/b",
    "https://other.com/c",
    "https://example.com/a#frag",
    "https://example.com/a"
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
    rows,
    sitemap_url = sm_url,
    limits = protocol_limits(max_url_count = 2L)
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
    rows,
    sitemap_url = sm_url,
    limits = protocol_limits(max_url_count = 2L)
  )
  expect_false("PROTOCOL_URL_COUNT_EXCEEDED" %in% out$code)
})

# --- Uncompressed size -----------------------------------------------------

test_that("an oversized document produces PROTOCOL_SIZE_EXCEEDED", {
  out <- validate_protocol(
    rows_for("https://example.com/a"),
    sitemap_url = sm_url,
    byte_size = 60 * 1024^2
  )
  sz <- out[out$code == "PROTOCOL_SIZE_EXCEEDED", ]
  expect_identical(nrow(sz), 1L)
  expect_identical(sz$severity, "error")
  expect_identical(sz$subject_type, "document")
})

test_that("size within the limit, or an unknown size, does not fire", {
  small <- validate_protocol(
    rows_for("https://example.com/a"),
    sitemap_url = sm_url,
    byte_size = 1024
  )
  unknown <- validate_protocol(
    rows_for("https://example.com/a"),
    sitemap_url = sm_url
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
      loc = c(
        "https://example.com/a",
        "https://example.com/b",
        "https://example.com/c"
      ),
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
  vals <- c("always", "hourly", "daily", "weekly", "monthly", "yearly", "never")
  out <- validate_protocol(
    sitemap_rows(
      loc = sprintf("https://example.com/p%d", seq_along(vals)),
      changefreq = vals
    ),
    sitemap_url = sm_url
  )
  expect_false("PROTOCOL_CHANGEFREQ_INVALID" %in% out$code)
})

# --- lastmod format (read from the faithful rows$lastmod column) -----------

# Build rows whose faithful `lastmod` column holds the given raw strings.
rows_with_lastmod <- function(loc, lastmod) {
  sitemap_rows(loc = loc, lastmod = lastmod)
}

test_that("a malformed lastmod produces PROTOCOL_LASTMOD_INVALID", {
  out <- validate_protocol(
    rows_with_lastmod(
      c("https://example.com/a", "https://example.com/b"),
      c("2004-12-23T18:00:15+00:00", "not-a-date")
    ),
    sitemap_url = sm_url
  )
  lm <- out[out$code == "PROTOCOL_LASTMOD_INVALID", ]
  expect_identical(nrow(lm), 1L)
  expect_identical(lm$severity, "error")
  expect_identical(lm$subject_ref, paste0(base, "#entry:2"))
})

test_that("a datetime lastmod without a timezone is invalid", {
  out <- validate_protocol(
    rows_with_lastmod("https://example.com/a", "2004-12-23T18:00:15"),
    sitemap_url = sm_url
  )
  expect_true("PROTOCOL_LASTMOD_INVALID" %in% out$code)
})

test_that("a date-only lastmod produces strict-only info DATE_ONLY", {
  out <- validate_protocol(
    rows_with_lastmod("https://example.com/a", "2004-12-23"),
    sitemap_url = sm_url
  )
  do <- out[out$code == "PROTOCOL_LASTMOD_DATE_ONLY", ]
  expect_identical(nrow(do), 1L)
  expect_identical(do$severity, "info")
  expect_true(do$is_strict_only)
  expect_false("PROTOCOL_LASTMOD_INVALID" %in% out$code)
})

test_that("a full datetime lastmod is clean and not flagged date-only", {
  out <- validate_protocol(
    rows_with_lastmod("https://example.com/a", "2004-12-23T18:00:15+00:00"),
    sitemap_url = sm_url
  )
  expect_false(any(grepl("LASTMOD", out$code, fixed = TRUE)))
})

test_that("an absent lastmod (NA in the faithful column) is not flagged", {
  out <- validate_protocol(
    rows_with_lastmod(
      c("https://example.com/a", "https://example.com/b"),
      c(NA_character_, NA_character_)
    ),
    sitemap_url = sm_url
  )
  expect_false(any(grepl("LASTMOD", out$code, fixed = TRUE)))
})

# --- corpus-level lastmod heuristics ---------------------------------------

test_that("uniformly identical lastmods produce ALL_IDENTICAL (warning)", {
  out <- validate_protocol(
    sitemap_rows(
      loc = c(
        "https://example.com/a",
        "https://example.com/b",
        "https://example.com/c"
      ),
      lastmod = rep("2024-01-01T00:00:00Z", 3L)
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
      lastmod = c("2024-01-01", "2024-06-01")
    ),
    sitemap_url = sm_url
  )
  expect_false("PROTOCOL_LASTMOD_ALL_IDENTICAL" %in% out$code)
})

test_that("a single dated entry is too small a corpus to flag", {
  out <- validate_protocol(
    sitemap_rows(
      loc = "https://example.com/a",
      lastmod = "2024-01-01"
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
      lastmod = c("2024-01-01T11:59:00Z", "2024-01-01T11:58:00Z")
    ),
    sitemap_url = sm_url,
    fetched_at = fetched
  )
  lg <- out[out$code == "PROTOCOL_LASTMOD_LOOKS_GENERATED", ]
  expect_identical(nrow(lg), 1L)
  expect_identical(lg$severity, "info")
})

test_that("LOOKS_GENERATED is skipped without a fetch time", {
  out <- validate_protocol(
    sitemap_rows(
      loc = c("https://example.com/a", "https://example.com/b"),
      lastmod = c("2024-01-01T11:59:00Z", "2024-01-01T11:58:00Z")
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
      lastmod = c("2020-01-01", "2021-01-01")
    ),
    sitemap_url = sm_url,
    fetched_at = fetched
  )
  expect_false("PROTOCOL_LASTMOD_LOOKS_GENERATED" %in% out$code)
})

# --- combined shape + determinism ------------------------------------------

test_that("count, field, and corpus findings combine in one tibble", {
  rows <- sitemap_rows(
    loc = c("https://example.com/a", "https://example.com/b"),
    changefreq = c("daily", "sometimes"),
    priority = c(0.5, 2),
    lastmod = c("2024-01-01", "2024-01-01")
  )
  out <- validate_protocol(
    rows,
    sitemap_url = sm_url,
    byte_size = 60 * 1024^2,
    limits = protocol_limits(max_url_count = 1L)
  )
  expect_setequal(
    out$code,
    c(
      "PROTOCOL_URL_COUNT_EXCEEDED",
      "PROTOCOL_SIZE_EXCEEDED",
      "PROTOCOL_PRIORITY_OUT_OF_RANGE",
      "PROTOCOL_CHANGEFREQ_INVALID",
      "PROTOCOL_LASTMOD_DATE_ONLY",
      "PROTOCOL_LASTMOD_ALL_IDENTICAL"
    )
  )
  expect_identical(unique(out$layer), "protocol")
})

test_that("D.2 rules are deterministic across repeated calls", {
  rows <- sitemap_rows(
    loc = c("https://example.com/a", "https://example.com/b"),
    changefreq = c("daily", "nope"),
    priority = c(0.5, 2),
    lastmod = c("bad", "2024-01-01")
  )
  call <- function() {
    validate_protocol(
      rows,
      sitemap_url = sm_url,
      byte_size = 60 * 1024^2
    )
  }
  expect_identical(call(), call())
})

# --- D.3 hreflang token policy ---------------------------------------------

# Build one as_list()-shaped <xhtml:link>: an empty list carrying the supplied
# attributes (NULL = attribute absent), matching collect_extension()'s output.
mk_link <- function(rel = "alternate", hreflang = NULL, href = NULL) {
  x <- list()
  if (!is.null(rel)) {
    attr(x, "rel") <- rel
  }
  if (!is.null(hreflang)) {
    attr(x, "hreflang") <- hreflang
  }
  if (!is.null(href)) {
    attr(x, "href") <- href
  }
  x
}

# A single-row tibble whose `alternates` column holds the given list of links.
rows_with_alts <- function(links, loc = "https://example.com/a") {
  sitemap_rows(loc = loc, alternates = list(links))
}

# Codes for one entry's alternates set.
hreflang_codes <- function(links) {
  validate_hreflang(rows_with_alts(links), base)$code
}

# A clean alternate-language link.
alt <- function(hreflang, href = paste0("https://example.com/", hreflang)) {
  mk_link(hreflang = hreflang, href = href)
}

# --- token classifier ------------------------------------------------------

test_that("the accepted hreflang families classify as valid", {
  for (tok in c("en", "en-US", "en-Latn", "zh-Hans-CN", "x-default")) {
    expect_identical(classify_hreflang_token(tok), {
      if (identical(tok, "x-default")) "valid-xdefault" else "valid"
    })
  }
})

test_that("empty and arbitrary tokens are FORMAT_INVALID", {
  for (tok in c("", "english", "123", "e", "eng")) {
    expect_identical(
      classify_hreflang_token(tok),
      "HREFLANG_FORMAT_INVALID"
    )
  }
})

test_that("a standalone uppercase 2-letter token reads as region-only", {
  expect_identical(classify_hreflang_token("US"), "HREFLANG_FORMAT_INVALID")
})

test_that("a lowercase standalone 2-letter token passes as a lang", {
  expect_identical(classify_hreflang_token("us"), "valid")
})

test_that("a whitespace-padded token is FORMAT_INVALID", {
  expect_identical(classify_hreflang_token(" en"), "HREFLANG_FORMAT_INVALID")
  expect_identical(classify_hreflang_token("en "), "HREFLANG_FORMAT_INVALID")
})

test_that("underscore and bad separators are SEPARATOR_INVALID", {
  for (tok in c("en_US", "en--US", "-en", "en-", "en US")) {
    expect_identical(
      classify_hreflang_token(tok),
      "HREFLANG_SEPARATOR_INVALID"
    )
  }
})

test_that("off-convention casing is NONSTANDARD_CASE", {
  # A standalone miscased lang must be mixed-case to read as a lang; an
  # all-uppercase standalone 2-letter is region-only (covered above).
  for (tok in c("En", "en-us", "EN-US", "en-latn", "en-LATN-US")) {
    expect_identical(
      classify_hreflang_token(tok),
      "HREFLANG_NONSTANDARD_CASE"
    )
  }
})

test_that("malformed x-default near misses are XDEFAULT_INVALID", {
  for (tok in c("X-DEFAULT", "x_default", "X_Default", " x-default")) {
    expect_identical(
      classify_hreflang_token(tok),
      "HREFLANG_XDEFAULT_INVALID"
    )
  }
})

test_that("multi-subtag tokens that fit no family are FORMAT_INVALID", {
  # Each exercises a distinct hreflang_roles() fall-through: a 2-part token
  # whose first subtag is not alpha2 ("xyz-US"); a 2-part token whose second
  # subtag is neither alpha2 nor alpha4 ("en-xyz"); a 3-part token that is not
  # lang-script-region ("en-US-XX", second subtag not alpha4).
  for (tok in c("xyz-US", "en-xyz", "en-US-XX")) {
    expect_identical(
      classify_hreflang_token(tok),
      "HREFLANG_FORMAT_INVALID"
    )
  }
})

# --- per-entry findings -----------------------------------------------------

test_that("a clean hreflang set with x-default produces no findings", {
  out <- validate_hreflang(
    rows_with_alts(list(alt("en"), alt("de"), alt("x-default"))),
    base
  )
  expect_identical(nrow(out), 0L)
})

test_that("an underscore-separated tag produces HREFLANG_FORMAT/SEPARATOR", {
  cc <- hreflang_codes(list(alt("en_US"), alt("x-default")))
  expect_true("HREFLANG_SEPARATOR_INVALID" %in% cc)
})

test_that("missing x-default with present alternates is flagged", {
  cc <- hreflang_codes(list(alt("en"), alt("de")))
  expect_true("HREFLANG_XDEFAULT_MISSING" %in% cc)
})

test_that("x-default present suppresses the missing finding", {
  cc <- hreflang_codes(list(alt("en"), alt("x-default")))
  expect_false("HREFLANG_XDEFAULT_MISSING" %in% cc)
})

test_that("a malformed x-default is not treated as missing", {
  cc <- hreflang_codes(list(alt("en"), alt("X-DEFAULT")))
  expect_true("HREFLANG_XDEFAULT_INVALID" %in% cc)
  expect_false("HREFLANG_XDEFAULT_MISSING" %in% cc)
})

test_that("a duplicate hreflang token is flagged once, naming the first", {
  out <- validate_hreflang(
    rows_with_alts(list(alt("en"), alt("en"), alt("x-default"))),
    base
  )
  dup <- out[out$code == "HREFLANG_DUPLICATE", ]
  expect_identical(nrow(dup), 1L)
  expect_match(dup$message, "link 1")
})

test_that("duplicate clean x-default is XDEFAULT_INVALID, not DUPLICATE", {
  out <- validate_hreflang(
    rows_with_alts(list(alt("en"), alt("x-default"), alt("x-default"))),
    base
  )
  expect_identical(
    out$code[out$code != "HREFLANG_XDEFAULT_MISSING"],
    "HREFLANG_XDEFAULT_INVALID"
  )
  expect_false("HREFLANG_DUPLICATE" %in% out$code)
})

test_that("a missing required attribute is HREFLANG_LINK_ATTR_INVALID", {
  expect_true(
    "HREFLANG_LINK_ATTR_INVALID" %in%
      hreflang_codes(list(mk_link(hreflang = "en"))) # no href
  )
  expect_true(
    "HREFLANG_LINK_ATTR_INVALID" %in%
      hreflang_codes(list(mk_link(rel = NULL, hreflang = "en", href = "/x")))
  )
  expect_true(
    "HREFLANG_LINK_ATTR_INVALID" %in%
      hreflang_codes(list(mk_link(
        rel = "stylesheet",
        hreflang = "en",
        href = "https://e.com/x"
      )))
  )
})

test_that("an absent hreflang attribute is named in the LINK_ATTR message", {
  out <- validate_hreflang(
    rows_with_alts(list(mk_link(rel = "alternate", href = "https://e.com/x"))),
    base
  )
  inv <- out[out$code == "HREFLANG_LINK_ATTR_INVALID", ]
  expect_identical(nrow(inv), 1L)
  expect_match(inv$message, "hreflang is absent")
})

test_that("a relative href is HREFLANG_HREF_RELATIVE and strict-only", {
  out <- validate_hreflang(
    rows_with_alts(list(
      mk_link(hreflang = "en", href = "/en"),
      alt("x-default")
    )),
    base
  )
  hr <- out[out$code == "HREFLANG_HREF_RELATIVE", ]
  expect_identical(nrow(hr), 1L)
  expect_identical(hr$severity, "warning")
  expect_true(hr$is_strict_only)
})

test_that("hreflang findings are scoped to the entry and link", {
  out <- validate_hreflang(
    rows_with_alts(list(alt("en"), alt("english"))),
    base
  )
  fmt <- out[out$code == "HREFLANG_FORMAT_INVALID", ]
  expect_identical(fmt$subject_ref, paste0(base, "#entry:1:link:2"))
  miss <- out[out$code == "HREFLANG_XDEFAULT_MISSING", ]
  expect_identical(miss$subject_ref, paste0(base, "#entry:1"))
})

test_that("hreflang evidence preserves the original off-case value", {
  out <- validate_hreflang(rows_with_alts(list(alt("en-us"))), base)
  case <- out[out$code == "HREFLANG_NONSTANDARD_CASE", ]
  expect_identical(case$evidence[[1]]$excerpt, "en-us")
})

test_that("rows without alternates produce no hreflang findings", {
  out <- validate_hreflang(
    sitemap_rows(loc = c("https://example.com/a", "https://example.com/b")),
    base
  )
  expect_identical(nrow(out), 0L)
})

test_that("hreflang findings carry the protocol layer and entry subject", {
  out <- validate_hreflang(rows_with_alts(list(alt("en"))), base)
  expect_identical(unique(out$layer), "protocol")
  expect_identical(unique(out$subject_type), "entry")
})

test_that("validate_protocol wires in the hreflang policy", {
  rows <- sitemap_rows(
    loc = "https://example.com/a",
    alternates = list(list(alt("en"), alt("en")))
  )
  out <- validate_protocol(rows, sitemap_url = sm_url)
  expect_true("HREFLANG_DUPLICATE" %in% out$code)
})

test_that("hreflang policy is deterministic across repeated calls", {
  rows <- rows_with_alts(
    list(alt("en"), alt("en_US"), mk_link(hreflang = "de"))
  )
  call <- function() validate_hreflang(rows, base)
  expect_identical(call(), call())
})

# --- D.4 extension field rules (image / video / news) ----------------------

# Build as_list()-shaped extension nodes: a leaf child is list("text"); an
# element is a (possibly repeat-named) named list of children; XML attributes
# are R attributes.
leaf <- function(text) list(as.character(text))
leaf_attr <- function(text, ...) {
  x <- leaf(text)
  a <- list(...)
  for (nm in names(a)) {
    attr(x, nm) <- a[[nm]]
  }
  x
}

test_that("ext_child_text is NA for an empty or non-character child", {
  expect_identical(ext_child_text(list(title = list()), "title"), NA_character_)
  expect_identical(
    ext_child_text(list(title = list(123L)), "title"),
    NA_character_
  )
})

test_that("ext_child_attr is NULL when the named child is absent", {
  expect_null(ext_child_attr(list(title = leaf("x")), "loc", "type"))
})

# A minimally-valid <video:video> element; override/add children via `...`.
# A flat (non-recursive) merge so leaf lists are replaced wholesale and repeated
# child names (e.g. several `tag`s) are preserved.
mk_video <- function(...) {
  base_children <- list(
    thumbnail_loc = leaf("https://e.com/t.jpg"),
    title = leaf("Title"),
    description = leaf("Desc"),
    content_loc = leaf("https://e.com/v.mp4")
  )
  overrides <- list(...)
  kept <- base_children[!names(base_children) %in% names(overrides)]
  c(kept, overrides)
}

# A minimally-valid <news:news> element; override via `...`.
mk_news <- function(language = "en", publication_date = "2024-01-01") {
  list(
    publication = list(name = leaf("Pub"), language = leaf(language)),
    publication_date = leaf(publication_date),
    title = leaf("Headline")
  )
}

# A one-row tibble with the given list of extension elements on `column`.
rows_with_ext <- function(column, els, loc = "https://example.com/a") {
  args <- list(loc = loc)
  args[[column]] <- list(els)
  do.call(sitemap_rows, args)
}

ext_codes <- function(column, els) {
  validate_extensions(rows_with_ext(column, els), base, protocol_limits())$code
}

# --- image ------------------------------------------------------------------

test_that("an image set within the per-URL cap produces no findings", {
  imgs <- rep(list(list(loc = leaf("https://e.com/i.jpg"))), 1000L)
  expect_identical(
    nrow(validate_extensions(
      rows_with_ext("images", imgs),
      base,
      protocol_limits()
    )),
    0L
  )
})

test_that("more than 1000 images per URL is PROTOCOL_IMAGE_COUNT_EXCEEDED", {
  imgs <- rep(list(list(loc = leaf("https://e.com/i.jpg"))), 1001L)
  out <- validate_extensions(
    rows_with_ext("images", imgs),
    base,
    protocol_limits()
  )
  expect_identical(out$code, "PROTOCOL_IMAGE_COUNT_EXCEEDED")
  expect_identical(out$subject_ref, paste0(base, "#entry:1"))
})

test_that("the image cap is configurable via limits", {
  imgs <- rep(list(list(loc = leaf("https://e.com/i.jpg"))), 3L)
  out <- validate_extensions(
    rows_with_ext("images", imgs),
    base,
    protocol_limits(max_images_per_url = 2L)
  )
  expect_identical(out$code, "PROTOCOL_IMAGE_COUNT_EXCEEDED")
})

# --- video ------------------------------------------------------------------

test_that("a clean video produces no findings", {
  expect_length(ext_codes("video", list(mk_video())), 0L)
})

test_that("an out-of-range or non-integer duration is flagged", {
  for (d in c("0", "40000", "40.5", "abc")) {
    cc <- ext_codes("video", list(mk_video(duration = leaf(d))))
    expect_identical(cc, "PROTOCOL_VIDEO_FIELD_INVALID")
  }
})

test_that("a valid duration at the bounds passes", {
  for (d in c("1", "28800")) {
    expect_length(ext_codes("video", list(mk_video(duration = leaf(d)))), 0L)
  }
})

test_that("an out-of-range rating is flagged", {
  for (r in c("6.0", "-1", "abc")) {
    expect_identical(
      ext_codes("video", list(mk_video(rating = leaf(r)))),
      "PROTOCOL_VIDEO_FIELD_INVALID"
    )
  }
})

test_that("more than 32 video tags is flagged and configurable", {
  tags <- stats::setNames(
    rep(list(leaf("t")), 33L),
    rep("tag", 33L)
  )
  v <- do.call(mk_video, tags)
  expect_identical(
    ext_codes("video", list(v)),
    "PROTOCOL_VIDEO_FIELD_INVALID"
  )
  out <- validate_extensions(
    rows_with_ext("video", list(v)),
    base,
    protocol_limits(max_video_tags = 50L)
  )
  expect_identical(nrow(out), 0L)
})

test_that("a too-long video description is flagged", {
  long <- paste(rep("x", 2049L), collapse = "")
  expect_identical(
    ext_codes("video", list(mk_video(description = leaf(long)))),
    "PROTOCOL_VIDEO_FIELD_INVALID"
  )
})

test_that("a bad enum-like video value is flagged, a good one passes", {
  expect_identical(
    ext_codes("video", list(mk_video(family_friendly = leaf("maybe")))),
    "PROTOCOL_VIDEO_FIELD_INVALID"
  )
  expect_length(
    ext_codes("video", list(mk_video(live = leaf("yes")))),
    0L
  )
})

test_that("restriction/platform need a valid relationship attribute", {
  expect_identical(
    ext_codes("video", list(mk_video(restriction = leaf("US")))),
    "PROTOCOL_VIDEO_FIELD_INVALID"
  )
  expect_length(
    ext_codes(
      "video",
      list(mk_video(
        restriction = leaf_attr("US", relationship = "allow")
      ))
    ),
    0L
  )
  expect_identical(
    ext_codes(
      "video",
      list(mk_video(
        platform = leaf_attr("web", relationship = "maybe")
      ))
    ),
    "PROTOCOL_VIDEO_FIELD_INVALID"
  )
})

test_that("multiple video violations yield multiple findings", {
  v <- mk_video(duration = leaf("0"), rating = leaf("9"))
  out <- validate_extensions(
    rows_with_ext("video", list(v)),
    base,
    protocol_limits()
  )
  expect_identical(nrow(out), 2L)
  expect_identical(unique(out$code), "PROTOCOL_VIDEO_FIELD_INVALID")
  expect_identical(out$subject_ref[1], paste0(base, "#entry:1:video:1"))
})

# --- news -------------------------------------------------------------------

test_that("a clean news element produces no findings", {
  expect_length(ext_codes("news", list(mk_news())), 0L)
})

test_that("valid news languages pass, invalid ones are flagged", {
  for (lang in c("en", "eng", "zh-cn", "zh-tw")) {
    expect_length(ext_codes("news", list(mk_news(language = lang))), 0L)
  }
  for (lang in c("english", "e", "EN")) {
    expect_identical(
      ext_codes("news", list(mk_news(language = lang))),
      "PROTOCOL_NEWS_FIELD_INVALID"
    )
  }
})

test_that("an invalid news publication_date is flagged", {
  expect_identical(
    ext_codes("news", list(mk_news(publication_date = "not-a-date"))),
    "PROTOCOL_NEWS_FIELD_INVALID"
  )
  expect_length(
    ext_codes(
      "news",
      list(
        mk_news(publication_date = "2024-01-01T12:00:00Z")
      )
    ),
    0L
  )
})

test_that("news field findings are scoped to the entry and member", {
  out <- validate_extensions(
    rows_with_ext("news", list(mk_news(language = "english"))),
    base,
    protocol_limits()
  )
  expect_identical(out$subject_ref, paste0(base, "#entry:1:news:1"))
})

test_that("more than 1000 news entries per file is a document finding", {
  # Spread 1001 news entries across two URLs to prove the count is per-file.
  rows <- sitemap_rows(
    loc = c("https://example.com/a", "https://example.com/b"),
    news = list(
      rep(list(mk_news()), 600L),
      rep(list(mk_news()), 401L)
    )
  )
  out <- validate_extensions(rows, base, protocol_limits())
  cc <- out[out$code == "PROTOCOL_NEWS_COUNT_EXCEEDED", ]
  expect_identical(nrow(cc), 1L)
  expect_identical(cc$subject_type, "document")
  expect_identical(cc$subject_ref, base)
})

# --- integration + determinism ---------------------------------------------

test_that("validate_protocol wires in the extension rules", {
  rows <- sitemap_rows(
    loc = "https://example.com/a",
    video = list(list(mk_video(duration = leaf("0"))))
  )
  out <- validate_protocol(rows, sitemap_url = sm_url)
  expect_true("PROTOCOL_VIDEO_FIELD_INVALID" %in% out$code)
})

test_that("rows without extension data produce no extension findings", {
  out <- validate_extensions(
    sitemap_rows(loc = c("https://example.com/a", "https://example.com/b")),
    base,
    protocol_limits()
  )
  expect_identical(nrow(out), 0L)
})

test_that("extension rules are deterministic across repeated calls", {
  rows <- sitemap_rows(
    loc = "https://example.com/a",
    video = list(list(mk_video(rating = leaf("9")))),
    news = list(list(mk_news(language = "english")))
  )
  call <- function() validate_extensions(rows, base, protocol_limits())
  expect_identical(call(), call())
})

# --- Text-sitemap rules (D.5) ----------------------------------------------

txt_codes <- function(text) validate_text_protocol(text, base)$code

test_that("a clean text sitemap produces no findings", {
  out <- validate_text_protocol(
    "https://example.com/a\nhttps://example.com/b",
    base
  )
  expect_s3_class(out, "tbl_df")
  expect_identical(nrow(out), 0L)
})

test_that("an empty document produces no findings", {
  expect_identical(nrow(validate_text_protocol("", base)), 0L)
})

test_that("LF, CRLF, and lone-CR all split lines", {
  for (sep in c("\n", "\r\n", "\r")) {
    text <- paste("https://example.com/a", "/relative", sep = sep)
    expect_identical(txt_codes(text), "PROTOCOL_URL_NOT_ABSOLUTE", info = sep)
  }
})

test_that("a relative line is PROTOCOL_URL_NOT_ABSOLUTE", {
  expect_identical(txt_codes("/page/one"), "PROTOCOL_URL_NOT_ABSOLUTE")
})

test_that("a non-http(s) scheme line is PROTOCOL_URL_NOT_ABSOLUTE", {
  expect_identical(
    txt_codes("ftp://example.com/x"),
    "PROTOCOL_URL_NOT_ABSOLUTE"
  )
})

test_that("an absolute line with no host is PROTOCOL_URL_NO_HOST", {
  expect_identical(txt_codes("http://"), "PROTOCOL_URL_NO_HOST")
})

test_that("a >2048-char URL is PROTOCOL_TEXT_URL_TOO_LONG (warning)", {
  long <- paste0("https://example.com/", strrep("a", 2048L))
  out <- validate_text_protocol(long, base)
  expect_identical(out$code, "PROTOCOL_TEXT_URL_TOO_LONG")
  expect_identical(out$severity, "warning")
})

test_that("the 2048-char boundary matches the XML rule (must be < 2048)", {
  # sitemaps.org: URLs must be *less than* 2048 chars, so 2048 is flagged and
  # 2047 passes (mirrors validate_loc_urls()' `>= 2048L`).
  at_limit <- paste0("https://example.com/", strrep("a", 2048L - 20L))
  expect_identical(nchar(at_limit), 2048L)
  expect_identical(txt_codes(at_limit), "PROTOCOL_TEXT_URL_TOO_LONG")

  under <- paste0("https://example.com/", strrep("a", 2047L - 20L))
  expect_identical(nchar(under), 2047L)
  expect_identical(nrow(validate_text_protocol(under, base)), 0L)
})

test_that("a blank line is a strict-only PROTOCOL_TEXT_BLANK_LINE info", {
  out <- validate_text_protocol(
    "https://example.com/a\n\nhttps://example.com/b",
    base
  )
  expect_identical(out$code, "PROTOCOL_TEXT_BLANK_LINE")
  expect_identical(out$severity, "info")
  expect_true(out$is_strict_only)
})

test_that("a whitespace-only line is also a blank line", {
  out <- validate_text_protocol("   \t  ", base)
  expect_identical(out$code, "PROTOCOL_TEXT_BLANK_LINE")
})

test_that("blank-line findings carry the 1-based line number", {
  out <- validate_text_protocol(
    "https://example.com/a\n\n\nhttps://example.com/b",
    base
  )
  lines <- vapply(out$evidence, function(e) e$line, integer(1))
  expect_identical(sort(lines), c(2L, 3L))
})

test_that("text findings are scoped to the line via #line:<n>", {
  out <- validate_text_protocol("/relative", base)
  expect_identical(out$subject_ref, paste0(base, "#line:1"))
  expect_identical(out$subject_type, "entry")
})

test_that("the too-long excerpt is clamped to 200 chars", {
  long <- paste0("https://example.com/", strrep("a", 4000L))
  out <- validate_text_protocol(long, base)
  expect_identical(nchar(out$evidence[[1]]$excerpt), 200L)
})

test_that("surrounding whitespace is trimmed before URL checks", {
  expect_identical(
    nrow(validate_text_protocol("  https://example.com/a  ", base)),
    0L
  )
})

test_that("multiple lines yield one finding each, in line order", {
  out <- validate_text_protocol(
    paste("/rel", "https://example.com/ok", "ftp://h/x", sep = "\n"),
    base
  )
  expect_identical(
    out$code,
    c("PROTOCOL_URL_NOT_ABSOLUTE", "PROTOCOL_URL_NOT_ABSOLUTE")
  )
})

test_that("raw bytes are accepted as input", {
  out <- validate_text_protocol(charToRaw("/relative"), base)
  expect_identical(out$code, "PROTOCOL_URL_NOT_ABSOLUTE")
})

test_that("a missing subject_ref yields a fragment-only ref", {
  out <- validate_text_protocol("/relative")
  expect_identical(out$subject_ref, "#line:1")
})

test_that("text validation is deterministic across repeated calls", {
  text <- "https://example.com/a\n\n/rel\nhttp://"
  call <- function() validate_text_protocol(text, base)
  expect_identical(call(), call())
})

# --- D.6 classification diagnostics: unsupported input ---------------------

test_that("an unsupported root yields a classification UNSUPPORTED_ROOT", {
  out <- validate_protocol(
    empty_sitemap_rows(),
    subject_ref = base,
    source_meta = source_meta(unsupported_root = "rss")
  )
  ur <- out[out$code == "UNSUPPORTED_ROOT", ]
  expect_identical(nrow(ur), 1L)
  expect_identical(ur$layer, "classification")
  expect_identical(ur$severity, "error")
  expect_identical(ur$subject_type, "source")
  expect_identical(ur$subject_ref, base)
  expect_match(ur$message, "<rss>")
})

test_that("HTML at a sitemap URL yields UNSUPPORTED_HTML_MASQUERADE", {
  out <- validate_protocol(
    empty_sitemap_rows(),
    subject_ref = base,
    source_meta = source_meta(html_masquerade = TRUE)
  )
  hm <- out[out$code == "UNSUPPORTED_HTML_MASQUERADE", ]
  expect_identical(nrow(hm), 1L)
  expect_identical(hm$layer, "classification")
  expect_identical(hm$severity, "error")
})

test_that("feed children each yield an index-child UNSUPPORTED_FEED", {
  children <- c("https://example.com/feed.xml", "https://example.com/atom")
  out <- validate_protocol(
    empty_sitemap_rows(),
    subject_ref = base,
    source_meta = source_meta(feed_children = children)
  )
  uf <- out[out$code == "UNSUPPORTED_FEED", ]
  expect_identical(nrow(uf), 2L)
  expect_true(all(uf$subject_type == "index-child"))
  expect_identical(
    uf$subject_ref,
    paste0(base, "#index-child:", children)
  )
})

test_that("diagnostics are produced even with no rows", {
  out <- validate_protocol(
    empty_sitemap_rows(),
    subject_ref = base,
    source_meta = source_meta(unsupported_root = "feed")
  )
  expect_identical(out$code, "UNSUPPORTED_ROOT")
})

test_that("no source_meta yields no classification diagnostics", {
  out <- validate_protocol(rows_for("https://example.com/a"))
  expect_false(any(out$layer == "classification"))
  expect_false(any(grepl("^UNSUPPORTED_|^ENCODING_", out$code)))
})

test_that("an all-default source_meta yields no diagnostics", {
  out <- validate_protocol(
    empty_sitemap_rows(),
    subject_ref = base,
    source_meta = source_meta()
  )
  expect_identical(nrow(out), 0L)
})

test_that("diagnostics co-exist with protocol findings over real rows", {
  out <- validate_protocol(
    sitemap_rows(loc = "https://example.com/a", changefreq = "fortnightly"),
    subject_ref = base,
    source_meta = source_meta(
      bom_encoding = "UTF-8",
      declared_encoding = "UTF-16"
    )
  )
  expect_true("PROTOCOL_CHANGEFREQ_INVALID" %in% out$code)
  expect_true("ENCODING_BOM_DECLARATION_CONFLICT" %in% out$code)
  expect_setequal(out$layer, c("protocol", "classification"))
})

# --- D.6 classification diagnostics: encoding conflicts --------------------

test_that("BOM vs XML declaration is the specialised conflict (info)", {
  out <- validate_encoding(
    source_meta(bom_encoding = "UTF-8", declared_encoding = "UTF-16"),
    base
  )
  expect_identical(out$code, "ENCODING_BOM_DECLARATION_CONFLICT")
  expect_identical(out$severity, "info")
  expect_false(out$is_strict_only)
  expect_identical(out$layer, "classification")
})

test_that("an HTTP-charset disagreement is the general ENCODING_CONFLICT", {
  out <- validate_encoding(
    source_meta(declared_encoding = "UTF-8", http_charset = "ISO-8859-1"),
    base
  )
  expect_identical(out$code, "ENCODING_CONFLICT")
  expect_identical(out$severity, "info")
})

test_that("a three-way mismatch emits both encoding findings", {
  out <- validate_encoding(
    source_meta(
      bom_encoding = "UTF-16",
      declared_encoding = "UTF-8",
      http_charset = "UTF-8"
    ),
    base
  )
  expect_setequal(
    out$code,
    c("ENCODING_BOM_DECLARATION_CONFLICT", "ENCODING_CONFLICT")
  )
})

test_that("equivalent encoding spellings do not conflict", {
  out <- validate_encoding(
    source_meta(
      bom_encoding = "UTF-8",
      declared_encoding = "utf8",
      http_charset = "utf-8"
    ),
    base
  )
  expect_identical(nrow(out), 0L)
})

test_that("a single encoding signal never conflicts", {
  out <- validate_encoding(source_meta(declared_encoding = "UTF-8"), base)
  expect_identical(nrow(out), 0L)
})

test_that("NULL source_meta producers return empty classification findings", {
  expect_identical(nrow(validate_classification(NULL, base)), 0L)
  expect_identical(nrow(validate_encoding(NULL, base)), 0L)
})

test_that("HTTP charset alone resolves encoding without a conflict", {
  # bom + declaration both absent: resolution falls through to the HTTP-charset
  # branch and, with a single signal, emits no finding.
  out <- validate_encoding(source_meta(http_charset = "UTF-8"), base)
  expect_identical(nrow(out), 0L)
})

test_that("NA / empty feed children are skipped", {
  out <- validate_classification(
    source_meta(feed_children = c(NA_character_, "")),
    base
  )
  expect_identical(nrow(out), 0L)
})

test_that("encoding normalisation helpers handle absent input", {
  # norm_encoding maps missing input to NA; encoding_signal_label renders it as
  # the literal "absent" for diagnostic messages.
  expect_true(is.na(norm_encoding(NULL)))
  expect_true(is.na(norm_encoding(character(0))))
  expect_identical(encoding_signal_label(NULL), "absent")
  expect_identical(encoding_signal_label(character(0)), "absent")
})

test_that("classification diagnostics are deterministic across calls", {
  meta <- source_meta(
    unsupported_root = "rss",
    feed_children = c("https://example.com/a", "https://example.com/b"),
    bom_encoding = "UTF-8",
    declared_encoding = "UTF-16"
  )
  call <- function() {
    validate_protocol(
      empty_sitemap_rows(),
      subject_ref = base,
      source_meta = meta
    )
  }
  expect_identical(call(), call())
})
