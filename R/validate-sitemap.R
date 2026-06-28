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
# non-XML/non-text source (HTML masquerade), and RSS/Atom feed children of an
# index are classification findings, not thrown errors. A genuine transport /
# SSRF / timeout / non-2xx failure still propagates as the existing classed
# condition from `fetch_source()` (v1 minimal; no activated feature requires
# otherwise).

# A resolved source: the (possibly decompressed) bytes, the sniffed format of
# those bytes, the uncompressed byte count, the document-level subject_ref base,
# and the final URL (NA for a local file, so the protocol scope check is
# skipped). `fetched_at` is NA: source_metadata() carries no fetch timestamp, so
# the PROTOCOL_LASTMOD_LOOKS_GENERATED corpus heuristic is skipped (the protocol
# producer treats NA `fetched_at` as "skip").
resolve_validation_source <- function(x, user_agent, limits) {
  if (file.exists(x)) {
    bytes <- readBin(x, what = "raw", n = file.info(x)$size)
    final_url <- NA_character_
  } else {
    rec <- fetch_source(x, user_agent = user_agent, limits = limits)
    if (!is.na(rec$error_class)) {
      rlang::abort(
        sprintf(
          "Entry-point fetch of %s failed with HTTP %s.", rec$final_url,
          rec$status
        ),
        class = "sitemapr_entrypoint_error",
        url = rec$final_url, status = rec$status
      )
    }
    bytes <- attr(rec, "body")
    final_url <- rec$final_url
  }

  fmt <- sniff_format(bytes)
  if (identical(fmt, "gzip")) {
    bytes <- gzip_decompress(bytes)
    fmt <- sniff_format(bytes)
  }

  list(
    bytes = bytes,
    format = fmt,
    byte_size = as.numeric(length(bytes)),
    final_url = final_url,
    base = sitemap_subject_ref(if (is.na(final_url)) x else final_url),
    fetched_at = NA # TODO(layer-f-encoding) + no fetch-timestamp in source_meta
  )
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
        base, paste0("#index-child:", problems$subject_ref[i])
      ),
      message = problems$message[i],
      evidence = list(protocol_evidence(excerpt = problems$subject_ref[i])),
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
index_findings <- function(code = character(0),
                           severity = character(0),
                           subject_type = character(0),
                           subject_ref = character(0),
                           message = character(0),
                           evidence = list(),
                           is_strict_only = logical(0)) {
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

# Build the producer `parts` list for an XML source, branching on the root
# local-name. `src` is a resolved source; `index_limits` bounds the expansion.
validate_xml_parts <- function(src, user_agent, limits, index_limits) {
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
        rows, sitemap_url = src$final_url, subject_ref = src$base,
        byte_size = src$byte_size, fetched_at = src$fetched_at,
        source_meta = NULL
      )
    ))
  }

  # sitemapindex: schema + bounded expansion. The expansion problems become
  # INDEX_* findings; RSS/Atom feed children become UNSUPPORTED_FEED; the rows
  # gathered from leaf children feed the protocol layer.
  validate_index_parts(src, schema, doc, user_agent, limits, index_limits)
}

# Assemble the producer parts for a `sitemapindex` root. A local index has no
# origin URL to fetch children from, so expansion only runs for a URL source.
validate_index_parts <- function(src, schema, doc, user_agent, limits,
                                 index_limits) {
  parts <- list(schema)
  if (is.na(src$final_url)) {
    return(parts)
  }

  children <- parse_sitemapindex(xml2::xml_root(doc))
  ex <- expand_index(
    src$final_url, children, depth = 0L,
    user_agent = user_agent, limits = index_limits, net_limits = limits
  )

  parts[[length(parts) + 1L]] <-
    index_findings_from_problems(ex$problems, src$base)

  # A child the expander fetched and sniffed as an RSS/Atom feed -> one
  # UNSUPPORTED_FEED per child via the existing source_meta/classification path.
  # (A TOP-LEVEL feed source — src$format == "feed" at the entrypoint, no index
  # — is OUT OF SCOPE for v1: the XML branch yields UNSUPPORTED_ROOT for it.)
  feeds <- index_feed_children(ex$sources)
  if (length(feeds) > 0L) {
    parts[[length(parts) + 1L]] <- validate_classification(
      source_meta(feed_children = feeds), src$base
    )
  }

  if (nrow(ex$rows) > 0L) {
    parts[[length(parts) + 1L]] <- validate_protocol(
      ex$rows, sitemap_url = src$final_url, subject_ref = src$base,
      byte_size = src$byte_size, fetched_at = src$fetched_at,
      source_meta = NULL
    )
  }
  parts
}

# Final URLs of the expansion `sources` records the byte-sniffer classified as
# an RSS/Atom feed ("feed"). These drive one UNSUPPORTED_FEED finding each.
index_feed_children <- function(sources) {
  if (is.null(sources) || nrow(sources) == 0L) {
    return(character(0))
  }
  is_feed <- as.character(sources$format) == "feed"
  as.character(sources$final_url[is_feed])
}

#' Validate a sitemap source against the schema, protocol, and classification
#' rules
#'
#' The public validation entry point. Reads a single sitemap source — a sitemap
#' URL or a local sitemap file — runs every finding-producer over it (the XSD
#' schema layer, the protocol/semantic layer, the byte-level classification
#' layer, and, for a sitemap index, the bounded index-expansion layer), and
#' assembles the results into the stable findings contract.
#'
#' The source is read once and branched on its sniffed format: an HTML document
#' served where a sitemap was expected yields an `UNSUPPORTED_HTML_MASQUERADE`
#' classification finding; a plain-text sitemap is checked line-by-line; an XML
#' document is dispatched on its root element. An XML root that is neither
#' `urlset` nor `sitemapindex` yields an `UNSUPPORTED_ROOT` finding rather than
#' an error. A `urlset` is schema- and protocol-validated; a `sitemapindex` is
#' schema-validated and recursively expanded (cycle-, depth-, and count-capped),
#' with the traversal events surfaced as `INDEX_*` findings.
#'
#' @param x A single source: a sitemap URL (character) or a path to a local
#'   sitemap file.
#' @param mode `"strict"` (the default) or `"non-strict"`. In `non-strict`,
#'   strict-only findings are dropped and schema violations are downgraded to
#'   `warning`; in `strict`, the documented info-to-warning codes are elevated.
#' @param user_agent The User-Agent header for HTTP fetches. Defaults to the
#'   package User-Agent.
#' @param limits Network limits for HTTP fetches, as from `fetch_limits()`.
#' @param index_limits Sitemapindex-expansion bounds (recursion depth and
#'   per-index child-count cap), as from `index_limits()`. Defaults to
#'   `index_limits()`.
#' @return The findings tibble described in `docs/findings-contract.md`: the
#'   columns `code`, `severity`, `layer`, `subject_type`, `subject_ref`,
#'   `message`, `evidence`, `mode`, `is_strict_only`, and `remediation_hint`, in
#'   the contract's stable order. The same source and mode yield a row-for-row
#'   identical tibble across calls. A genuine transport, SSRF, or HTTP failure
#'   raises a classed error condition.
#' @export
#' @examples
#' \dontrun{
#' validate_sitemap("https://example.com/sitemap.xml")
#' validate_sitemap("path/to/sitemap.xml", mode = "non-strict")
#' }
validate_sitemap <- function(x,
                             mode = c("strict", "non-strict"),
                             user_agent = default_user_agent(),
                             limits = fetch_limits(),
                             index_limits = NULL) {
  mode <- match.arg(mode)
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    rlang::abort(
      "`x` must be a single non-empty source: a URL or a local file path.",
      class = "sitemapr_bad_input"
    )
  }
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }

  src <- resolve_validation_source(x, user_agent, limits)

  parts <- if (identical(src$format, "html")) {
    list(validate_classification(source_meta(html_masquerade = TRUE), src$base))
  } else if (identical(src$format, "text")) {
    list(validate_text_protocol(rawToChar(src$bytes), src$base))
  } else {
    validate_xml_parts(src, user_agent, limits, index_limits)
  }

  assemble_findings(parts, mode)
}
