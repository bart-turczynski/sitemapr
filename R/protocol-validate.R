# Protocol/semantic validation, Layer D finding-producer (architecture.md §3,
# §7; docs/sitemap-spec.md §4). Internal only.
#
# `validate_protocol()` takes the parsed row tibble (R/parse-rows.R) plus the
# sitemap's own URL and returns protocol findings (`layer = "protocol"`) in the
# docs/findings-contract.md shape. Like the schema layer it produces stable,
# scoped rows but does NOT assemble the final tibble: the `mode` column,
# strict/non-strict severity adjustment + filtering, de-duplication, and the
# final sort are all Layer F's job (SITE-ymzvnlpr); they are deliberately not
# done here. The rows emitted here carry: code, severity, layer, subject_type,
# subject_ref, message, evidence, and is_strict_only.
#
# This file covers the SITE-fraetonj (D.1), SITE-ysviepus (D.2),
# SITE-nmbmgmba (D.3), SITE-fwdqovyp (D.4), and SITE-htmkvrmo (D.5) slices: the
# findings constructor, the per-`<loc>` URL rules, the count/field-value rules,
# the hreflang token policy, the image/video/news extension field rules, and the
# text-sitemap per-line rules. The D.6 slice (SITE-jlpihcap) adds the
# `source_meta` argument to `validate_protocol()` and surfaces the
# unsupported-input + encoding diagnostics, whose producers live in
# R/classification-validate.R because they carry `layer = "classification"`
# rather than `"protocol"` (findings-contract.md layer vocabulary).
#
# Text sitemaps take a DEDICATED path (sitemap-spec.md §7.2; SPEC §18), never
# the XML rows path: `validate_text_protocol()` reads the RAW document text, not
# the parsed rows, because the row tibble has already dropped blank lines and
# line numbers (R/parse-text.R). It is a standalone producer parallel to
# `validate_protocol()`; the Layer F assembler routes text sources to it.
#
# The extension rules (D.4) read the `images`/`video`/`news` list-columns,
# whose entries are `xml2::as_list()` conversions of the extension elements
# (child text in `[[1]]`, repeated children as repeated names, XML attributes as
# R attributes). Only the value/cap rules XSD cannot express are checked here:
# per-`<url>` image count, per-file news count, the bounded `<video:*>`
# optionals (duration/rating/tag-count/description/enums/relationship), and the
# `<news:language>`/`<news:publication_date>` value formats. Required-child
# presence and structural one-of constraints remain the schema layer's job.
#
# The hreflang policy (D.3) is sitemap-specific, NOT generic
# BCP-47/`xs:language` (PRD §17; sitemap-spec.md §5.4): it accepts only `lang`,
# `lang-REGION`, `lang-Script`, `lang-Script-REGION`, and `x-default`, where
# `lang` is ISO 639-1 (2 alpha), `REGION` ISO 3166-1 alpha-2 (2 alpha), and
# `Script` ISO 15924 (4 alpha). No IANA registry snapshot is shipped, so the
# subtags are matched by alpha-length and position, not against a code list;
# casing (lang lowercase, Script Title-case, REGION UPPERCASE, `x-default`
# exactly lowercase) is checked for reporting but the ORIGINAL value is always
# preserved in evidence. The schema layer (XSD) owns structural failures of an
# `xhtml:link` under the generic `SCHEMA_INVALID` code; the eight `HREFLANG_*`
# codes here are purely semantic.
#
# Field-value rules (D.2) read the FAITHFUL row tibble (ADR-004): `lastmod` and
# `priority` arrive as the raw `<lastmod>`/`<priority>` strings, so the original
# text is available where format matters. `priority` is validated against
# `[0.0, 1.0]` by parsing the raw string to numeric once (the parser
# deliberately passes out-of-range values through); `changefreq` against its
# enum on the character column. `lastmod` format is classified directly from the
# raw column (`classify_lastmod()`), distinguishing malformed and date-only
# values that a POSIXct coercion would have collapsed; the corpus heuristics
# parse the raw column to POSIXct once internally. The uncompressed `byte_size`
# and the `fetched_at` time are external to the rows and gate
# `PROTOCOL_SIZE_EXCEEDED` and `PROTOCOL_LASTMOD_LOOKS_GENERATED` respectively.
#
# URL handling follows the sitemap spec exactly and never reshapes a URL's
# meaning. A `<loc>` is validated as: absolute `http`/`https`, host present,
# RFC 3986/3987, shorter than 2048 chars, in the sitemap's scope, and with valid
# percent-escaping. Duplicate detection keys on sitemapr's full-URL identity key
# (`build_loc_key()`: keeps query, collapses the scheme's default port, drops
# the fragment) and NEVER on `rurl::clean_url`/`get_clean_url`, which discard
# the meaningful query/port that distinguish two sitemap entries. IRIs are
# accepted and compared in their percent-encoded URI form (the RFC 3987 -> 3986
# mapping is done once in `parse_url_adapter()` via `path_encoding = "encode"`).

# Construct the protocol-layer findings tibble. The single source of truth for
# the columns this producer emits (a contract-shaped subset; `mode` and
# `remediation_hint` are added by Layer F). Each `evidence` entry is the named
# list `list(excerpt, line, column)` from the findings contract.
protocol_findings <- function(
  code = character(0),
  severity = character(0),
  subject_type = character(0),
  subject_ref = character(0),
  message = character(0),
  evidence = list(),
  is_strict_only = logical(0)
) {
  n <- length(code)
  tibble::tibble(
    code = as.character(code),
    severity = as.character(severity),
    layer = rep("protocol", n),
    subject_type = as.character(subject_type),
    subject_ref = as.character(subject_ref),
    message = as.character(message),
    evidence = if (length(evidence) > 0L) evidence else vector("list", n),
    is_strict_only = as.logical(is_strict_only)
  )
}

# A zero-row protocol-findings tibble (a fully conformant document).
empty_protocol_findings <- function() {
  protocol_findings()
}

# Append a fragment to a subject_ref base, tolerating an absent base.
protocol_ref_fragment <- function(base, fragment) {
  if (is.null(base) || is.na(base) || !nzchar(base)) {
    return(fragment)
  }
  paste0(base, fragment)
}

# The document-level subject_ref base for a sitemap URL: `sitemap://` + the URL
# with its scheme stripped (the findings-contract authority form, e.g.
# `sitemap://example.com/sitemap.xml`). `NA` in -> `NA` out (fragment-only ref).
sitemap_subject_ref <- function(sitemap_url) {
  if (is.null(sitemap_url) || is.na(sitemap_url) || !nzchar(sitemap_url)) {
    return(NA_character_)
  }
  paste0("sitemap://", sub("^[A-Za-z][A-Za-z0-9+.-]*://", "", sitemap_url))
}

# Classify a raw `<loc>` string's absoluteness from the ORIGINAL text, never the
# parsed scheme: `rurl` synthesises an `http` scheme for a relative input
# (`/page` parses as host `page`), so absoluteness can only be read off the
# original string. Returns "http(s)" (absolute and fetchable), "other-scheme"
# (an absolute URI with a non-http(s) scheme such as `ftp:`/`data:`/`mailto:`),
# or "relative" (no scheme, or a scheme-relative `//host/...`).
loc_absoluteness <- function(loc) {
  out <- rep("relative", length(loc))
  has_scheme <- grepl("^[A-Za-z][A-Za-z0-9+.-]*:", loc)
  is_httpish <- grepl("^https?://", loc, ignore.case = TRUE)
  out[has_scheme] <- "other-scheme"
  out[is_httpish] <- "http(s)"
  out
}

# An invalid percent-escape is a `%` not followed by two hex digits (RFC 3986
# §2.1). A well-escaped `%XX` and a literal-free URL are both clean.
has_invalid_escape <- function(loc) {
  grepl("%(?![0-9A-Fa-f]{2})", loc, perl = TRUE)
}

# The scheme+host+port authority of a parsed row, with the scheme's default port
# collapsed (matching build_loc_key()), used for same-origin scope comparison.
loc_authority <- function(parsed) {
  scheme <- as.character(parsed$scheme)
  host <- as.character(parsed$host)
  port <- parsed$port
  is_default <- (scheme == "http" & port == 80L) |
    (scheme == "https" & port == 443L)
  drop_port <- is.na(port) | (!is.na(is_default) & is_default)
  paste0(scheme, "://", host, ifelse(drop_port, "", paste0(":", port)))
}

# The sitemap's own directory prefix: its path up to and including the last `/`.
# `/a/sitemap.xml` -> `/a/`; `/sitemap.xml` -> `/`; empty -> `/`.
loc_directory_prefix <- function(path) {
  path <- as.character(path)
  path[is.na(path) | !nzchar(path)] <- "/"
  sub("[^/]*$", "", path)
}

# Build one URL-rule finding row for entry `i`.
protocol_url_finding <- function(
  code,
  severity,
  subject_type,
  base,
  i,
  loc,
  message,
  is_strict_only = FALSE
) {
  protocol_findings(
    code = code,
    severity = severity,
    subject_type = subject_type,
    subject_ref = protocol_ref_fragment(base, paste0("#entry:", i)),
    message = message,
    evidence = list(finding_evidence(excerpt = loc)),
    is_strict_only = is_strict_only
  )
}

# One document-level finding row (`subject_type = "document"`, the unfragmented
# `sitemap://…` base). Used by the count/size and corpus-level lastmod rules.
protocol_document_finding <- function(
  code,
  severity,
  base,
  message,
  excerpt = NA_character_,
  is_strict_only = FALSE
) {
  protocol_findings(
    code = code,
    severity = severity,
    subject_type = "document",
    subject_ref = if (is.null(base)) NA_character_ else base,
    message = message,
    evidence = list(finding_evidence(excerpt = excerpt)),
    is_strict_only = is_strict_only
  )
}

# The `<changefreq>` enumeration (sitemaps.org Protocol 0.9). Case-sensitive,
# matching the XSD enumeration; a wrong-case value (`Daily`) is invalid.
protocol_changefreq_values <- c(
  "always",
  "hourly",
  "daily",
  "weekly",
  "monthly",
  "yearly",
  "never"
)

# Layer D limit thresholds. Each resolves from its argument, then the matching
# `getOption("sitemapr.*")`, then the sitemaps.org protocol default. All limits
# are configurable; none is hardcoded (sitemap-spec.md §2, ADR-003 §3).
protocol_limits <- function(
  max_url_count = getOption("sitemapr.max_url_count", 50000L),
  max_uncompressed_bytes = getOption(
    "sitemapr.max_uncompressed_bytes",
    52428800L
  ),
  lastmod_identical_ratio = getOption(
    "sitemapr.lastmod_identical_ratio",
    1
  ),
  lastmod_generated_tolerance = getOption(
    "sitemapr.lastmod_generated_tolerance",
    86400
  ),
  max_images_per_url = getOption("sitemapr.max_images_per_url", 1000L),
  max_news_per_file = getOption("sitemapr.max_news_per_file", 1000L),
  max_video_tags = getOption("sitemapr.max_video_tags", 32L)
) {
  list(
    max_url_count = as.integer(max_url_count),
    max_uncompressed_bytes = as.numeric(max_uncompressed_bytes),
    lastmod_identical_ratio = as.numeric(lastmod_identical_ratio),
    lastmod_generated_tolerance = as.numeric(lastmod_generated_tolerance),
    max_images_per_url = as.integer(max_images_per_url),
    max_news_per_file = as.integer(max_news_per_file),
    max_video_tags = as.integer(max_video_tags)
  )
}

# Classify each ORIGINAL `<lastmod>` string into "absent", "invalid",
# "date-only", or "datetime". Reuses parse_lastmod() (R/parse-xml.R) for the
# valid/invalid split so the parser and this validator can never diverge: a
# value the parser turns into NA is exactly an invalid value here, and the
# date-only form is the one the parser accepts as a bare `YYYY-MM-DD`.
classify_lastmod <- function(raw) {
  raw <- as.character(raw)
  trimmed <- trimws(raw)
  out <- rep("absent", length(raw))
  present <- !is.na(trimmed) & nzchar(trimmed)
  if (!any(present)) {
    return(out)
  }
  parsed <- parse_lastmod(raw[present])
  is_date <- grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", trimmed[present])
  cls <- rep("datetime", length(parsed))
  cls[is.na(parsed)] <- "invalid"
  cls[!is.na(parsed) & is_date] <- "date-only"
  out[present] <- cls
  out
}

# Document-level URL-count rule. More than `limit` URL entries is a non-fatal
# protocol violation (reading continues; sitemap-spec.md §2 Axis 2).
validate_url_count <- function(rows, base, limit) {
  n <- nrow(rows)
  if (is.na(limit) || n <= limit) {
    return(empty_protocol_findings())
  }
  protocol_document_finding(
    "PROTOCOL_URL_COUNT_EXCEEDED",
    "error",
    base,
    sprintf(
      "Sitemap has %d URL entries; the protocol limit is %d.",
      n,
      limit
    )
  )
}

# Document-level uncompressed-size rule. `byte_size` is the uncompressed byte
# count of the source document (NA skips the check). Over `limit` is a non-fatal
# protocol violation; the body is still read (sitemap-spec.md §2 Axis 1).
validate_doc_size <- function(byte_size, base, limit) {
  if (is.na(byte_size) || is.na(limit) || byte_size <= limit) {
    return(empty_protocol_findings())
  }
  protocol_document_finding(
    "PROTOCOL_SIZE_EXCEEDED",
    "error",
    base,
    sprintf(
      "Sitemap is %.0f bytes uncompressed; the protocol limit is %.0f.",
      byte_size,
      limit
    )
  )
}

# Per-entry field-value rules: priority range, changefreq enum, and lastmod
# format. Reads the FAITHFUL row tibble (ADR-004): `lastmod` and `priority` are
# the raw `<lastmod>`/`<priority>` strings. Returns a (possibly empty)
# protocol-findings tibble.
validate_field_values <- function(rows, base) {
  out <- list()

  pri <- suppressWarnings(as.numeric(rows$priority))
  bad_pri <- which(!is.na(pri) & (pri < 0 | pri > 1))
  for (j in bad_pri) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_PRIORITY_OUT_OF_RANGE",
      "error",
      "entry",
      base,
      j,
      trimws(as.character(rows$priority[j])),
      sprintf(
        "<priority> %s is outside the permitted range [0.0, 1.0].",
        trimws(as.character(rows$priority[j]))
      )
    )
  }

  cf <- rows$changefreq
  bad_cf <- which(!is.na(cf) & !(cf %in% protocol_changefreq_values))
  for (j in bad_cf) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_CHANGEFREQ_INVALID",
      "error",
      "entry",
      base,
      j,
      cf[j],
      sprintf(
        "<changefreq> '%s' is not one of: %s.",
        cf[j],
        paste(protocol_changefreq_values, collapse = ", ")
      )
    )
  }

  lm <- rows$lastmod
  cls <- classify_lastmod(lm)
  for (j in which(cls == "invalid")) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_LASTMOD_INVALID",
      "error",
      "entry",
      base,
      j,
      as.character(lm[j]),
      sprintf(
        "<lastmod> '%s' is not a valid W3C Date-Time value.",
        trimws(as.character(lm[j]))
      )
    )
  }
  for (j in which(cls == "date-only")) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_LASTMOD_DATE_ONLY",
      "info",
      "entry",
      base,
      j,
      as.character(lm[j]),
      sprintf(
        "<lastmod> '%s' is date-only; including a time is recommended.",
        trimws(as.character(lm[j]))
      ),
      is_strict_only = TRUE
    )
  }

  if (length(out) == 0L) {
    return(empty_protocol_findings())
  }
  do.call(rbind, out)
}

# Corpus-level lastmod-honesty heuristics (sitemap-spec.md §4.1). These scan
# ALL dated entries of one sitemap, so they are document-level, not per-entry.
# `fetched_at` is the sitemap's fetch/generation time (NA skips the
# looks-generated heuristic). The raw `lastmod` column is parsed to POSIXct once
# here (parse-once, use-late; ADR-004).
validate_lastmod_corpus <- function(rows, base, fetched_at, limits) {
  lastmod <- parse_lastmod(rows$lastmod)
  dated <- lastmod[!is.na(lastmod)]
  out <- list()
  if (length(dated) < 2L) {
    return(empty_protocol_findings())
  }

  counts <- table(as.numeric(dated))
  modal_ratio <- max(counts) / length(dated)

  if (modal_ratio >= limits$lastmod_identical_ratio) {
    out[[length(out) + 1L]] <- protocol_document_finding(
      "PROTOCOL_LASTMOD_ALL_IDENTICAL",
      "warning",
      base,
      sprintf(
        paste0(
          "%d of %d dated entries share one <lastmod> value; engines may ",
          "distrust uniformly identical dates."
        ),
        max(counts),
        length(dated)
      )
    )
  }

  if (!is.na(fetched_at)) {
    near <- abs(as.numeric(dated) - as.numeric(fetched_at)) <=
      limits$lastmod_generated_tolerance
    if (mean(near) >= limits$lastmod_identical_ratio) {
      out[[length(out) + 1L]] <- protocol_document_finding(
        "PROTOCOL_LASTMOD_LOOKS_GENERATED",
        "info",
        base,
        sprintf(
          paste0(
            "%d of %d dated entries fall within %.0fs of the sitemap's ",
            "fetch time; <lastmod> looks auto-generated, not content-derived."
          ),
          sum(near),
          length(dated),
          limits$lastmod_generated_tolerance
        )
      )
    }
  }

  if (length(out) == 0L) {
    return(empty_protocol_findings())
  }
  do.call(rbind, out)
}

# --- Extension field rules (D.4): image / video / news ---------------------

# Fixed value ranges for the bounded `<video:*>` optionals (sitemap-spec.md
# §5.3). These are value constraints, not size limits (cf. the priority range
# and changefreq enum), so unlike the per-extension count caps in
# `protocol_limits()` they are not configurable.
protocol_video_duration_range <- c(1L, 28800L)
protocol_video_rating_range <- c(0, 5)
protocol_video_description_max <- 2048L
protocol_video_bool_values <- c("yes", "no")
protocol_video_rel_values <- c("allow", "deny")

# `<news:language>` exceptions: the two region-qualified codes Google accepts in
# addition to the bare ISO 639 2-/3-letter codes (sitemap-spec.md §5.2).
protocol_news_lang_exceptions <- c("zh-cn", "zh-tw")

# Read the trimmed text of an extension element's first `name` child, or `NA`
# when the child is absent or empty. Children of an `as_list()` element are
# named list members (namespace prefix stripped); a leaf's text sits in `[[1]]`.
ext_child_text <- function(el, name) {
  idx <- which(names(el) == name)
  if (length(idx) == 0L) {
    return(NA_character_)
  }
  child <- el[[idx[1]]]
  if (length(child) == 0L || !is.character(child[[1]])) {
    return(NA_character_)
  }
  trimws(child[[1]])
}

# How many `name` children the element has (repeated elements repeat the name).
ext_child_count <- function(el, name) sum(names(el) == name)

# TRUE when the element has at least one `name` child.
ext_has_child <- function(el, name) any(names(el) == name)

# An attribute of the element's first `name` child, or `NULL` when absent.
ext_child_attr <- function(el, name, attrname) {
  idx <- which(names(el) == name)
  if (length(idx) == 0L) {
    return(NULL)
  }
  attr(el[[idx[1]]], attrname, exact = TRUE)
}

# One extension field/count finding scoped to a member of an entry (ref
# `…#entry:i:kind:m`, e.g. `…#entry:3:video:1`).
protocol_ext_finding <- function(
  code,
  base,
  i,
  kind,
  m,
  message,
  excerpt = NA_character_
) {
  protocol_findings(
    code = code,
    severity = "error",
    subject_type = "entry",
    subject_ref = protocol_ref_fragment(
      base,
      sprintf("#entry:%d:%s:%d", i, kind, m)
    ),
    message = message,
    evidence = list(finding_evidence(excerpt = excerpt)),
    is_strict_only = FALSE
  )
}

# `<news:language>` is valid when it is a bare ISO 639 2-/3-letter code or one
# of the region-qualified exceptions. (Case-sensitive: Google emits lowercase.)
news_language_ok <- function(lang) {
  grepl("^[a-z]{2,3}$", lang) || lang %in% protocol_news_lang_exceptions
}

# Value-rule violations for one `<news:news>` element, as a character vector of
# messages (empty = clean). Required-child presence is the schema layer's job;
# here only the value formats XSD cannot express are checked.
validate_news_element <- function(n) {
  msgs <- character(0)

  pub_idx <- which(names(n) == "publication")
  if (length(pub_idx) > 0L) {
    lang <- ext_child_text(n[[pub_idx[1]]], "language")
    if (!is.na(lang) && !news_language_ok(lang)) {
      msgs <- c(
        msgs,
        sprintf(
          "<news:language> '%s' is not a valid ISO 639 language code.",
          lang
        )
      )
    }
  }

  pdate <- ext_child_text(n, "publication_date")
  if (!is.na(pdate) && is.na(parse_lastmod(pdate))) {
    msgs <- c(
      msgs,
      sprintf(
        "<news:publication_date> '%s' is not a valid W3C date-time value.",
        pdate
      )
    )
  }

  msgs
}

# Value-rule violations for one `<video:video>` element, as a character vector
# of messages (empty = clean). Covers the bounded optionals (sitemap-spec.md
# §5.3); required-child presence and the content_loc/player_loc one-of rule
# are structural and left to the schema layer.
# `<video:duration>` must be an integer within the protocol range.
video_duration_msgs <- function(v) {
  dur <- ext_child_text(v, "duration")
  if (is.na(dur)) {
    return(character(0))
  }
  d <- suppressWarnings(as.numeric(dur))
  rng <- protocol_video_duration_range
  if (is.na(d) || d != round(d) || d < rng[1] || d > rng[2]) {
    return(sprintf(
      "<video:duration> '%s' must be an integer between %d and %d seconds.",
      dur,
      rng[1],
      rng[2]
    ))
  }
  character(0)
}

# `<video:rating>` must be a number within the protocol range.
video_rating_msgs <- function(v) {
  rat <- ext_child_text(v, "rating")
  if (is.na(rat)) {
    return(character(0))
  }
  r <- suppressWarnings(as.numeric(rat))
  rng <- protocol_video_rating_range
  if (is.na(r) || r < rng[1] || r > rng[2]) {
    return(sprintf(
      "<video:rating> '%s' must be a number between %.1f and %.1f.",
      rat,
      rng[1],
      rng[2]
    ))
  }
  character(0)
}

# Per-video `<video:tag>` count cap.
video_tag_count_msgs <- function(v, max_tags) {
  ntag <- ext_child_count(v, "tag")
  if (ntag > max_tags) {
    return(sprintf(
      "<video:tag> count %d exceeds the limit of %d per video.",
      ntag,
      max_tags
    ))
  }
  character(0)
}

# `<video:description>` length cap.
video_description_msgs <- function(v) {
  desc <- ext_child_text(v, "description")
  if (!is.na(desc) && nchar(desc) > protocol_video_description_max) {
    return(sprintf(
      "<video:description> is %d characters; the limit is %d.",
      nchar(desc),
      protocol_video_description_max
    ))
  }
  character(0)
}

# yes/no enum fields: family_friendly, requires_subscription, live.
video_enum_msgs <- function(v) {
  msgs <- character(0)
  for (enum in c("family_friendly", "requires_subscription", "live")) {
    val <- ext_child_text(v, enum)
    if (!is.na(val) && !val %in% protocol_video_bool_values) {
      msgs <- c(
        msgs,
        sprintf("<video:%s> '%s' must be 'yes' or 'no'.", enum, val)
      )
    }
  }
  msgs
}

# restriction/platform require a relationship="allow"|"deny" attribute.
video_relationship_msgs <- function(v) {
  msgs <- character(0)
  for (rel in c("restriction", "platform")) {
    if (ext_has_child(v, rel)) {
      a <- ext_child_attr(v, rel, "relationship")
      if (is.null(a) || !as.character(a) %in% protocol_video_rel_values) {
        msgs <- c(
          msgs,
          sprintf(
            '<video:%s> requires a relationship="allow" or "deny" attribute.',
            rel
          )
        )
      }
    }
  }
  msgs
}

validate_video_element <- function(v, max_tags) {
  c(
    video_duration_msgs(v),
    video_rating_msgs(v),
    video_tag_count_msgs(v, max_tags),
    video_description_msgs(v),
    video_enum_msgs(v),
    video_relationship_msgs(v)
  )
}

# Extension field/count rules over the `images`/`video`/`news` list-columns.
# Per-`<url>` image count and per-video/per-news value rules are entry-scoped;
# the news count is per-FILE and document-scoped. Returns a (possibly empty)
# protocol-findings tibble.
# Per-`<url>` image-count cap. Returns a 0-/1-element list.
extension_image_findings <- function(imgs, base, i, limits) {
  if (is.null(imgs) || length(imgs) <= limits$max_images_per_url) {
    return(list())
  }
  list(protocol_url_finding(
    "PROTOCOL_IMAGE_COUNT_EXCEEDED",
    "error",
    "entry",
    base,
    i,
    NA_character_,
    sprintf(
      "<url> has %d <image:image> entries; the limit is %d per URL.",
      length(imgs),
      limits$max_images_per_url
    )
  ))
}

# Per-video field findings for one `<url>` (NULL `vids` -> no findings).
extension_video_findings <- function(vids, base, i, limits) {
  out <- list()
  for (m in seq_along(vids)) {
    for (msg in validate_video_element(vids[[m]], limits$max_video_tags)) {
      out[[length(out) + 1L]] <- protocol_ext_finding(
        "PROTOCOL_VIDEO_FIELD_INVALID",
        base,
        i,
        "video",
        m,
        msg
      )
    }
  }
  out
}

# Per-news field findings for one `<url>` (NULL `nws` -> no findings).
extension_news_findings <- function(nws, base, i) {
  out <- list()
  for (m in seq_along(nws)) {
    for (msg in validate_news_element(nws[[m]])) {
      out[[length(out) + 1L]] <- protocol_ext_finding(
        "PROTOCOL_NEWS_FIELD_INVALID",
        base,
        i,
        "news",
        m,
        msg
      )
    }
  }
  out
}

validate_extensions <- function(rows, base, limits) {
  images <- rows$images
  video <- rows$video
  news <- rows$news
  out <- list()
  total_news <- 0L

  for (i in seq_len(nrow(rows))) {
    total_news <- total_news + length(news[[i]])
    out <- c(
      out,
      extension_image_findings(images[[i]], base, i, limits),
      extension_video_findings(video[[i]], base, i, limits),
      extension_news_findings(news[[i]], base, i)
    )
  }

  if (total_news > limits$max_news_per_file) {
    out[[length(out) + 1L]] <- protocol_document_finding(
      "PROTOCOL_NEWS_COUNT_EXCEEDED",
      "error",
      base,
      sprintf(
        "Sitemap has %d <news:news> entries; the limit is %d per file.",
        total_news,
        limits$max_news_per_file
      )
    )
  }

  if (length(out) == 0L) {
    return(empty_protocol_findings())
  }
  do.call(rbind, out)
}

# --- Hreflang token policy (D.3) -------------------------------------------

# Read the `rel`/`hreflang`/`href` attributes off one `xml2::as_list()`
# `<xhtml:link>` element (an empty list carrying those values as R attributes).
# `exact = TRUE` guards against R's partial attribute-name matching. Each field
# is the raw character value or `NULL` when the attribute is absent.
hreflang_link_attrs <- function(link) {
  list(
    rel = attr(link, "rel", exact = TRUE),
    hreflang = attr(link, "hreflang", exact = TRUE),
    href = attr(link, "href", exact = TRUE)
  )
}

# A 2-/4-alpha subtag test (case-insensitive); the building block of the family
# structure check below.
hreflang_is_alpha2 <- function(s) grepl("^[A-Za-z]{2}$", s)
hreflang_is_alpha4 <- function(s) grepl("^[A-Za-z]{4}$", s)

# Assign a role (`"lang"`, `"region"`, `"script"`) to each hyphen-separated
# subtag by position and alpha-length, or return `NULL` when the structure fits
# no accepted family. With no IANA snapshot the subtags are matched by shape
# only; the one place casing carries meaning structurally is a standalone
# all-UPPERCASE 2-letter token, which reads as a region used alone (e.g. `US`)
# and is therefore rejected here as a non-family token (the caller maps `NULL`
# to `HREFLANG_FORMAT_INVALID`).
# Single-subtag family (`lang`): a 2-alpha token, but a standalone all-UPPERCASE
# 2-letter token reads as a region used alone (e.g. `US`) and is rejected.
hreflang_roles_1 <- function(parts) {
  if (!hreflang_is_alpha2(parts[1])) {
    return(NULL)
  }
  if (parts[1] == toupper(parts[1]) && parts[1] != tolower(parts[1])) {
    return(NULL)
  }
  "lang"
}

# Two-subtag families: `lang-REGION` (alpha2-alpha2) or `lang-Script`
# (alpha2-alpha4).
hreflang_roles_2 <- function(parts) {
  if (!hreflang_is_alpha2(parts[1])) {
    return(NULL)
  }
  if (hreflang_is_alpha2(parts[2])) {
    return(c("lang", "region"))
  }
  if (hreflang_is_alpha4(parts[2])) {
    return(c("lang", "script"))
  }
  NULL
}

# Assign a role (`"lang"`, `"region"`, `"script"`) to each hyphen-separated
# subtag by position and alpha-length, or return `NULL` when the structure fits
# no accepted family. With no IANA snapshot the subtags are matched by shape
# only (see the per-arity helpers; the caller maps `NULL` to
# `HREFLANG_FORMAT_INVALID`).
hreflang_roles <- function(parts) {
  n <- length(parts)
  if (n == 1L) {
    return(hreflang_roles_1(parts))
  }
  if (n == 2L) {
    return(hreflang_roles_2(parts))
  }
  is_lsr <- n == 3L &&
    hreflang_is_alpha2(parts[1]) &&
    hreflang_is_alpha4(parts[2]) &&
    hreflang_is_alpha2(parts[3])
  if (is_lsr) {
    return(c("lang", "script", "region"))
  }
  NULL
}

# TRUE when every subtag matches the convention for its role: lang lowercase,
# region UPPERCASE, script Title-case.
hreflang_case_ok <- function(parts, roles) {
  for (i in seq_along(parts)) {
    p <- parts[i]
    ok <- switch(
      roles[i],
      lang = identical(p, tolower(p)),
      region = identical(p, toupper(p)),
      script = identical(
        p,
        paste0(toupper(substr(p, 1L, 1L)), tolower(substr(p, 2L, nchar(p))))
      )
    )
    if (!ok) {
      return(FALSE)
    }
  }
  TRUE
}

# Classify one ORIGINAL `hreflang` value into a single primary code (precedence
# matters; the first applicable wins): `"valid"`, `"valid-xdefault"`,
# `"HREFLANG_XDEFAULT_INVALID"`, `"HREFLANG_FORMAT_INVALID"`,
# `"HREFLANG_SEPARATOR_INVALID"`, or `"HREFLANG_NONSTANDARD_CASE"`. An
# `x-default`-like value (case-folded, `_` to `-`) must be EXACTLY `x-default`
# to be clean; any near miss is `XDEFAULT_INVALID`. Otherwise: empty or
# whitespace-padded gives `FORMAT_INVALID`; `_`, `--`, an edge `-`, or internal
# whitespace gives `SEPARATOR_INVALID`; a structure outside the accepted
# families gives `FORMAT_INVALID`; a well-structured token with off-convention
# casing gives `NONSTANDARD_CASE`.
# `x-default`-like (case-folded, `_`->`-`): EXACTLY `x-default` is clean, any
# near miss is invalid. Returns the code, or `NULL` when not `x-default`-like.
hreflang_xdefault_code <- function(raw, trimmed) {
  if (!identical(tolower(gsub("_", "-", trimmed, fixed = TRUE)), "x-default")) {
    return(NULL)
  }
  if (identical(raw, "x-default")) {
    "valid-xdefault"
  } else {
    "HREFLANG_XDEFAULT_INVALID"
  }
}

# TRUE when the token uses a disallowed separator: `_`, `--`, an edge `-`, or
# internal whitespace.
hreflang_has_bad_separator <- function(trimmed) {
  grepl("_", trimmed, fixed = TRUE) ||
    grepl("--", trimmed, fixed = TRUE) ||
    grepl("(^-)|(-$)|[[:space:]]", trimmed)
}

classify_hreflang_token <- function(raw) {
  raw <- as.character(raw)
  trimmed <- trimws(raw)
  xdefault <- hreflang_xdefault_code(raw, trimmed)
  if (!is.null(xdefault)) {
    return(xdefault)
  }
  if (!nzchar(trimmed) || !identical(raw, trimmed)) {
    return("HREFLANG_FORMAT_INVALID")
  }
  if (hreflang_has_bad_separator(trimmed)) {
    return("HREFLANG_SEPARATOR_INVALID")
  }
  parts <- strsplit(trimmed, "-", fixed = TRUE)[[1]]
  roles <- hreflang_roles(parts)
  if (is.null(roles)) {
    return("HREFLANG_FORMAT_INVALID")
  }
  if (!hreflang_case_ok(parts, roles)) {
    return("HREFLANG_NONSTANDARD_CASE")
  }
  "valid"
}

# One per-`<xhtml:link>` hreflang finding (`subject_type = "entry"`, ref
# `…#entry:i:link:m`). `i` is the 1-based row/entry index, `m` the 1-based link
# index within that entry.
protocol_hreflang_finding <- function(
  code,
  severity,
  base,
  i,
  m,
  excerpt,
  message,
  is_strict_only = FALSE
) {
  protocol_findings(
    code = code,
    severity = severity,
    subject_type = "entry",
    subject_ref = protocol_ref_fragment(
      base,
      sprintf("#entry:%d:link:%d", i, m)
    ),
    message = message,
    evidence = list(finding_evidence(excerpt = excerpt)),
    is_strict_only = is_strict_only
  )
}

# One entry-level hreflang finding (ref `…#entry:i`), for set-level rules
# such as the missing `x-default`.
protocol_hreflang_set_finding <- function(code, severity, base, i, message) {
  protocol_findings(
    code = code,
    severity = severity,
    subject_type = "entry",
    subject_ref = protocol_ref_fragment(base, sprintf("#entry:%d", i)),
    message = message,
    evidence = list(finding_evidence()),
    is_strict_only = FALSE
  )
}

# Severity for the per-token classifier codes: structural/format failures are
# errors, a casing deviation is a warning.
hreflang_token_severity <- function(code) {
  if (identical(code, "HREFLANG_NONSTANDARD_CASE")) "warning" else "error"
}

# Build the LINK_ATTR_INVALID message from the specific attribute problems.
hreflang_attr_message <- function(rel, hreflang_missing, href_missing) {
  reasons <- character(0)
  if (is.null(rel)) {
    reasons <- c(reasons, "rel is absent")
  } else if (!identical(as.character(rel), "alternate")) {
    reasons <- c(reasons, sprintf("rel='%s' is not 'alternate'", rel))
  }
  if (hreflang_missing) {
    reasons <- c(reasons, "hreflang is absent")
  }
  if (href_missing) {
    reasons <- c(reasons, "href is absent or empty")
  }
  sprintf(
    "<xhtml:link> has invalid required attributes: %s.",
    paste(reasons, collapse = "; ")
  )
}

# Hreflang token policy over the `alternates` list-column. Each row's entry is
# `NULL` (no alternates) or a list of `xml2::as_list()`-converted `<xhtml:link>`
# elements. Per-link checks (attributes, token format/separator/case, relative
# href) and per-`<url>` set checks (duplicate token, duplicate / missing
# `x-default`) are emitted as protocol findings. Returns a (possibly empty)
# protocol-findings tibble.
# Classify one link's `hreflang` value: its normalized token (`NA` when the
# value is an `x-default`), the two `x-default` flags, and any per-token finding
# (`NULL` when the token is clean). Pure; the caller folds the result into its
# per-`<url>` state.
hreflang_token_outcome <- function(hl, base, i, m) {
  raw <- as.character(hl)
  code <- classify_hreflang_token(raw)
  is_xd <- identical(
    tolower(gsub("_", "-", trimws(raw), fixed = TRUE)),
    "x-default"
  )
  finding <- NULL
  if (!code %in% c("valid", "valid-xdefault")) {
    finding <- protocol_hreflang_finding(
      code,
      hreflang_token_severity(code),
      base,
      i,
      m,
      raw,
      hreflang_token_message(code, raw)
    )
  }
  list(
    norm = if (is_xd) NA_character_ else tolower(trimws(raw)),
    is_xdefault = is_xd,
    xdefault_clean = is_xd && identical(code, "valid-xdefault"),
    finding = finding
  )
}

# The required-attribute check for one `<xhtml:link>`: `rel="alternate"`, a
# present `hreflang`, and a non-empty `href`. Returns a 0-/1-element list.
hreflang_attr_finding <- function(rel, hl, hf, base, i, m) {
  hreflang_missing <- is.null(hl)
  href_missing <- is.null(hf) || !nzchar(trimws(as.character(hf)))
  rel_bad <- is.null(rel) || !identical(as.character(rel), "alternate")
  if (!(rel_bad || hreflang_missing || href_missing)) {
    return(list())
  }
  list(protocol_hreflang_finding(
    "HREFLANG_LINK_ATTR_INVALID",
    "error",
    base,
    i,
    m,
    if (hreflang_missing) NA_character_ else as.character(hl),
    hreflang_attr_message(rel, hreflang_missing, href_missing)
  ))
}

# The relative-href check for one `<xhtml:link>`. Returns a 0-/1-element list.
hreflang_href_finding <- function(hf, base, i, m) {
  href_missing <- is.null(hf) || !nzchar(trimws(as.character(hf)))
  if (href_missing || loc_absoluteness(as.character(hf)) != "relative") {
    return(list())
  }
  list(protocol_hreflang_finding(
    "HREFLANG_HREF_RELATIVE",
    "warning",
    base,
    i,
    m,
    as.character(hf),
    sprintf(
      "hreflang href '%s' is relative; an absolute URL is required.",
      hf
    ),
    is_strict_only = TRUE
  ))
}

# Per-`<xhtml:link>` checks for one `<url>`'s alternates (attributes, token
# format/separator/case, relative href). Returns the per-link findings plus the
# set-level state the caller's set checks consume.
hreflang_link_findings <- function(alts, base, i) {
  nlink <- length(alts)
  token_norm <- rep(NA_character_, nlink)
  is_xdefault <- rep(FALSE, nlink)
  xdefault_clean <- rep(FALSE, nlink)
  any_hreflang <- FALSE
  out <- list()

  for (m in seq_len(nlink)) {
    a <- hreflang_link_attrs(alts[[m]])
    out <- c(out, hreflang_attr_finding(a$rel, a$hreflang, a$href, base, i, m))

    if (!is.null(a$hreflang)) {
      any_hreflang <- TRUE
      o <- hreflang_token_outcome(a$hreflang, base, i, m)
      token_norm[m] <- o$norm
      is_xdefault[m] <- o$is_xdefault
      xdefault_clean[m] <- o$xdefault_clean
      if (!is.null(o$finding)) {
        out[[length(out) + 1L]] <- o$finding
      }
    }

    out <- c(out, hreflang_href_finding(a$href, base, i, m))
  }

  list(
    findings = out,
    token_norm = token_norm,
    is_xdefault = is_xdefault,
    xdefault_clean = xdefault_clean,
    any_hreflang = any_hreflang
  )
}

# Duplicate non-`x-default` tokens within one `<url>`: each repeat past the
# first occurrence is flagged against its own link, naming the first.
hreflang_dup_token_findings <- function(token_norm, base, i) {
  out <- list()
  seen <- new.env(parent = emptyenv())
  for (m in which(!is.na(token_norm))) {
    key <- token_norm[m]
    if (is.null(seen[[key]])) {
      assign(key, m, envir = seen)
    } else {
      out[[length(out) + 1L]] <- protocol_hreflang_finding(
        "HREFLANG_DUPLICATE",
        "warning",
        base,
        i,
        m,
        key,
        sprintf(
          "hreflang '%s' duplicates link %d in this <url>.",
          key,
          get(key, envir = seen)
        )
      )
    }
  }
  out
}

# More than one clean `x-default` in one `<url>` is a duplicate (malformed ones
# are already reported as XDEFAULT_INVALID by the per-token classifier).
hreflang_xdefault_dup_findings <- function(xdefault_clean, base, i) {
  out <- list()
  for (m in which(xdefault_clean)[-1]) {
    out[[length(out) + 1L]] <- protocol_hreflang_finding(
      "HREFLANG_XDEFAULT_INVALID",
      "error",
      base,
      i,
      m,
      "x-default",
      "x-default appears more than once in this <url>; only one is permitted."
    )
  }
  out
}

# `x-default` is recommended whenever any alternate is annotated; "absent" means
# no `x-default`-like value at all (a malformed attempt is reported, not treated
# as missing).
hreflang_no_xdefault_findings <- function(
  any_hreflang,
  is_xdefault,
  base,
  i
) {
  if (!(any_hreflang && !any(is_xdefault))) {
    return(list())
  }
  list(protocol_hreflang_set_finding(
    "HREFLANG_XDEFAULT_MISSING",
    "info",
    base,
    i,
    paste0(
      "No x-default hreflang annotation; one is recommended when ",
      "alternate-language links are present."
    )
  ))
}

validate_hreflang <- function(rows, base) {
  alternates <- rows$alternates
  out <- list()

  for (i in seq_len(nrow(rows))) {
    alts <- alternates[[i]]
    if (is.null(alts) || length(alts) == 0L) {
      next
    }

    links <- hreflang_link_findings(alts, base, i)
    out <- c(
      out,
      links$findings,
      hreflang_dup_token_findings(links$token_norm, base, i),
      hreflang_xdefault_dup_findings(links$xdefault_clean, base, i),
      hreflang_no_xdefault_findings(
        links$any_hreflang,
        links$is_xdefault,
        base,
        i
      )
    )
  }

  if (length(out) == 0L) {
    return(empty_protocol_findings())
  }
  do.call(rbind, out)
}

# The human-readable message for one per-token classifier code.
hreflang_token_message <- function(code, raw) {
  switch(
    code,
    HREFLANG_FORMAT_INVALID = sprintf(
      paste0(
        "hreflang '%s' is not an accepted language token (lang, lang-REGION, ",
        "lang-Script, lang-Script-REGION, or x-default)."
      ),
      raw
    ),
    HREFLANG_SEPARATOR_INVALID = sprintf(
      paste0(
        "hreflang '%s' has an invalid separator or structure; subtags must be ",
        "hyphen-separated (e.g. en-US, not en_US)."
      ),
      raw
    ),
    HREFLANG_NONSTANDARD_CASE = sprintf(
      paste0(
        "hreflang '%s' deviates from the conventional casing (lang lowercase, ",
        "Script Title-case, REGION UPPERCASE)."
      ),
      raw
    ),
    HREFLANG_XDEFAULT_INVALID = sprintf(
      "hreflang '%s' is a malformed x-default; it must be exactly 'x-default'.",
      raw
    )
  )
}

# Per-`<loc>` URL rules over the parsed rows. Returns a (possibly empty)
# protocol-findings tibble. `sitemap_url` is the sitemap's own absolute URL,
# used for scope; `NA` skips the scope check (undefined without an origin).
# Non-absolute (relative or non-http(s) scheme) locs -> a single clear finding
# per entry; the remaining URL-structure checks assume an absolute http(s) URL.
loc_not_absolute_findings <- function(loc, bad, base) {
  out <- list()
  for (j in bad) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_URL_NOT_ABSOLUTE",
      "error",
      "entry",
      base,
      j,
      loc[j],
      sprintf(
        "<loc> '%s' is not an absolute http/https URL.",
        loc[j]
      )
    )
  }
  out
}

# URL-structure checks for one absolute http(s) `<loc>` at entry `j`: no-host
# (terminal), over-length, invalid escape, fragment, userinfo, out-of-scope.
# `prow` is the one-row parsed adapter for this loc.
loc_single_url_findings <- function(
  l,
  j,
  prow,
  authority_self,
  dir_self,
  sitemap_url,
  base
) {
  host <- as.character(prow$host)
  if (is.na(host) || !nzchar(host)) {
    return(list(protocol_url_finding(
      "PROTOCOL_URL_NO_HOST",
      "error",
      "entry",
      base,
      j,
      l,
      sprintf("<loc> '%s' has no host component.", l)
    )))
  }

  out <- list()

  if (nchar(l) >= 2048L) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_URL_TOO_LONG",
      "warning",
      "entry",
      base,
      j,
      l,
      sprintf(
        "<loc> is %d characters; sitemap URLs must be under 2048.",
        nchar(l)
      )
    )
  }

  if (has_invalid_escape(l)) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_URL_INVALID_ESCAPE",
      "error",
      "entry",
      base,
      j,
      l,
      sprintf("<loc> '%s' contains an invalid percent-escape.", l)
    )
  }

  if (grepl("#", l, fixed = TRUE)) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_URL_FRAGMENT",
      "info",
      "entry",
      base,
      j,
      l,
      sprintf(
        "<loc> '%s' contains a fragment, which crawlers ignore.",
        l
      )
    )
  }

  user <- as.character(prow$user)
  if (!is.na(user) && nzchar(user)) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_URL_USERINFO",
      "info",
      "entry",
      base,
      j,
      l,
      sprintf("<loc> '%s' contains userinfo, which crawlers ignore.", l)
    )
  }

  if (!is.na(authority_self)) {
    in_scope <- identical(loc_authority(prow), authority_self) &&
      startsWith(as.character(prow$path), dir_self)
    if (!in_scope) {
      out[[length(out) + 1L]] <- protocol_url_finding(
        "PROTOCOL_URL_OUT_OF_SCOPE",
        "warning",
        "entry",
        base,
        j,
        l,
        sprintf(
          paste0(
            "<loc> '%s' is outside the sitemap's scope (same host and ",
            "same-or-lower path as %s)."
          ),
          l,
          sitemap_url
        )
      )
    }
  }

  out
}

# Duplicate detection on the full-URL identity key, over the absolute,
# host-bearing entries only. Each repeat past the first occurrence of a key is
# flagged against its own entry, naming the first occurrence.
loc_duplicate_findings <- function(parsed, absolute, loc, base) {
  has_host <- !is.na(parsed$host) & nzchar(as.character(parsed$host))
  if (!any(has_host)) {
    return(list())
  }
  keys <- build_loc_key(parsed)
  keys[!has_host] <- NA_character_
  out <- list()
  first_seen <- new.env(parent = emptyenv())
  for (k in which(has_host)) {
    key <- keys[k]
    if (is.null(first_seen[[key]])) {
      assign(key, absolute[k], envir = first_seen)
    } else {
      j <- absolute[k]
      first_entry <- get(key, envir = first_seen)
      out[[length(out) + 1L]] <- protocol_url_finding(
        "PROTOCOL_DUPLICATE_LOC",
        "warning",
        "entry",
        base,
        j,
        loc[j],
        sprintf(
          "<loc> duplicates entry %d (identity key '%s').",
          first_entry,
          key
        )
      )
    }
  }
  out
}

validate_loc_urls <- function(rows, sitemap_url, base) {
  loc <- rows$loc
  keep <- !is.na(loc) & nzchar(loc)
  idx <- which(keep)
  if (length(idx) == 0L) {
    return(empty_protocol_findings())
  }

  kind <- loc_absoluteness(loc[idx])
  bad <- idx[kind != "http(s)"]
  out <- loc_not_absolute_findings(loc, bad, base)

  absolute <- idx[kind == "http(s)"]
  if (length(absolute) == 0L) {
    # Unreachable empty-guard: with no absolute URL left, every kept loc was
    # non-absolute and already emitted a finding above, so `out` is non-empty.
    if (length(out) == 0L) {
      return(empty_protocol_findings()) # nocov
    }
    return(do.call(rbind, out))
  }

  parsed <- parse_url_adapter(loc[absolute])
  authority_self <- NA_character_
  dir_self <- NA_character_
  if (!is.na(sitemap_url)) {
    parsed_self <- parse_url_adapter(sitemap_url)
    authority_self <- loc_authority(parsed_self)
    dir_self <- loc_directory_prefix(parsed_self$path)
  }

  for (k in seq_along(absolute)) {
    j <- absolute[k]
    out <- c(
      out,
      loc_single_url_findings(
        loc[j],
        j,
        parsed[k, , drop = FALSE],
        authority_self,
        dir_self,
        sitemap_url,
        base
      )
    )
  }

  out <- c(out, loc_duplicate_findings(parsed, absolute, loc, base))

  if (length(out) == 0L) {
    return(empty_protocol_findings())
  }
  do.call(rbind, out)
}

# --- Text-sitemap rules (D.5) ------------------------------------------------

# Text-sitemap evidence: like finding_evidence() but the excerpt is clamped to
# the contract's tighter 200-char cap for text lines (findings-contract.md;
# sitemap-spec.md §7.2) and the 1-based line number is always recorded.
protocol_text_evidence <- function(excerpt, line) {
  if (!is.na(excerpt)) {
    excerpt <- substr(excerpt, 1L, 200L)
  }
  list(excerpt = excerpt, line = as.integer(line), column = NA_integer_)
}

# One text-sitemap finding row, scoped to a 1-based line via the `#line:<n>`
# subject_ref fragment (findings-contract.md). A text line is an `entry`.
protocol_text_finding <- function(
  code,
  severity,
  base,
  line,
  excerpt,
  message,
  is_strict_only = FALSE
) {
  protocol_findings(
    code = code,
    severity = severity,
    subject_type = "entry",
    subject_ref = protocol_ref_fragment(base, paste0("#line:", line)),
    message = message,
    evidence = list(protocol_text_evidence(excerpt, line)),
    is_strict_only = is_strict_only
  )
}

#' Validate a text sitemap against protocol/semantic rules (Layer D)
#'
#' The text-format counterpart of `validate_protocol()` and a standalone
#' finding-producer: text sitemaps never go through the XML rows path
#' (sitemap-spec.md §7.2). It reads the RAW document because the parsed row
#' tibble has already dropped blank lines and line numbers (R/parse-text.R).
#'
#' Each line (split on `\n` / `\r\n` / `\r`, matching the parser, then trimmed)
#' is checked: a blank/whitespace-only line emits a strict-only
#' `PROTOCOL_TEXT_BLANK_LINE` `info`; a non-absolute line emits
#' `PROTOCOL_URL_NOT_ABSOLUTE`; an absolute line missing a host emits
#' `PROTOCOL_URL_NO_HOST`; an over-long line emits `PROTOCOL_TEXT_URL_TOO_LONG`.
#' Findings are scoped to their 1-based line via the `#line:<n>` subject_ref and
#' carry a ≤ 200-char excerpt. Like the XML producer it does not assemble the
#' final contract (no `mode`, filtering, dedup, or sort — those are Layer F).
#'
#' @param text The raw text-sitemap document: a character string/vector or raw
#'   bytes (decoded as UTF-8), the same input `parse_sitemap_text()` accepts.
#' @param subject_ref The document-level `sitemap://…` base for each finding's
#'   `subject_ref`. `NA` yields fragment-only refs.
#' @return A protocol-findings tibble (zero rows when every line conforms).
#' @keywords internal
#' @noRd
# Strict-only blank-line findings for a text sitemap.
text_blank_findings <- function(blank, subject_ref) {
  out <- list()
  for (i in which(blank)) {
    out[[length(out) + 1L]] <- protocol_text_finding(
      "PROTOCOL_TEXT_BLANK_LINE",
      "info",
      subject_ref,
      i,
      NA_character_,
      sprintf(
        "Line %d is blank; blank lines are skipped (reported only in strict).",
        i
      ),
      is_strict_only = TRUE
    )
  }
  out
}

# Non-absolute text lines get a single clear finding; the host/length checks
# assume an absolute http(s) URL.
text_not_absolute_findings <- function(url_idx, vals, kind, subject_ref) {
  out <- list()
  for (k in which(kind != "http(s)")) {
    i <- url_idx[k]
    out[[length(out) + 1L]] <- protocol_text_finding(
      "PROTOCOL_URL_NOT_ABSOLUTE",
      "error",
      subject_ref,
      i,
      vals[k],
      sprintf("Line %d: '%s' is not an absolute http/https URL.", i, vals[k])
    )
  }
  out
}

# Host/length checks over the absolute http(s) text lines (`abs_k` indexes into
# `vals`/`url_idx`).
text_absolute_findings <- function(url_idx, abs_k, vals, subject_ref) {
  out <- list()
  if (length(abs_k) == 0L) {
    return(out)
  }
  parsed <- parse_url_adapter(vals[abs_k])
  for (m in seq_along(abs_k)) {
    i <- url_idx[abs_k[m]]
    l <- vals[abs_k[m]]
    host <- as.character(parsed$host[m])
    if (is.na(host) || !nzchar(host)) {
      out[[length(out) + 1L]] <- protocol_text_finding(
        "PROTOCOL_URL_NO_HOST",
        "error",
        subject_ref,
        i,
        l,
        sprintf("Line %d: '%s' has no host component.", i, l)
      )
      next
    }
    if (nchar(l) >= 2048L) {
      out[[length(out) + 1L]] <- protocol_text_finding(
        "PROTOCOL_TEXT_URL_TOO_LONG",
        "warning",
        subject_ref,
        i,
        l,
        sprintf(
          "Line %d: URL is %d characters; sitemap URLs must be under 2048.",
          i,
          nchar(l)
        )
      )
    }
  }
  out
}

validate_text_protocol <- function(text, subject_ref = NA_character_) {
  s <- text_as_string(text)
  if (!nzchar(s)) {
    return(empty_protocol_findings())
  }
  lines <- strsplit(s, "\r\n|\r|\n", perl = TRUE)[[1L]]
  trimmed <- trimws(lines)
  blank <- !nzchar(trimmed)

  out <- text_blank_findings(blank, subject_ref)

  url_idx <- which(!blank)
  if (length(url_idx) == 0L) {
    # Unreachable empty-guard: a non-empty document with no URL lines is
    # all-blank, so the blank-line findings above already populated `out`.
    if (length(out) == 0L) {
      return(empty_protocol_findings()) # nocov
    }
    return(do.call(rbind, out))
  }

  vals <- trimmed[url_idx]
  kind <- loc_absoluteness(vals)
  abs_k <- which(kind == "http(s)")

  out <- c(
    out,
    text_not_absolute_findings(url_idx, vals, kind, subject_ref),
    text_absolute_findings(url_idx, abs_k, vals, subject_ref)
  )

  if (length(out) == 0L) {
    return(empty_protocol_findings())
  }
  do.call(rbind, out)
}

#' Validate parsed sitemap rows against protocol/semantic rules (Layer D)
#'
#' Layer D finding-producer: runs the protocol checks XSD cannot express over
#' the parsed row tibble and returns findings in the contract shape. Produces no
#' rows for a conformant document. Does not assemble the final contract (no
#' `mode`, no filtering/dedup/sort across sources — those are Layer F).
#'
#' Covers the per-`<loc>` URL rules, count/field-value rules, the hreflang
#' token policy over the `alternates` list-column, and the image/video/news
#' extension field rules. With a `source_meta` argument it also surfaces the D.6
#' classification diagnostics (`UNSUPPORTED_*` / `ENCODING_*`); text sitemaps
#' take the dedicated `validate_text_protocol()` path.
#'
#' @param rows A faithful parsed row tibble from `sitemap_rows()` / the format
#'   parsers — `lastmod` and `priority` are the raw `<lastmod>`/`<priority>`
#'   strings (ADR-004), so format rules read the original text directly.
#' @param sitemap_url The sitemap's own absolute URL, used for same-origin scope
#'   comparison. `NA` skips the scope check.
#' @param subject_ref The document-level `sitemap://…` base for each finding's
#'   `subject_ref`; defaults to the authority form derived from `sitemap_url`.
#'   `NA` yields fragment-only refs.
#' @param byte_size The uncompressed byte count of the source document, for the
#'   `PROTOCOL_SIZE_EXCEEDED` rule. `NA` skips the size check.
#' @param fetched_at The sitemap's fetch/generation time (`POSIXct`), for the
#'   `PROTOCOL_LASTMOD_LOOKS_GENERATED` corpus heuristic. `NA` skips it.
#' @param source_meta A `source_meta()` object carrying the source's
#'   classification + encoding signals, for the D.6 unsupported-input and
#'   encoding-conflict diagnostics (`UNSUPPORTED_*` / `ENCODING_*`, all
#'   `layer = "classification"`). `NULL` emits none. These run from the metadata
#'   alone, so they are produced even when `rows` is empty (e.g. an
#'   `UNSUPPORTED_ROOT` document yields no rows). Acting as the interim
#'   cross-layer assembler, this function surfaces them alongside the protocol
#'   findings until Layer F owns assembly.
#' @param limits Layer D limit thresholds; see `protocol_limits()`.
#' @return A findings tibble (zero rows when the document conforms and no
#'   diagnostics apply). Protocol rows carry `layer = "protocol"`; the D.6
#'   source diagnostics carry `layer = "classification"`.
#' @keywords internal
#' @noRd
validate_protocol <- function(
  rows,
  sitemap_url = NA_character_,
  subject_ref = sitemap_subject_ref(sitemap_url),
  byte_size = NA_real_,
  fetched_at = NA,
  source_meta = NULL,
  limits = protocol_limits()
) {
  parts <- list(
    validate_classification(source_meta, subject_ref),
    validate_encoding(source_meta, subject_ref)
  )

  if (!is.null(rows) && nrow(rows) > 0L) {
    parts <- c(
      parts,
      list(
        validate_loc_urls(rows, sitemap_url, subject_ref),
        validate_url_count(rows, subject_ref, limits$max_url_count),
        validate_doc_size(
          byte_size,
          subject_ref,
          limits$max_uncompressed_bytes
        ),
        validate_field_values(rows, subject_ref),
        validate_lastmod_corpus(rows, subject_ref, fetched_at, limits),
        validate_hreflang(rows, subject_ref),
        validate_extensions(rows, subject_ref, limits)
      )
    )
  }

  parts <- parts[vapply(parts, nrow, integer(1)) > 0L]
  if (length(parts) == 0L) {
    return(empty_protocol_findings())
  }
  do.call(rbind, parts)
}
