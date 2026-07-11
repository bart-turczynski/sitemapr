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
validate_archive_parts <- function(src) {
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
      source_meta = NULL
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
validate_feed_parts <- function(src, user_agent, limits, index_limits, policy) {
  parsed <- tryCatch(
    parse_feed(src$bytes, source_sitemap = src$final_url),
    sitemapr_unsupported_feed = function(cnd) NULL
  )
  if (is.null(parsed)) {
    return(validate_xml_parts(src, user_agent, limits, index_limits, policy))
  }
  list(validate_protocol(
    parsed$rows,
    sitemap_url = src$final_url,
    subject_ref = src$base,
    byte_size = src$byte_size,
    fetched_at = src$fetched_at,
    source_meta = NULL
  ))
}

# Build the producer `parts` list for an XML source, branching on the root
# local-name. `src` is a resolved source; `index_limits` bounds the expansion.
validate_xml_parts <- function(src, user_agent, limits, index_limits, policy) {
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
    return(list(
      schema,
      validate_protocol(
        rows,
        sitemap_url = src$final_url,
        subject_ref = src$base,
        byte_size = src$byte_size,
        fetched_at = src$fetched_at,
        source_meta = NULL
      )
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
    policy
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
  policy
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
    parts <- c(parts, index_protocol_parts(ex$rows, ex$sources, src$base))
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

index_protocol_parts <- function(rows, sources, fallback_base) {
  if (is.null(rows) || nrow(rows) == 0L) {
    return(list())
  }

  sitemap_url <- as.character(rows$source_sitemap)
  known <- !is.na(sitemap_url) & nzchar(sitemap_url)
  if (!any(known)) {
    return(list(validate_protocol(
      rows,
      sitemap_url = NA_character_,
      subject_ref = fallback_base,
      byte_size = NA_real_,
      fetched_at = NA,
      source_meta = NULL
    )))
  }

  groups <- split(which(known), sitemap_url[known], drop = TRUE)
  parts <- vector("list", length(groups))
  for (i in seq_along(groups)) {
    child_url <- names(groups)[[i]]
    child_source <- index_source_row(sources, child_url)
    parts[[i]] <- validate_protocol(
      rows[groups[[i]], , drop = FALSE],
      sitemap_url = child_url,
      subject_ref = sitemap_subject_ref(child_url),
      byte_size = index_source_byte_size(child_source),
      fetched_at = NA,
      source_meta = NULL
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

# Validate one normalized source record. This is the former scalar
# validate_sitemap() body, factored so batched calls can continue per source.
validate_sitemap_source <- function(
  source,
  mode,
  user_agent,
  limits,
  index_limits,
  policy
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

  parts <- if (identical(src$kind, "malformed-gzip")) {
    list(decompression_source_finding(
      "UNSUPPORTED_MALFORMED_GZIP",
      src$base,
      conditionMessage(src$cnd)
    ))
  } else if (identical(src$kind, "archive")) {
    validate_archive_parts(src)
  } else if (identical(src$format, "html")) {
    list(validate_classification(source_meta(html_masquerade = TRUE), src$base))
  } else if (identical(src$format, "text")) {
    list(validate_text_protocol(rawToChar(src$bytes), src$base))
  } else if (identical(src$format, "feed")) {
    validate_feed_parts(src, user_agent, limits, index_limits, policy)
  } else {
    validate_xml_parts(src, user_agent, limits, index_limits, policy)
  }

  assemble_findings(parts, mode)
}

# Row-bind already assembled findings contracts from per-source validation.
combine_findings_contracts <- function(parts) {
  parts <- parts[vapply(parts, nrow, integer(1L)) > 0L]
  if (length(parts) == 0L) {
    return(empty_findings_contract())
  }
  findings <- do.call(rbind, parts)
  findings <- findings_dedup(findings)
  findings <- findings_sort(findings)
  cols <- names(empty_findings_contract())
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
  policy
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
          policy
        )
      ),
      error = function(cnd) {
        assemble_findings(
          list(validate_failure_finding(source, cnd)),
          mode
        )
      }
    )
  }
  combine_findings_contracts(parts)
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
#' @param mode `"strict"` (the default) or `"non-strict"`. In `non-strict`,
#'   strict-only findings are dropped and schema violations are downgraded to
#'   `warning`; in `strict`, the documented info-to-warning codes are elevated.
#' @inheritParams read_sitemap
#' @return The findings tibble described in `docs/findings-contract.md`: the
#'   columns `code`, `severity`, `layer`, `subject_type`, `subject_ref`,
#'   `message`, `evidence`, `mode`, `is_strict_only`, and `remediation_hint`, in
#'   the contract's stable order. The same source and mode yield a row-for-row
#'   identical tibble across calls. A genuine transport, SSRF, or HTTP failure
#'   raises a classed error condition.
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
  policy = request_policy()
) {
  mode <- match.arg(mode)
  sources <- sitemap_public_source_records(x)
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }

  if (length(x) == 1L) {
    validate_sitemap_source(
      sources[1L, , drop = FALSE],
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy
    )
  } else {
    validate_sitemap_batch(
      sources,
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy
    )
  }
}

#' @rdname validate_sitemap
#' @export
validate_sitemaps <- function(
  x,
  mode = c("strict", "non-strict"),
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL,
  policy = request_policy()
) {
  validate_sitemap(
    x,
    mode = mode,
    user_agent = user_agent,
    limits = limits,
    index_limits = index_limits,
    policy = policy
  )
}
