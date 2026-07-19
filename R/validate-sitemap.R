# validate_sitemap() entry point (Layer F; architecture.md §3, PRD §1).
#
# The public validation entry point and the Layer F integration site. It reads a
# single source (a sitemap URL or a local file), runs every finding-producer
# over it (Layer C schema, Layer D protocol, classification, index-expansion),
# and hands the producer parts to the F.1 assembler core
# `assemble_findings(parts, mode)`, which row-binds them, stamps `mode`, applies
# the strict/non-strict severity model, de-duplicates, and sorts into the
# stable contract order.
#
# This is the ONLY place that holds the raw bytes, the sniffed format, and the
# xml2 document, so it owns the parse->validate data flow. It does NOT reuse
# `read_sitemap()` wholesale: that projects rows to the typed tibble and hides
# the bytes/doc/format, whereas validation needs (a) the raw bytes + sniffed
# format (for classification), (b) the xml2 document (for the schema layer), and
# (c) the FAITHFUL un-projected rows (for the protocol layer, which reads the
# raw <lastmod>/<priority> per ADR-004). It reuses only the LOW-LEVEL machinery
# (`fetch_source()` for the SSRF-guarded fetch, `sniff_format()`,
# `gzip_decompress()`, `read_sitemap_xml()`, `parse_sitemap_xml()`,
# `expand_index()`), never duplicating the network/SSRF code.
#
# Errors-vs-findings (architecture.md §3). Conditions the parse API would RAISE
# become FINDINGS here where the contract says so: an unsupported XML root, a
# non-XML/non-text source (HTML masquerade), and UNSUPPORTED (non-Atom-dialect)
# RSS/Atom feed children of an index are classification findings, not thrown
# errors. Supported feeds (RSS 2.0 / Atom 0.3/1.0) parse into rows and are
# protocol-validated like a urlset. A genuine transport /
# SSRF / timeout / non-2xx failure still propagates as the existing classed
# condition from `fetch_source()` (v1 minimal; no activated feature requires
# otherwise).

# A resolved source: the (possibly decompressed) bytes, the sniffed format of
# those bytes, the uncompressed byte count, the document-level subject_ref base,
# and the final URL (NA for a local file, so the protocol scope check is
# skipped). `fetched_at` is NA: source_metadata() carries no fetch timestamp, so
# the PROTOCOL_LASTMOD_LOOKS_GENERATED corpus heuristic is skipped (the protocol
# producer treats NA `fetched_at` as "skip").
validation_target <- function(x) {
  if (is.data.frame(x) || is.list(x)) {
    return(list(
      target = as.character(x$normalized_url)[[1L]],
      is_local = isTRUE(as.logical(x$is_local_file)[[1L]]),
      source = x
    ))
  }
  target <- as.character(x)[[1L]]
  list(target = target, is_local = file.exists(target), source = target)
}

validation_source_bytes <- function(
  target,
  source,
  is_local,
  user_agent,
  limits,
  policy
) {
  if (is_local) {
    return(list(
      bytes = readBin(target, what = "raw", n = file.info(target)$size),
      final_url = NA_character_
    ))
  }

  rec <- fetch_source(
    source,
    user_agent = user_agent,
    limits = limits,
    policy = policy
  )
  if (!is.na(rec$error_class)) {
    rlang::abort(
      sprintf(
        "Entry-point fetch of %s failed with HTTP %s.",
        rec$final_url,
        rec$status
      ),
      class = "sitemapr_entrypoint_error",
      url = rec$final_url,
      status = rec$status
    )
  }
  list(bytes = attr(rec, "body"), final_url = rec$final_url)
}

validation_archive_source <- function(target, bytes, final_url, base) {
  list(
    kind = "archive",
    path = target,
    byte_size = as.numeric(length(bytes)),
    final_url = final_url,
    base = base,
    fetched_at = NA
  )
}

validation_document_source <- function(bytes, fmt, final_url, base) {
  list(
    kind = "document",
    bytes = bytes,
    format = fmt,
    byte_size = as.numeric(length(bytes)),
    final_url = final_url,
    base = base,
    fetched_at = NA # TODO(layer-f-encoding) + no fetch-timestamp in source_meta
  )
}

resolve_validation_source <- function(x, user_agent, limits, policy) {
  target <- validation_target(x)
  source <- validation_source_bytes(
    target$target,
    target$source,
    target$is_local,
    user_agent,
    limits,
    policy
  )
  bytes <- source$bytes
  final_url <- source$final_url

  base <- sitemap_subject_ref(
    if (is.na(final_url)) target$target else final_url
  )
  fmt <- sniff_format(bytes)

  # A local `.tar.gz` (gzip whose inner stream is tar; tar.gz is local-only,
  # PRD §1) is handed to the bounded archive extractor by path — its
  # decompression conditions (malformed tar, the ADR-003 file-count cap,
  # per-member non-sitemap skips) become findings in validate_archive_parts().
  # A corrupt outer gzip makes this guard's decompress raise
  # `sitemapr_decompression_error`, caught by validate_sitemap() as
  # UNSUPPORTED_MALFORMED_GZIP.
  if (
    target$is_local &&
      identical(fmt, "gzip") &&
      identical(sniff_format(gzip_decompress(bytes)), "tar")
  ) {
    return(validation_archive_source(target$target, bytes, final_url, base))
  }

  if (identical(fmt, "gzip")) {
    bytes <- gzip_decompress(bytes)
    fmt <- sniff_format(bytes)
  }

  validation_document_source(bytes, fmt, final_url, base)
}

archive_gzip_error_part <- function(cnd, src) {
  list(
    finding = decompression_source_finding(
      "UNSUPPORTED_MALFORMED_GZIP",
      src$base,
      conditionMessage(cnd)
    )
  )
}

archive_malformed_part <- function(cnd, src) {
  list(
    finding = decompression_member_finding(
      "UNSUPPORTED_MALFORMED_ARCHIVE",
      src$base,
      conditionMessage(cnd),
      severity = "error"
    )
  )
}

archive_limit_part <- function(cnd, src) {
  if (!identical(cnd$limit, "file_count")) {
    stop(cnd) # byte-ceiling guards are out of this mapping; re-propagate
  }
  list(
    finding = decompression_source_finding(
      "DECOMPRESS_TOO_MANY_FILES",
      src$base,
      conditionMessage(cnd)
    )
  )
}

# Assemble the producer parts for a local `.tar.gz` archive. The bounded
# extractor (`parse_sitemap_archive()`) signals its failure modes as classed
# conditions; each is caught and turned into a decompression finding per the
# findings-contract mapping. On success the member-skip `problems` become
# DECOMPRESS_NOT_SITEMAP findings and the extracted rows feed the protocol
# producer (mirroring how index expansion routes its rows). Non-file_count
# archive-byte limits (the 200 MB decompressed / 50 MB on-disk guards) are NOT
# in this mapping and re-propagate as the existing condition, preserving the
# guard behavior.
validate_archive_parts <- function(src, ruleset = NULL) {
  result <- tryCatch(
    list(ok = parse_sitemap_archive(src$path, source_ref = src$base)),
    sitemapr_decompression_error = function(cnd) {
      archive_gzip_error_part(cnd, src)
    },
    sitemapr_malformed_archive = function(cnd) {
      archive_malformed_part(cnd, src)
    },
    sitemapr_archive_limit = function(cnd) {
      archive_limit_part(cnd, src)
    }
  )

  if (!is.null(result$finding)) {
    return(list(result$finding))
  }

  res <- result$ok
  parts <- list(decompression_findings_from_problems(res$problems))
  if (nrow(res$rows) > 0L) {
    parts[[length(parts) + 1L]] <- validate_protocol(
      res$rows,
      sitemap_url = src$final_url,
      subject_ref = src$base,
      byte_size = src$byte_size,
      fetched_at = src$fetched_at,
      source_meta = NULL,
      ruleset = ruleset
    )
    parts <- append_robots_part(
      parts,
      res$rows$loc,
      src$robots_ua,
      src$base,
      src$page_sink,
      res$rows$alternates
    )
  }
  parts
}

# Map one `expand_index()` problem row to its stable INDEX_* finding code from
# the message wording set in `expand_index_node()`. Returns NA for a problem
# that is not an index-expansion traversal event (e.g. a fetch/classification
# problem on an unfetchable child), which is not surfaced as a finding here.
index_problem_code <- function(category, message) {
  if (!identical(category, "index-expansion")) {
    return(NA_character_)
  }
  if (grepl("cycle", message, fixed = TRUE)) {
    return("INDEX_CYCLE_DETECTED")
  }
  if (grepl("depth limit", message, fixed = TRUE)) {
    return("INDEX_DEPTH_EXCEEDED")
  }
  if (grepl("Nested sitemap index", message, fixed = TRUE)) {
    return("SITEMAP_INDEX_NESTED")
  }
  if (grepl("Aggregate sitemap budget", message, fixed = TRUE)) {
    return("INDEX_TOTAL_SITEMAPS_EXCEEDED")
  }
  if (grepl("Aggregate URL budget", message, fixed = TRUE)) {
    return("INDEX_TOTAL_URLS_EXCEEDED")
  }
  if (grepl("children", message, fixed = TRUE)) {
    return("INDEX_CHILD_COUNT_EXCEEDED")
  }
  NA_character_
}

# Contract severity for an INDEX_* code: nesting is a warning (still expanded),
# the cycle / depth-cap / count-cap events are errors (sitemap-spec.md §8).
index_code_severity <- function(code) {
  if (identical(code, "SITEMAP_INDEX_NESTED")) "warning" else "error"
}

# Build a contract-shaped (8-column) index-expansion findings tibble from the
# `problems` table `expand_index()` records. `layer = "index-expansion"`,
# `subject_type = "index-child"`; the problem's subject_ref (a child/index URL)
# becomes the finding's `#index-child:<url>` ref. Non-traversal problems are
# skipped. Returns a zero-row tibble when there is nothing to map.
index_findings_from_problems <- function(problems, base) {
  if (is.null(problems) || nrow(problems) == 0L) {
    return(empty_index_findings())
  }
  out <- list()
  for (i in seq_len(nrow(problems))) {
    code <- index_problem_code(problems$category[i], problems$message[i])
    if (is.na(code)) {
      next
    }
    out[[length(out) + 1L]] <- index_findings(
      code = code,
      severity = index_code_severity(code),
      subject_type = "index-child",
      subject_ref = protocol_ref_fragment(
        base,
        paste0("#index-child:", problems$subject_ref[i])
      ),
      message = problems$message[i],
      evidence = list(finding_evidence(excerpt = problems$subject_ref[i])),
      is_strict_only = FALSE
    )
  }
  if (length(out) == 0L) {
    return(empty_index_findings())
  }
  do.call(rbind, out)
}

# Construct an index-expansion findings tibble (the same 8-column contract
# subset the other producers emit, with `layer = "index-expansion"`).
index_findings <- function(
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
    layer = rep("index-expansion", n),
    subject_type = as.character(subject_type),
    subject_ref = as.character(subject_ref),
    message = as.character(message),
    evidence = if (length(evidence) > 0L) evidence else vector("list", n),
    is_strict_only = as.logical(is_strict_only)
  )
}

# A zero-row index-expansion findings tibble.
empty_index_findings <- function() {
  index_findings()
}

# Build the producer `parts` list for a top-level RSS/Atom feed source. A
# supported dialect (rss2.0 / atom0.3 / atom1.0) is parsed into the faithful row
# schema and protocol-validated exactly like a `urlset`; an unsupported dialect
# (`parse_feed()` raising `sitemapr_unsupported_feed`) falls through to the XML
# branch, which yields UNSUPPORTED_ROOT for its `<feed>`/`<rss>` root.
validate_feed_parts <- function(
  src,
  user_agent,
  limits,
  index_limits,
  policy,
  ruleset = NULL
) {
  parsed <- tryCatch(
    parse_feed(src$bytes, source_sitemap = src$final_url),
    sitemapr_unsupported_feed = function(cnd) NULL
  )
  if (is.null(parsed)) {
    return(validate_xml_parts(
      src,
      user_agent,
      limits,
      index_limits,
      policy,
      ruleset
    ))
  }
  append_robots_part(
    list(
      validate_engine_format(parsed$variant, src$base, ruleset),
      validate_protocol(
        parsed$rows,
        sitemap_url = src$final_url,
        subject_ref = src$base,
        byte_size = src$byte_size,
        fetched_at = src$fetched_at,
        source_meta = NULL,
        ruleset = ruleset
      )
    ),
    parsed$rows$loc,
    src$robots_ua,
    src$base,
    src$page_sink,
    parsed$rows$alternates
  )
}

# Build the producer `parts` list for an XML source, branching on the root
# local-name. `src` is a resolved source; `index_limits` bounds the expansion.
validate_xml_parts <- function(
  src,
  user_agent,
  limits,
  index_limits,
  policy,
  ruleset = NULL
) {
  doc <- read_sitemap_xml(src$bytes)
  root <- xml2::xml_name(xml2::xml_root(doc))

  if (is.na(schema_root_kind(root))) {
    # An unsupported root becomes a classification finding, never an error;
    # validate_schema() already returns empty for it, and there are no rows.
    return(list(
      validate_classification(source_meta(unsupported_root = root), src$base)
    ))
  }

  schema <- validate_schema(doc, src$base)

  if (identical(root, "urlset")) {
    rows <- parse_sitemap_xml(src$bytes, source_sitemap = src$final_url)$rows
    return(append_robots_part(
      list(
        schema,
        validate_protocol(
          rows,
          sitemap_url = src$final_url,
          subject_ref = src$base,
          byte_size = src$byte_size,
          fetched_at = src$fetched_at,
          source_meta = NULL,
          ruleset = ruleset
        )
      ),
      rows$loc,
      src$robots_ua,
      src$base,
      src$page_sink,
      rows$alternates
    ))
  }

  # sitemapindex: schema + bounded expansion. The expansion problems become
  # INDEX_* findings; unsupported-dialect feed children become UNSUPPORTED_FEED
  # (supported feeds parse into rows); the rows gathered from leaf children
  # (urlset/text/feed) feed the protocol layer.
  validate_index_parts(
    src,
    schema,
    doc,
    user_agent,
    limits,
    index_limits,
    policy,
    ruleset
  )
}

# Assemble the producer parts for a `sitemapindex` root. A local index has no
# origin URL to fetch children from, so expansion only runs for a URL source.
validate_index_parts <- function(
  src,
  schema,
  doc,
  user_agent,
  limits,
  index_limits,
  policy,
  ruleset = NULL
) {
  parts <- list(schema)
  if (is.na(src$final_url)) {
    return(parts)
  }

  children <- parse_sitemapindex(xml2::xml_root(doc))
  ex <- expand_index(
    src$final_url,
    children,
    depth = 0L,
    user_agent = user_agent,
    limits = index_limits,
    net_limits = limits,
    policy = policy
  )

  parts[[length(parts) + 1L]] <-
    index_findings_from_problems(ex$problems, src$base)

  parts[[length(parts) + 1L]] <- index_child_scope_findings(
    src$final_url,
    children$loc,
    src$base,
    ruleset
  )

  # A child sniffed as a feed but rejected by parse_feed() (unsupported dialect)
  # -> one UNSUPPORTED_FEED per child via the source_meta/classification path.
  # Supported feed children are parsed into rows above and validated like any
  # leaf. (A TOP-LEVEL feed source is handled by validate_feed_parts().)
  feeds <- index_feed_children(ex$problems)
  if (length(feeds) > 0L) {
    parts[[length(parts) + 1L]] <- validate_classification(
      source_meta(feed_children = feeds),
      src$base
    )
  }

  if (nrow(ex$rows) > 0L) {
    parts <- c(
      parts,
      index_protocol_parts(
        ex$rows,
        ex$sources,
        src$base,
        src$robots_ua,
        ruleset,
        src$page_sink
      )
    )
  }
  parts
}

# Child URLs the expander sniffed as a feed but `parse_feed()` rejected as an
# unsupported dialect (recorded as a `"feed"`-category expansion problem). These
# drive one UNSUPPORTED_FEED finding each. A SUPPORTED feed child is parsed into
# rows like any leaf and never appears here.
index_feed_children <- function(problems) {
  if (is.null(problems) || nrow(problems) == 0L) {
    return(character(0))
  }
  is_feed <- as.character(problems$category) == "feed"
  as.character(problems$subject_ref[is_feed])
}

index_source_row <- function(sources, sitemap_url) {
  if (is.null(sources) || nrow(sources) == 0L || is.na(sitemap_url)) {
    return(NULL)
  }
  i <- match(sitemap_url, as.character(sources$final_url))
  if (is.na(i)) {
    return(NULL)
  }
  sources[i, , drop = FALSE]
}

index_source_byte_size <- function(source) {
  if (is.null(source) || nrow(source) == 0L) {
    return(NA_real_)
  }
  # `source_metadata()$bytes` records the fetched body size. For gzip children
  # that is the compressed size, while the protocol limit is uncompressed.
  if (identical(as.character(source$format)[[1L]], "gzip")) {
    return(NA_real_)
  }
  as.numeric(source$bytes[[1L]])
}

index_protocol_parts <- function(
  rows,
  sources,
  fallback_base,
  robots_ua = NULL,
  ruleset = NULL,
  page_sink = NULL
) {
  if (is.null(rows) || nrow(rows) == 0L) {
    return(list())
  }

  sitemap_url <- as.character(rows$source_sitemap)
  known <- !is.na(sitemap_url) & nzchar(sitemap_url)
  if (!any(known)) {
    return(append_robots_part(
      list(validate_protocol(
        rows,
        sitemap_url = NA_character_,
        subject_ref = fallback_base,
        byte_size = NA_real_,
        fetched_at = NA,
        source_meta = NULL,
        ruleset = ruleset
      )),
      rows$loc,
      robots_ua,
      fallback_base,
      page_sink,
      rows$alternates
    ))
  }

  groups <- split(which(known), sitemap_url[known], drop = TRUE)
  parts <- list()
  for (i in seq_along(groups)) {
    child_url <- names(groups)[[i]]
    child_base <- sitemap_subject_ref(child_url)
    child_source <- index_source_row(sources, child_url)
    child_rows <- rows[groups[[i]], , drop = FALSE]
    parts[[length(parts) + 1L]] <- validate_protocol(
      child_rows,
      sitemap_url = child_url,
      subject_ref = child_base,
      byte_size = index_source_byte_size(child_source),
      fetched_at = NA,
      source_meta = NULL,
      ruleset = ruleset
    )
    parts <- append_robots_part(
      parts,
      child_rows$loc,
      robots_ua,
      child_base,
      page_sink,
      child_rows$alternates
    )
  }
  parts
}

# Build a fetch-layer finding for a source that failed during batched
# validation. Scalar validate_sitemap() calls still propagate these conditions.
validate_failure_finding <- function(source, cnd) {
  code <- if (inherits(cnd, "sitemapr_timeout")) {
    "FETCH_TIMEOUT"
  } else if (inherits(cnd, "sitemapr_body_ceiling")) {
    "FETCH_BODY_CEILING_EXCEEDED"
  } else {
    "FETCH_FAILED"
  }
  subject <- source$normalized_url[[1L]]
  tibble::tibble(
    code = code,
    severity = "fatal",
    layer = "fetch",
    subject_type = "source",
    subject_ref = sitemap_subject_ref(subject),
    message = sprintf(
      "Submitted sitemap source %s failed: %s",
      subject,
      conditionMessage(cnd)
    ),
    evidence = list(finding_evidence(excerpt = subject)),
    is_strict_only = FALSE
  )
}

# Resolve the robots matcher user-agent for a call, or NULL when the robots
# allow/disallow check is not active. Returns NULL when `check_robots` is FALSE.
# When `check_robots` is TRUE but the optional `robotstxtr` engine is not
# installed, this signals a classed warning naming the install command (the
# absence is a setup fact about the user's machine, NOT a finding about the
# sitemap) and returns NULL so validation proceeds with every other layer
# unaffected. Otherwise it returns the matcher user-agent to test against.
resolve_robots_ua <- function(check_robots, robots_user_agent) {
  if (!isTRUE(check_robots)) {
    return(NULL)
  }
  if (!robotstxtr_available()) {
    rlang::warn(
      sprintf(
        paste0(
          "robots allow/disallow check skipped: the optional 'robotstxtr' ",
          "package is not installed. Install it with %s."
        ),
        robotstxtr_install_hint()
      ),
      class = "sitemapr_robots_unavailable"
    )
    return(NULL)
  }
  robots_user_agent
}

# A page-inspection loc sink: a mutable env accumulating every advertised loc
# and the sitemap base that advertised it, across every source of a validate
# call, so batch-wide page inspection (E.1f) fetches the union of the call's
# deduped locs and anchors each transport finding to its advertising
# subject_ref. Created only when `inspect_pages = TRUE`; NULL otherwise.
page_sink_new <- function() {
  sink <- new.env(parent = emptyenv())
  sink$loc <- character(0)
  sink$base <- character(0)
  # Parallel to loc/base: the sitemap-DECLARED hreflang alternates for that
  # advertising occurrence (the row's `alternates` list-column entry, or NULL
  # when the source declares none / carries no such column). Consumed by the
  # E.4 page-hreflang reconciliation; ignored by transport / canonical.
  sink$alt <- list()
  sink
}

# Record advertised `locs` (from the same rows-bearing branch that feeds the
# robots check) into the sink, tagged with the advertising sitemap `base`. A
# no-op when `sink` is NULL, so the byte-identical inspect_pages = FALSE path is
# untouched. Blank/NA locs are dropped; page_inspection_dedup() drops any
# remaining non-http(s)/unparseable ones from eligibility.
page_sink_add <- function(sink, locs, base, alternates = NULL) {
  if (is.null(sink)) {
    return(invisible(NULL))
  }
  locs <- as.character(locs)
  keep <- !is.na(locs) & nzchar(locs)
  locs <- locs[keep]
  if (length(locs) == 0L) {
    return(invisible(NULL))
  }
  # The declared-alternates list runs parallel to the RAW loc vector (a row per
  # advertised URL); subset it by the same keep mask so it stays aligned. A
  # source without an `alternates` column (text sitemaps) contributes NULLs.
  alts <- if (is.null(alternates)) {
    vector("list", length(locs))
  } else {
    as.list(alternates)[keep]
  }
  sink$loc <- c(sink$loc, locs)
  sink$base <- c(sink$base, rep(base, length(locs)))
  sink$alt <- c(sink$alt, alts)
  invisible(NULL)
}

# Append a robots-layer producer part for the advertised `locs` to `parts` when
# the robots check is active (`robots_ua` non-NULL), and record the same locs
# into the page-inspection `sink` when one is active. The sink record runs
# regardless of the robots check (page inspection is independent of it); both
# are no-ops when their gate is NULL, so the rows-bearing branches can call this
# unconditionally and the inspect_pages = FALSE path stays byte-identical.
append_robots_part <- function(
  parts,
  locs,
  robots_ua,
  base,
  sink = NULL,
  alternates = NULL
) {
  page_sink_add(sink, locs, base, alternates)
  if (is.null(robots_ua)) {
    return(parts)
  }
  parts[[length(parts) + 1L]] <- validate_robots(locs, robots_ua, base)
  parts
}

# Validate one normalized source record. This is the former scalar
# validate_sitemap() body, factored so batched calls can continue per source.
validate_sitemap_source <- function(
  source,
  mode,
  user_agent,
  limits,
  index_limits,
  policy,
  robots_ua = NULL,
  ruleset = NULL,
  page_sink = NULL
) {
  # A corrupt/truncated gzip stream (the `.xml.gz`/`.txt.gz` case, or a
  # `.tar.gz` with a bad outer gzip) makes source resolution raise; catch it and
  # surface UNSUPPORTED_MALFORMED_GZIP rather than propagating the condition. A
  # genuine transport / SSRF / HTTP failure still propagates.
  src <- tryCatch(
    resolve_validation_source(source, user_agent, limits, policy),
    sitemapr_decompression_error = function(cnd) {
      list(
        kind = "malformed-gzip",
        base = sitemap_subject_ref(source$normalized_url[[1L]]),
        cnd = cnd
      )
    }
  )
  # The robots allow/disallow check rides on the resolved source so each
  # rows-bearing branch can feed the advertised `<loc>`s to validate_robots()
  # without a threaded argument (NULL = check inactive). The page-inspection
  # sink rides the same way: each rows-bearing branch records its advertised
  # locs into it via append_robots_part (NULL = page inspection off).
  src$robots_ua <- robots_ua
  src$page_sink <- page_sink

  parts <- if (identical(src$kind, "malformed-gzip")) {
    list(decompression_source_finding(
      "UNSUPPORTED_MALFORMED_GZIP",
      src$base,
      conditionMessage(src$cnd)
    ))
  } else if (identical(src$kind, "archive")) {
    validate_archive_parts(src, ruleset)
  } else if (identical(src$format, "html")) {
    list(validate_classification(source_meta(html_masquerade = TRUE), src$base))
  } else if (identical(src$format, "text")) {
    text <- rawToChar(src$bytes)
    append_robots_part(
      list(validate_text_protocol(text, src$base)),
      strsplit(text, "\r\n|\r|\n", perl = TRUE)[[1L]],
      src$robots_ua,
      src$base,
      src$page_sink
    )
  } else if (identical(src$format, "feed")) {
    validate_feed_parts(src, user_agent, limits, index_limits, policy, ruleset)
  } else {
    validate_xml_parts(src, user_agent, limits, index_limits, policy, ruleset)
  }

  assemble_findings(parts, mode, ruleset)
}

# Row-bind already assembled findings contracts from per-source validation. The
# per-source contracts are already stamped with the additive columns when an
# engine `ruleset` is active, so the column set widens to match; the baseline
# (`ruleset = NULL`) path keeps the pinned ten columns unchanged.
combine_findings_contracts <- function(parts, ruleset = NULL) {
  parts <- parts[vapply(parts, nrow, integer(1L)) > 0L]
  if (length(parts) == 0L) {
    return(findings_stamp_ruleset(empty_findings_contract(), ruleset))
  }
  findings <- do.call(rbind, parts)
  findings <- findings_dedup(findings)
  findings <- findings_sort(findings)
  cols <- names(empty_findings_contract())
  if (!is.null(ruleset)) {
    cols <- c(cols, findings_additive_cols())
  }
  findings <- findings[, cols, drop = FALSE]
  tibble::new_tibble(findings, nrow = nrow(findings))
}

# Validate multiple normalized source records, converting source-level failures
# into fetch-layer findings so successful sources still contribute rows.
validate_sitemap_batch <- function(
  sources,
  mode,
  user_agent,
  limits,
  index_limits,
  policy,
  robots_ua = NULL,
  ruleset = NULL,
  page_sink = NULL
) {
  parts <- list()
  for (i in seq_len(nrow(sources))) {
    source <- sources[i, , drop = FALSE]
    parts[[length(parts) + 1L]] <- tryCatch(
      suppressWarnings(
        validate_sitemap_source(
          source,
          mode,
          user_agent,
          limits,
          index_limits,
          policy,
          robots_ua,
          ruleset,
          page_sink
        )
      ),
      error = function(cnd) {
        assemble_findings(
          list(validate_failure_finding(source, cnd)),
          mode,
          ruleset
        )
      }
    )
  }
  combine_findings_contracts(parts, ruleset)
}

# Build the engine-aware ruleset spec threaded through the pipeline to the
# findings assembler, or NULL for the baseline path. The baseline
# `"sitemaps.org"` returns NULL so the schema-v1 ten-column contract is emitted
# unchanged (no additive columns, ADR-009 §5/§6); an engine overlay returns the
# selected ruleset, its published revision, and the per-source context, stamped
# by the assembler as the four additive columns.
findings_ruleset_spec <- function(sitemap_ruleset, context) {
  if (identical(sitemap_ruleset, "sitemaps.org")) {
    return(NULL)
  }
  list(
    ruleset = sitemap_ruleset,
    ruleset_revision = ruleset_revision(sitemap_ruleset),
    context = context
  )
}

#' Validate a sitemap source against the schema, protocol, and classification
#' rules
#'
#' The public validation entry point. Reads one or more sitemap sources —
#' sitemap URLs or local sitemap files — runs every finding-producer over them
#' (the XSD schema layer, the protocol/semantic layer, the byte-level
#' classification layer, and, for a sitemap index, the bounded index-expansion
#' layer), and assembles the results into the stable findings contract.
#'
#' The source is read once and branched on its sniffed format: an HTML document
#' served where a sitemap was expected yields an `UNSUPPORTED_HTML_MASQUERADE`
#' classification finding; a plain-text sitemap is checked line-by-line; an
#' RSS 2.0 or Atom 0.3/1.0 feed is parsed into rows and protocol-validated; an
#' XML document is dispatched on its root element. An XML root that is neither
#' `urlset` nor `sitemapindex` yields an `UNSUPPORTED_ROOT` finding rather than
#' an error. A `urlset` is schema- and protocol-validated; a `sitemapindex` is
#' schema-validated and recursively expanded (cycle-, depth-, and count-capped),
#' with the traversal events surfaced as `INDEX_*` findings.
#'
#' When `x` contains more than one source, inputs are normalized, deduplicated,
#' and capped using the submitted-list source-record policy. Per-source failures
#' are returned as fetch-layer findings and successful sources still contribute
#' their findings. Scalar calls keep the stricter historical behavior: genuine
#' transport, SSRF, or HTTP failures raise classed conditions.
#'
#' When `check_robots = TRUE`, each sitemap-advertised URL is additionally
#' tested against its governing robots.txt (via the optional `robotstxtr`
#' engine), emitting `robots`-layer findings for URLs that are disallowed
#' (`ROBOTS_DISALLOWED`, `warning`) or that cannot be decided because robots.txt
#' would not fetch (`ROBOTS_INDETERMINATE`, `info`). Each distinct origin's
#' robots.txt is fetched once under the SSRF-guarded fetch policy; matching is
#' offline, so every advertised URL is checked with no sampling. When
#' `robotstxtr` is not installed, a classed warning naming the install command
#' is signalled and the check is skipped; every other layer is unaffected.
#'
#' @param mode `"strict"` (the default) or `"non-strict"`. In `non-strict`,
#'   strict-only findings are dropped and schema violations are downgraded to
#'   `warning`; in `strict`, the documented info-to-warning codes are elevated.
#' @param check_robots Logical; when `TRUE`, run the robots.txt allow/disallow
#'   check over the advertised URLs (requires the optional `robotstxtr`
#'   package). Defaults to `FALSE`.
#' @param robots_user_agent The robots.txt group to match against when
#'   `check_robots = TRUE`, e.g. `"*"` (the catch-all group, the default) or a
#'   specific crawler token such as `"Googlebot"`.
#' @param inspect_pages Logical; the master opt-in for per-URL page inspection
#'   (Layer E). When `FALSE` (the default) no page is fetched and the result is
#'   byte-identical to a call without it: the pinned ten-column findings surface
#'   and no `page_coverage` attribute. When `TRUE`, a budgeted, deduplicated,
#'   deterministically-sampled set of the advertised page URLs is fetched and
#'   each fetch's transport outcome maps to at most one `page`-layer finding
#'   (`PAGE_STATUS_ERROR`, `PAGE_STATUS_REDIRECT`, `PAGE_REDIRECT_CHAIN`,
#'   `PAGE_FETCH_FAILED`, `PAGE_SSRF_BLOCKED`); the run's coverage rides the
#'   `page_coverage` attribute (see Value). Network expansion is never
#'   implicit. Page inspection is batch-wide: one budget over the union of the
#'   call's deduped page URLs.
#' @param page_sample Integer sample size for `page_mode = "sample"`: how many
#'   of the deduplicated page URLs to inspect, chosen by a deterministic stable
#'   hash order so re-runs pick the same set. Ignored when `page_mode = "full"`.
#' @param page_mode `"sample"` (inspect `page_sample` deduplicated URLs, the
#'   default) or `"full"` (inspect every deduplicated URL, subject to the
#'   budget caps).
#' @param page_budget A page-inspection budget list: the aggregate caps (max
#'   pages, max requests/hops, max aggregate bytes, per-page body cap, max wall
#'   time), each caller-overridable with a safe default. Applies only when
#'   `inspect_pages = TRUE`.
#' @param page_user_agent The HTTP request User-Agent sent when fetching pages
#'   (recorded for the "what did the inspector see" caveat; distinct from a
#'   robots product token). Defaults to sitemapr's inspector UA.
#' @inheritParams read_sitemap
#' @return The findings tibble described in `docs/findings-contract.md`: the
#'   columns `code`, `severity`, `layer`, `subject_type`, `subject_ref`,
#'   `message`, `evidence`, `mode`, `is_strict_only`, and `remediation_hint`, in
#'   the contract's stable order. The same source and mode yield a row-for-row
#'   identical tibble across calls. A genuine transport, SSRF, or HTTP failure
#'   raises a classed error condition. When `inspect_pages = TRUE`, the tibble
#'   additionally carries a `page_coverage` attribute (`attr(x,
#'   "page_coverage")`) — a versioned, batch-wide named list reporting what the
#'   run covered (`eligible`, `deduplicated`, `selected`, `attempted`,
#'   `completed`, `partial`, and which caps bit) so a sampled or capped run is
#'   never misread as clean; it is absent when `inspect_pages = FALSE`.
#' @export
#' @examples
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   '<url><loc>https://example.com/</loc>',
#'   '<priority>2.0</priority></url>',
#'   '</urlset>'
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#' validate_sitemap(path, mode = "non-strict")
#'
#' # Validate directly from a sitemap URL.
#' # validate_sitemap("https://example.com/sitemap.xml")
validate_sitemap <- function(
  x,
  mode = c("strict", "non-strict"),
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL,
  policy = request_policy(),
  check_robots = FALSE,
  robots_user_agent = "*",
  inspect_pages = FALSE,
  page_sample = 50L,
  page_mode = c("sample", "full"),
  page_budget = page_inspection_budget(),
  page_user_agent = default_user_agent()
) {
  mode <- match.arg(mode)
  page_mode <- match.arg(page_mode)
  sources <- sitemap_public_source_records(x)
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }
  robots_ua <- resolve_robots_ua(check_robots, robots_user_agent)
  # The page-inspection sink is created ONLY when inspect_pages is on; it stays
  # NULL otherwise so the loc-gathering plumbing is a strict no-op and the
  # result is byte-identical to a call without page inspection.
  page_sink <- if (isTRUE(inspect_pages)) page_sink_new() else NULL

  base <- if (length(x) == 1L) {
    validate_sitemap_source(
      sources[1L, , drop = FALSE],
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy,
      robots_ua = robots_ua,
      page_sink = page_sink
    )
  } else {
    validate_sitemap_batch(
      sources,
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy,
      robots_ua = robots_ua,
      page_sink = page_sink
    )
  }

  if (!isTRUE(inspect_pages)) {
    return(base)
  }
  page_inspection_finalize(
    base = base,
    sink = page_sink,
    mode = mode,
    ruleset = NULL,
    budget = page_budget,
    sample_size = page_sample,
    page_mode = page_mode,
    user_agent = page_user_agent,
    limits = limits,
    policy = policy
  )
}

#' @rdname validate_sitemap
#' @export
validate_sitemaps <- function(
  x,
  mode = c("strict", "non-strict"),
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL,
  policy = request_policy(),
  check_robots = FALSE,
  robots_user_agent = "*",
  inspect_pages = FALSE,
  page_sample = 50L,
  page_mode = c("sample", "full"),
  page_budget = page_inspection_budget(),
  page_user_agent = default_user_agent()
) {
  validate_sitemap(
    x,
    mode = mode,
    user_agent = user_agent,
    limits = limits,
    index_limits = index_limits,
    policy = policy,
    check_robots = check_robots,
    robots_user_agent = robots_user_agent,
    inspect_pages = inspect_pages,
    page_sample = page_sample,
    page_mode = page_mode,
    page_budget = page_budget,
    page_user_agent = page_user_agent
  )
}

#' Validate a sitemap under an engine-aware ruleset (ADR-009)
#'
#' The versioned, engine-aware entry point parallel to [validate_sitemap()]. It
#' runs the identical validation pipeline (the XSD schema, protocol/semantic,
#' byte-level classification, and bounded index-expansion layers), then, when an
#' engine overlay is selected, augments the findings tibble with the additive
#' schema-v2 columns (`docs/decisions/ADR-009-per-engine-validation-profiles.md`
#' §5/§6, `docs/findings-contract.md` "Per-engine ruleset extension").
#'
#' Backwards compatibility is preserved by construction (ADR-009 §5): a baseline
#' call (`sitemap_ruleset = "sitemaps.org"`, the default) returns exactly the
#' pinned ten-column schema-v1 result, byte-identical to [validate_sitemap()].
#' The four additive columns appear **only** for an explicit engine overlay
#' (`"google"` / `"bing"` / `"yandex"`); there is deliberately no `profile=`
#' argument on [validate_sitemap()] and no silent default switch to an engine.
#'
#' This slice fixes the engine-aware carrier and the additive schema; no
#' per-engine evaluators exist yet, so every finding produced under an overlay
#' is a reused baseline code and carries `provenance = "inherited_protocol"` (an
#' ADR-009 §0 executable class). Later slices override the provenance per code.
#'
#' Per-URL page inspection (`inspect_pages = TRUE`) works exactly as in
#' [validate_sitemap()], except the transport / canonical / hreflang page
#' findings are assembled under the selected `sitemap_ruleset` too: under an
#' engine overlay they carry the same additive schema-v2 columns as the base
#' findings, so the per-engine provenance / context (ADR-009 §5.2/§5.3) engages
#' over the page layer rather than emitting as generic baseline diagnostics. As
#' in [validate_sitemap()], `inspect_pages = FALSE` is byte-identical to a call
#' without the argument.
#'
#' @param sitemap_ruleset The engine ruleset to validate under; one of
#'   [sitemap_rulesets()] (baseline `"sitemaps.org"` first, the default). The
#'   baseline emits the schema-v1 result; an engine overlay adds the additive
#'   columns.
#' @param context A per-source validation context from [ruleset_context()] (the
#'   four independent ADR-009 §1 axes). Carried into the `context` list-column
#'   of the additive result. Ignored on the baseline path (which emits no
#'   additive columns).
#' @inheritParams validate_sitemap
#' @return The findings tibble of [validate_sitemap()]. Under the baseline
#'   `sitemap_ruleset` it is exactly the pinned ten columns; under an engine
#'   overlay it additionally carries `ruleset` (character), `ruleset_revision`
#'   (character), `context` (a list-column of the context object as a named
#'   list), and `provenance` (character, per finding), appended in that order
#'   after the ten pinned columns. The same source, mode, ruleset, and context
#'   yield a row-for-row identical tibble across calls.
#' @seealso [validate_sitemap()] for the baseline entry point,
#'   [sitemap_rulesets()] for the ruleset value set, and [ruleset_context()] for
#'   the per-source context axes.
#' @export
#' @examples
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   '<url><loc>https://example.com/</loc></url>',
#'   '</urlset>'
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#'
#' # Baseline: identical to validate_sitemap().
#' validate_sitemap_ruleset(path, "sitemaps.org")
#'
#' # Engine overlay: adds the additive schema-v2 columns.
#' validate_sitemap_ruleset(path, "google")
validate_sitemap_ruleset <- function(
  x,
  sitemap_ruleset = sitemap_rulesets(),
  context = ruleset_context(),
  mode = c("strict", "non-strict"),
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL,
  policy = request_policy(),
  check_robots = FALSE,
  robots_user_agent = "*",
  inspect_pages = FALSE,
  page_sample = 50L,
  page_mode = c("sample", "full"),
  page_budget = page_inspection_budget(),
  page_user_agent = default_user_agent()
) {
  sitemap_ruleset <- match.arg(sitemap_ruleset, sitemap_rulesets())
  mode <- match.arg(mode)
  page_mode <- match.arg(page_mode)
  sources <- sitemap_public_source_records(x)
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }
  robots_ua <- resolve_robots_ua(check_robots, robots_user_agent)
  ruleset <- findings_ruleset_spec(sitemap_ruleset, context)
  # As in validate_sitemap(): the sink exists only when inspect_pages is on, so
  # the loc-gathering plumbing is a strict no-op and the baseline/engine result
  # is byte-identical to a call without page inspection.
  page_sink <- if (isTRUE(inspect_pages)) page_sink_new() else NULL

  base <- if (length(x) == 1L) {
    validate_sitemap_source(
      sources[1L, , drop = FALSE],
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy,
      robots_ua = robots_ua,
      ruleset = ruleset,
      page_sink = page_sink
    )
  } else {
    validate_sitemap_batch(
      sources,
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy,
      robots_ua = robots_ua,
      ruleset = ruleset,
      page_sink = page_sink
    )
  }

  if (!isTRUE(inspect_pages)) {
    return(base)
  }
  # Unlike validate_sitemap() (ruleset = NULL), the page-layer findings are
  # assembled + combined under the SAME engine `ruleset` as the base result, so
  # the per-engine provenance / context columns (ADR-009 §5.2/§5.3) engage over
  # the transport / canonical / hreflang page findings too.
  page_inspection_finalize(
    base = base,
    sink = page_sink,
    mode = mode,
    ruleset = ruleset,
    budget = page_budget,
    sample_size = page_sample,
    page_mode = page_mode,
    user_agent = page_user_agent,
    limits = limits,
    policy = policy
  )
}

#' @rdname validate_sitemap_ruleset
#' @export
validate_sitemaps_ruleset <- function(
  x,
  sitemap_ruleset = sitemap_rulesets(),
  context = ruleset_context(),
  mode = c("strict", "non-strict"),
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL,
  policy = request_policy(),
  check_robots = FALSE,
  robots_user_agent = "*",
  inspect_pages = FALSE,
  page_sample = 50L,
  page_mode = c("sample", "full"),
  page_budget = page_inspection_budget(),
  page_user_agent = default_user_agent()
) {
  validate_sitemap_ruleset(
    x,
    sitemap_ruleset = sitemap_ruleset,
    context = context,
    mode = mode,
    user_agent = user_agent,
    limits = limits,
    index_limits = index_limits,
    policy = policy,
    check_robots = check_robots,
    robots_user_agent = robots_user_agent,
    inspect_pages = inspect_pages,
    page_sample = page_sample,
    page_mode = page_mode,
    page_budget = page_budget,
    page_user_agent = page_user_agent
  )
}
