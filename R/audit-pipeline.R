# audit_sitemap(): the single-pass audit pipeline (SITE-zkjoglmx).
#
# read_sitemap() and validate_sitemap() each fetch and parse a source
# INDEPENDENTLY, so producing both a URL table and a findings contract for the
# same source (as report_sitemap() does) fetches every remote root — and every
# index child — TWICE. audit_sitemap() resolves each source ONCE into a shared
# "resolved-source artifact" and projects BOTH the typed URL rows (read_sitemap
# semantics) AND the findings (validate_sitemap semantics) from it.
#
# It does NOT modify or call read_sitemap()/validate_sitemap(); it builds a
# PARALLEL single-pass path that reuses their low-level machinery
# (fetch_source(), sniff_format(), gzip_decompress(), read_sitemap_xml(),
# parse_sitemap_xml(), parse_dispatch(), expand_index(), and validate's
# projection layers). The output is the existing `sitemap_audit` container,
# assembled with `sitemap_audit()`.
#
# Equivalence is the acceptance bar: on any source where read_sitemap()
# succeeds, audit_urls() matches its rows; on any source where
# validate_sitemap() succeeds, audit_findings() matches its findings. This holds
# because the artifact reuses the exact same low-level calls, sharing only the
# single fetch and the single expand_index() call that today are duplicated.

# The single fetch/read of one source, decompressed and sniffed once. For a URL
# `sitemapindex` the bounded `expand_index()` is run ONCE here and its result is
# stashed on `ex`, so both projections consume the same expansion (children are
# fetched once, not twice). `kind` routes the two projections:
#   "malformed-gzip" a corrupt outer gzip stream (records a decompression
#                    problem for the read side, UNSUPPORTED_MALFORMED_GZIP for
#                    the findings side)
#   "archive"        a local `.tar.gz` (extracted per projection, local-only)
#   "document"       decompressed bytes + sniffed `format`; for XML `root` names
#                    the element and `ex` holds any URL-index expansion.
audit_resolve_source <- function(
  source,
  user_agent,
  limits,
  index_limits,
  policy
) {
  is_local <- isTRUE(source$is_local_file[[1L]])
  target <- source$normalized_url[[1L]]

  read_bytes <- audit_fetch_bytes(source, is_local, user_agent, limits, policy)
  bytes_raw <- read_bytes$bytes
  final_url <- read_bytes$final_url
  root_meta <- read_bytes$root_meta

  raw_fmt <- sniff_format(bytes_raw)
  base <- sitemap_subject_ref(if (is.na(final_url)) target else final_url)

  # Inflate a gzip stream ONCE (catching a corrupt outer stream), so both the
  # local-`.tar.gz` check and the document parse reuse the same decompression.
  doc <- audit_decompress_document(bytes_raw, raw_fmt)
  if (identical(doc$kind, "malformed-gzip")) {
    return(audit_artifact_malformed_gzip(source, base, doc$cnd))
  }

  # A local `.tar.gz` (gzip whose inner stream is tar) is handed to the bounded
  # archive extractor by path (tar.gz is local-only, PRD SS1).
  if (is_local && identical(raw_fmt, "gzip") && identical(doc$format, "tar")) {
    return(audit_artifact_archive(source, target, bytes_raw, base))
  }

  audit_artifact_document(
    source = source,
    is_local = is_local,
    target = target,
    final_url = final_url,
    base = base,
    root_meta = root_meta,
    raw_fmt = raw_fmt,
    doc_bytes = doc$bytes,
    doc_fmt = doc$format,
    user_agent = user_agent,
    limits = limits,
    index_limits = index_limits,
    policy = policy
  )
}

# Fetch (URL) or read (local) the source bytes ONCE, returning the bytes, the
# validate-side `final_url` (NA for a local file, so the protocol scope check is
# skipped), and the read-side root source-metadata record. A non-2xx terminal
# status raises `sitemapr_entrypoint_error`, mirroring read_sitemap()/
# validate_sitemap(); the pipeline catches it per source so the failure is
# attributable rather than fatal to the whole audit.
audit_fetch_bytes <- function(source, is_local, user_agent, limits, policy) {
  if (is_local) {
    target <- source$normalized_url[[1L]]
    size <- file.info(target)$size
    bytes <- readBin(target, what = "raw", n = size)
    # The read-side `sources` format for the document path is the raw sniff,
    # exactly as read_sitemap_local() records it. The archive and malformed-gzip
    # branches build/skip their own metadata, so no tar-aware sniff is needed
    # here (and eagerly decompressing would crash on a corrupt `.gz`).
    meta <- source_metadata(
      requested_url = target,
      final_url = target,
      bytes = as.integer(size),
      format = sniff_format(bytes)
    )
    return(list(bytes = bytes, final_url = NA_character_, root_meta = meta))
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
  list(bytes = attr(rec, "body"), final_url = rec$final_url, root_meta = rec)
}

# Transparently inflate a gzip stream and re-sniff, mirroring parse_dispatch()
# and resolve_validation_source(). A corrupt outer gzip raises
# `sitemapr_decompression_error`; it is caught and reported as a malformed-gzip
# artifact so both projections can attribute it.
audit_decompress_document <- function(bytes, raw_fmt) {
  if (!identical(raw_fmt, "gzip")) {
    return(list(kind = "document", bytes = bytes, format = raw_fmt))
  }
  tryCatch(
    {
      inflated <- gzip_decompress(bytes)
      list(kind = "document", bytes = inflated, format = sniff_format(inflated))
    },
    sitemapr_decompression_error = function(cnd) {
      list(kind = "malformed-gzip", cnd = cnd)
    }
  )
}

audit_artifact_malformed_gzip <- function(source, base, cnd) {
  list(kind = "malformed-gzip", source = source, base = base, cnd = cnd)
}

audit_artifact_archive <- function(source, target, bytes_raw, base) {
  list(
    kind = "archive",
    source = source,
    path = target,
    base = base,
    final_url = NA_character_,
    byte_size = as.numeric(length(bytes_raw)),
    fetched_at = NA
  )
}

# Assemble a "document" artifact. For an XML root the element name is recorded;
# for a URL `sitemapindex` the bounded expansion is run ONCE here so both
# projections share it (children fetched once).
audit_artifact_document <- function(
  source,
  is_local,
  target,
  final_url,
  base,
  root_meta,
  raw_fmt,
  doc_bytes,
  doc_fmt,
  user_agent,
  limits,
  index_limits,
  policy
) {
  art <- list(
    kind = "document",
    source = source,
    is_local = is_local,
    target = target,
    final_url = final_url,
    base = base,
    root_meta = root_meta,
    raw_fmt = raw_fmt,
    bytes = doc_bytes,
    format = doc_fmt,
    byte_size = as.numeric(length(doc_bytes)),
    fetched_at = NA,
    root = NA_character_,
    ex = NULL
  )

  if (!(doc_fmt %in% c("xml-urlset", "xml-sitemapindex", "xml"))) {
    return(art)
  }

  doc <- read_sitemap_xml(doc_bytes)
  art$root <- xml2::xml_name(xml2::xml_root(doc))

  # A URL sitemapindex is expanded ONCE; both projections read `ex`. A local
  # index has no origin to fetch children from (read does not expand it and
  # validate returns schema only), so expansion is skipped.
  if (identical(art$root, "sitemapindex") && !is.na(final_url)) {
    children <- parse_sitemapindex(xml2::xml_root(doc))
    art$ex <- expand_index(
      final_url,
      children,
      depth = 0L,
      user_agent = user_agent,
      limits = index_limits,
      net_limits = limits,
      policy = policy
    )
  }
  art
}

# ---- read-side projection (read_sitemap() semantics) -------------------------

# Project the read_sitemap() outputs from the artifact: the FAITHFUL rows (not
# yet typed), the per-source metadata, the non-fatal problems, and the discovery
# tree. Mirrors read_sitemap_source()/read_sitemap_url()/read_sitemap_local(),
# reusing the shared bytes and the single expand_index() result.
audit_read_projection <- function(artifact) {
  switch(
    artifact$kind,
    "malformed-gzip" = audit_read_failed(artifact),
    "archive" = audit_read_archive(artifact),
    "document" = audit_read_document(artifact),
    audit_read_failed(artifact)
  )
}

audit_read_empty <- function(problems = empty_problems()) {
  list(
    rows = empty_sitemap_rows(),
    sources = NULL,
    problems = problems,
    tree = empty_sitemap_tree()
  )
}

audit_read_failed <- function(artifact) {
  audit_read_empty(
    read_source_failure_problem(artifact$source, artifact$cnd)
  )
}

audit_read_archive <- function(artifact) {
  meta <- source_metadata(
    requested_url = artifact$path,
    final_url = artifact$path,
    bytes = as.integer(file.info(artifact$path)$size),
    format = "tar"
  )
  res <- parse_sitemap_archive(artifact$path, source_ref = artifact$path)
  list(
    rows = res$rows,
    sources = meta,
    problems = res$problems,
    tree = empty_sitemap_tree()
  )
}

audit_read_document <- function(artifact) {
  source_sitemap <- if (artifact$is_local) {
    artifact$target
  } else {
    artifact$final_url
  }

  if (identical(artifact$root, "sitemapindex") && !is.null(artifact$ex)) {
    ex <- artifact$ex
    sources <- if (is.null(ex$sources)) {
      artifact$root_meta
    } else {
      rbind(artifact$root_meta, ex$sources)
    }
    return(list(
      rows = ex$rows,
      sources = sources,
      problems = ex$problems,
      tree = ex$tree
    ))
  }

  # A non-index document goes through the same dispatcher read_sitemap() uses;
  # an unsupported root/format raises exactly as read_sitemap() would, and the
  # pipeline records it as a per-source problem.
  parsed <- parse_dispatch(artifact$bytes, source_sitemap = source_sitemap)
  list(
    rows = parsed$rows,
    sources = artifact$root_meta,
    problems = empty_problems(),
    tree = empty_sitemap_tree()
  )
}

# ---- findings-side projection (validate_sitemap() semantics) -----------------

# Project the validate_sitemap() findings contract from the artifact. Mirrors
# validate_sitemap_source(), reusing the shared bytes and the single
# expand_index() result instead of re-fetching/re-parsing.
audit_findings_projection <- function(artifact, mode) {
  parts <- switch(
    artifact$kind,
    "malformed-gzip" = list(decompression_source_finding(
      "UNSUPPORTED_MALFORMED_GZIP",
      artifact$base,
      conditionMessage(artifact$cnd)
    )),
    "archive" = validate_archive_parts(artifact),
    "document" = audit_findings_document(artifact),
    list(validate_failure_finding(artifact$source, artifact$cnd))
  )
  assemble_findings(parts, mode)
}

audit_findings_document <- function(artifact) {
  fmt <- artifact$format
  if (identical(fmt, "html")) {
    return(list(validate_classification(
      source_meta(html_masquerade = TRUE),
      artifact$base
    )))
  }
  if (identical(fmt, "text")) {
    return(list(validate_text_protocol(
      rawToChar(artifact$bytes),
      artifact$base
    )))
  }
  audit_validate_xml_parts(artifact)
}

# Mirror validate_xml_parts()/validate_index_parts() but read the shared bytes
# and the single expand_index() result off the artifact.
audit_validate_xml_parts <- function(artifact) {
  doc <- read_sitemap_xml(artifact$bytes)
  root <- xml2::xml_name(xml2::xml_root(doc))

  if (is.na(schema_root_kind(root))) {
    return(list(validate_classification(
      source_meta(unsupported_root = root),
      artifact$base
    )))
  }

  schema <- validate_schema(doc, artifact$base)

  if (identical(root, "urlset")) {
    rows <- parse_sitemap_xml(
      artifact$bytes,
      source_sitemap = artifact$final_url
    )$rows
    return(list(
      schema,
      validate_protocol(
        rows,
        sitemap_url = artifact$final_url,
        subject_ref = artifact$base,
        byte_size = artifact$byte_size,
        fetched_at = artifact$fetched_at,
        source_meta = NULL
      )
    ))
  }

  # sitemapindex. A local index has no origin URL, so children are never
  # fetched: only the schema part is produced (matching validate_index_parts()).
  if (is.null(artifact$ex)) {
    return(list(schema))
  }

  ex <- artifact$ex
  parts <- list(
    schema,
    index_findings_from_problems(ex$problems, artifact$base)
  )
  feeds <- index_feed_children(ex$sources)
  if (length(feeds) > 0L) {
    parts[[length(parts) + 1L]] <- validate_classification(
      source_meta(feed_children = feeds),
      artifact$base
    )
  }
  if (nrow(ex$rows) > 0L) {
    parts <- c(parts, index_protocol_parts(ex$rows, ex$sources, artifact$base))
  }
  parts
}

# ---- orchestration -----------------------------------------------------------

# Resolve one source ONCE, then project the read and findings sides
# INDEPENDENTLY from the shared artifact. Independence matters because the two
# public functions disagree on what is fatal: read_sitemap() raises on an
# unsupported root/format, whereas validate_sitemap() turns the same case into a
# classification finding. A shared-fetch failure (transport/SSRF/timeout) fails
# both sides identically; a read-only or findings-only failure is confined to
# that side and recorded as a per-source problem / fetch finding, so the source
# stays attributable and each side still matches its standalone function.
audit_one_source <- function(
  source,
  mode,
  user_agent,
  limits,
  index_limits,
  policy
) {
  artifact <- tryCatch(
    audit_resolve_source(
      source,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy
    ),
    error = function(cnd) list(kind = "resolve-error", cnd = cnd)
  )

  if (identical(artifact$kind, "resolve-error")) {
    return(list(
      rows = empty_sitemap_rows(),
      sources = NULL,
      problems = read_source_failure_problem(source, artifact$cnd),
      tree = empty_sitemap_tree(),
      findings = assemble_findings(
        list(validate_failure_finding(source, artifact$cnd)),
        mode
      )
    ))
  }

  read <- tryCatch(
    audit_read_projection(artifact),
    error = function(cnd) {
      audit_read_empty(read_source_failure_problem(source, cnd))
    }
  )
  findings <- tryCatch(
    audit_findings_projection(artifact, mode),
    error = function(cnd) {
      assemble_findings(list(validate_failure_finding(source, cnd)), mode)
    }
  )

  list(
    rows = read$rows,
    sources = read$sources,
    problems = read$problems,
    tree = read$tree,
    findings = findings
  )
}

# Combine already-assembled discovery trees, preserving the empty schema.
audit_combine_trees <- function(parts) {
  parts <- parts[vapply(parts, function(p) nrow(p) > 0L, logical(1L))]
  if (length(parts) == 0L) {
    return(empty_sitemap_tree())
  }
  do.call(rbind, parts)
}

#' Audit a sitemap in a single pass
#'
#' Resolves each sitemap source — a sitemap URL or a local sitemap file — just
#' ONCE and derives both the tidy URL table and the validation findings from
#' that single resolved artifact, returning them together as a [sitemap_audit()]
#' object. It is the single-pass equivalent of calling [read_sitemap()] and
#' [validate_sitemap()] separately: it fetches every remote root (and every
#' sitemap-index child) once instead of twice, and the two projections are
#' guaranteed to describe the same snapshot of the source.
#'
#' `audit_urls()` on the result equals [read_sitemap()] on the same source, and
#' `audit_findings()` equals [validate_sitemap()] on the same source and `mode`.
#' The audit also carries the per-source fetch metadata, the non-fatal parse
#' problems, and — for an expanded sitemap index — the discovery tree. A
#' source-level failure (an unreachable source, a corrupt archive, an
#' unsupported root) is recorded as a problem and a fetch-layer finding rather
#' than aborting the whole audit, so every source stays attributable.
#'
#' @param mode `"strict"` (the default) or `"non-strict"`, passed through to the
#'   findings projection exactly as [validate_sitemap()] uses it.
#' @inheritParams read_sitemap
#' @return A [sitemap_audit()] object: a classed list with the components
#'   `urls`, `findings`, `sources`, `problems`, and `tree`. Access them with
#'   [audit_urls()], [audit_findings()], [audit_sources()], [audit_problems()],
#'   and [audit_tree()].
#' @seealso [read_sitemap()] and [validate_sitemap()] for the equivalent
#'   two-call path, and [report_sitemap()], which accepts the returned object.
#' @export
#' @examples
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   '<url><loc>https://example.com/</loc>',
#'   '<lastmod>2024-01-01</lastmod></url>',
#'   '<url><loc>https://example.com/about</loc></url>',
#'   '</urlset>'
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#'
#' # One pass yields both the URL table and the findings.
#' audit <- audit_sitemap(path)
#' audit_urls(audit)
#' audit_findings(audit)
audit_sitemap <- function(
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

  # Mirror read_sitemap()/validate_sitemap(): a scalar source is projected
  # directly (so the outputs are byte-for-byte the scalar read/validate output),
  # while a submitted vector is combined the same way the batch paths combine.
  combined <- if (length(x) == 1L) {
    out <- audit_one_source(
      sources[1L, , drop = FALSE],
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy
    )
    list(
      rows = out$rows,
      findings = out$findings,
      sources = out$sources,
      problems = out$problems,
      tree = out$tree
    )
  } else {
    audit_sitemap_batch(
      sources,
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy
    )
  }

  sitemap_audit(
    urls = project_typed_rows(combined$rows),
    findings = combined$findings,
    sources = combined$sources,
    problems = combined$problems,
    tree = combined$tree
  )
}

# Resolve every source once and combine the per-source projections the same way
# read_sitemap_batch()/validate_sitemap_batch() combine theirs.
audit_sitemap_batch <- function(
  sources,
  mode,
  user_agent,
  limits,
  index_limits,
  policy
) {
  row_parts <- list()
  source_parts <- list()
  problem_parts <- list()
  tree_parts <- list()
  finding_parts <- list()

  for (i in seq_len(nrow(sources))) {
    out <- suppressWarnings(audit_one_source(
      sources[i, , drop = FALSE],
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy
    ))
    row_parts[[length(row_parts) + 1L]] <- out$rows
    source_parts[[length(source_parts) + 1L]] <- out$sources
    problem_parts[[length(problem_parts) + 1L]] <- out$problems
    tree_parts[[length(tree_parts) + 1L]] <- out$tree
    finding_parts[[length(finding_parts) + 1L]] <- out$findings
  }

  rows <- if (length(row_parts) == 0L) {
    empty_sitemap_rows()
  } else {
    do.call(rbind, row_parts)
  }
  list(
    rows = rows,
    findings = combine_findings_contracts(finding_parts),
    sources = combine_source_metadata(source_parts),
    problems = combine_problems(problem_parts),
    tree = audit_combine_trees(tree_parts)
  )
}
