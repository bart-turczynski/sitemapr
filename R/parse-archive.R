# Bounded, safe local `.tar.gz` archive extraction (architecture.md §9).
#
# Internal only. v1 supports `.tar.gz` from LOCAL files only (never fetched over
# the network; PRD §1). The outer gzip layer is inflated with the shared
# `gzip_decompress()` (R/decompress.R); the resulting tar stream is then parsed
# ENTIRELY IN MEMORY here. We never call `untar()` and never write any member to
# disk, so the "nothing is written outside the extraction boundary" guarantee
# (architecture.md §9) holds by construction — there is no boundary to escape.
# Pure and offline; failures surface as classed conditions, never findings
# (architecture.md §3).
#
# Per-member handling (architecture.md §9):
#   - directories and special entries (symlink/hardlink/device/...) are skipped;
#   - an entry whose name contains a path-traversal (`..`) component, is
#     absolute, or carries a drive letter is REJECTED (recorded as a warning
#     problem, never parsed);
#   - a regular file is sniffed and parsed: an inner `.gz` member is
#     decompressed first; a urlset (XML) or text sitemap contributes rows;
#     anything else is SKIPPED with an info problem;
#   - rows carry a stable `<archive>#archive-member:<path>` provenance ref, so
#     the contributing member is identifiable.
#
# Bounds (configurable; archive_limits()): archive bytes on disk, member (file)
# count, and total decompressed bytes. Exceeding any raises
# `sitemapr_archive_limit`. An archive with no regular-file members raises
# `sitemapr_empty_archive`; a truncated/garbage tar raises
# `sitemapr_malformed_archive`; a corrupt outer gzip raises
# `sitemapr_decompression_error` (from `gzip_decompress()`).

#' Default bounds for local `.tar.gz` extraction
#'
#' Resolves each bound from its argument, then a matching
#' `getOption("sitemapr.archive.*")` value, then the architecture.md §9 default.
#' Callers may raise any bound.
#'
#' @param max_archive_bytes Max compressed archive size on disk. Default 50 MB.
#' @param max_file_count Max number of regular-file members. Default 100.
#' @param max_decompressed_bytes Max total decompressed (tar) bytes. Default
#'   200 MB.
#' @return A named list of bounds with coerced types.
#' @keywords internal
#' @noRd
archive_limits <- function(
  max_archive_bytes = getOption("sitemapr.archive.max_bytes", 50 * 1024^2),
  max_file_count = getOption("sitemapr.archive.max_files", 100L),
  max_decompressed_bytes = getOption(
    "sitemapr.archive.max_decompressed",
    200 * 1024^2
  )
) {
  list(
    max_archive_bytes = as.numeric(max_archive_bytes),
    max_file_count = as.integer(max_file_count),
    max_decompressed_bytes = as.numeric(max_decompressed_bytes)
  )
}

# ---- tar (ustar) reader ------------------------------------------------------

tar_block_size <- 512L

# Extract bytes [offset, offset+len) (0-based offset) from a 512-byte header,
# truncate at the first NUL, and return the trimmed ASCII string.
tar_field_string <- function(header, offset, len) {
  field <- header[(offset + 1L):(offset + len)]
  nul <- which(field == as.raw(0L))
  if (length(nul) > 0L) {
    field <- field[seq_len(nul[[1L]] - 1L)]
  }
  if (length(field) == 0L) {
    return("")
  }
  trimws(rawToChar(field))
}

# Parse a space/NUL-padded octal numeric tar field to a numeric value.
tar_field_octal <- function(header, offset, len) {
  s <- gsub("[^0-7]", "", tar_field_string(header, offset, len))
  if (!nzchar(s)) {
    return(0)
  }
  val <- suppressWarnings(strtoi(s, base = 8L))
  if (is.na(val)) {
    archive_abort_malformed("an octal header field could not be parsed")
  }
  val
}

archive_abort_malformed <- function(detail) {
  rlang::abort(
    sprintf("The tar archive is malformed: %s.", detail),
    class = "sitemapr_malformed_archive"
  )
}

# Read all entries of an (already decompressed) tar stream into a list of
# records: list(name, typeflag, content). Stops at the end-of-archive marker
# (a zero block). Structural inconsistencies raise sitemapr_malformed_archive.
tar_read_entries <- function(tar_bytes) {
  n <- length(tar_bytes)
  block <- tar_block_size
  entries <- list()
  pos <- 0L

  repeat {
    if (pos >= n) {
      break
    }
    if (pos + block > n) {
      archive_abort_malformed("a header block is truncated")
    }
    header <- tar_bytes[(pos + 1L):(pos + block)]
    pos <- pos + block

    # End-of-archive: an all-zero header block.
    if (all(header == as.raw(0L))) {
      break
    }

    name <- tar_field_string(header, 0L, 100L)
    prefix <- tar_field_string(header, 345L, 155L)
    if (nzchar(prefix)) {
      name <- file.path(prefix, name)
    }
    typeflag <- as.integer(header[157L]) # offset 156 (0-based)
    size <- tar_field_octal(header, 124L, 12L)

    content <- NULL
    if (size > 0) {
      if (pos + size > n) {
        archive_abort_malformed("a member body is truncated")
      }
      content <- tar_bytes[(pos + 1L):(pos + size)]
      # Advance past the body, padded up to the next 512-byte boundary.
      pos <- pos + as.integer(ceiling(size / block)) * block
    }

    entries[[length(entries) + 1L]] <- list(
      name = name,
      typeflag = typeflag,
      content = content
    )
  }

  entries
}

# typeflag classification. '0' (0x30) and the historic NUL (0x00) are regular
# files; '5' (0x35) is a directory; everything else (links/devices/GNU-PAX
# extensions) is a special entry we skip.
tar_is_regular_file <- function(typeflag) {
  typeflag == 0x30L || typeflag == 0x00L
}
tar_is_directory <- function(typeflag) {
  typeflag == 0x35L
}

# An archive member name is unsafe if it is empty, absolute, carries a Windows
# drive letter, or contains a `..` path component.
tar_is_unsafe_name <- function(name) {
  if (!nzchar(name)) {
    return(TRUE)
  }
  if (grepl("^[/\\\\]", name) || grepl("^[A-Za-z]:", name)) {
    return(TRUE)
  }
  parts <- strsplit(name, "[/\\\\]", perl = TRUE)[[1L]]
  any(parts == "..")
}

# ---- per-member content dispatch ---------------------------------------------

# Decide whether a member with the given (peeled) extension and sniffed format
# is a parseable sitemap. Returns NULL when the member should be parsed, else a
# human-readable skip reason. Eligibility is decided by FILE EXTENSION first:
# inside an archive a text sitemap and an arbitrary text file (a README) are
# indistinguishable by content, so only `.xml`/`.txt` members are sitemap
# candidates; anything else is skipped. The sniffed format then catches a
# mismatch (e.g. an `.xml` member that is actually HTML or a sitemap index).
member_skip_reason <- function(ext, fmt) {
  if (!ext %in% c("xml", "txt")) {
    label <- if (nzchar(ext)) sprintf(".%s file", ext) else "extensionless file"
    return(sprintf("non-sitemap %s", label))
  }
  if (identical(ext, "xml")) {
    if (identical(fmt, "xml-urlset")) {
      return(NULL)
    }
    if (identical(fmt, "xml-sitemapindex")) {
      return("sitemap index inside archive is not expanded")
    }
    return("non-sitemap XML content")
  }
  # The remaining candidate extension is "txt".
  if (!identical(fmt, "text")) {
    return("non-text content in .txt member")
  }
  NULL
}

# Classify and parse one regular-file member's bytes into rows. An inner `.gz`
# member is decompressed once before classification. Returns
# list(rows = <tibble or NULL>, reason = <NULL when parsed, else why it was
# skipped>).
archive_parse_member <- function(content, name, source_ref) {
  if (is.null(content) || length(content) == 0L) {
    return(list(rows = NULL, reason = "empty member"))
  }

  display_name <- name
  if (identical(sniff_format(content), "gzip")) {
    content <- gzip_decompress(content)
    display_name <- sub("\\.gz$", "", name, ignore.case = TRUE)
  }

  ext <- tolower(tools::file_ext(display_name))
  fmt <- sniff_format(content)
  reason <- member_skip_reason(ext, fmt)
  if (!is.null(reason)) {
    return(list(rows = NULL, reason = reason))
  }

  rows <- if (identical(ext, "xml")) {
    parse_sitemap_xml(content, source_sitemap = source_ref)$rows
  } else {
    parse_sitemap_text(content, source_sitemap = source_ref)
  }
  list(rows = rows, reason = NULL)
}

# ---- entry point -------------------------------------------------------------

#' Extract and parse a local `.tar.gz` sitemap archive into rows
#'
#' Inflates the outer gzip layer, parses the tar in memory under the configured
#' bounds, and parses each safe sitemap member into the tidy row schema. Skipped
#' and rejected members are recorded in the returned `problems` table.
#'
#' @param path Path to a local `.tar.gz` file.
#' @param source_ref Stable provenance prefix for member refs; defaults to
#'   `path`. Each row's `source_sitemap` is `"<source_ref>#archive-member:<m>"`.
#' @param limits Extraction bounds, as from `archive_limits()`.
#' @return A list with `rows` (combined tidy row tibble; empty when no member
#'   contributed rows) and `problems` (the `parse_problems()` table of
#'   skipped/rejected members).
#' @keywords internal
#' @noRd
# Read a local `.tar.gz` from disk and return the inflated tar bytes, enforcing
# the on-disk archive-byte and total-decompressed-byte bounds. A missing file
# raises `sitemapr_archive_not_found`; either bound raises
# `sitemapr_archive_limit`; a corrupt outer gzip raises (via gzip_decompress)
# `sitemapr_decompression_error`.
read_archive_bytes <- function(path, limits) {
  size_on_disk <- file.info(path)$size
  if (is.na(size_on_disk)) {
    rlang::abort(
      sprintf("The archive file does not exist: %s.", path),
      class = "sitemapr_archive_not_found",
      path = path
    )
  }
  if (size_on_disk > limits$max_archive_bytes) {
    rlang::abort(
      sprintf(
        "Archive size %.0f bytes exceeds the limit of %.0f bytes.",
        size_on_disk,
        limits$max_archive_bytes
      ),
      class = "sitemapr_archive_limit",
      limit = "archive_bytes"
    )
  }

  gz <- readBin(path, what = "raw", n = size_on_disk)
  tar_bytes <- gzip_decompress(gz)

  if (length(tar_bytes) > limits$max_decompressed_bytes) {
    rlang::abort(
      sprintf(
        "Decompressed size %.0f bytes exceeds the limit of %.0f bytes.",
        length(tar_bytes),
        limits$max_decompressed_bytes
      ),
      class = "sitemapr_archive_limit",
      limit = "decompressed_bytes"
    )
  }

  tar_bytes
}

archive_unsafe_problem <- function(member_ref, name) {
  parse_problems(
    severity = "warning",
    category = "classification",
    subject_ref = member_ref,
    message = sprintf(
      "Rejected unsafe archive member path '%s' (path traversal).",
      name
    )
  )
}

archive_member_result <- function(entry, source_ref) {
  member_ref <- sprintf("%s#archive-member:%s", source_ref, entry$name)
  if (tar_is_unsafe_name(entry$name)) {
    return(list(problem = archive_unsafe_problem(member_ref, entry$name)))
  }

  member <- archive_parse_member(entry$content, entry$name, member_ref)
  if (is.null(member$rows)) {
    return(list(problem = parse_problems(
      severity = "info",
      category = "classification",
      subject_ref = member_ref,
      message = sprintf("Skipped %s: %s.", entry$name, member$reason)
    )))
  }

  list(rows = member$rows)
}

archive_check_file_count <- function(file_count, limits) {
  if (file_count <= limits$max_file_count) {
    return(invisible(NULL))
  }
  rlang::abort(
    sprintf(
      "Archive member count exceeds the limit of %d files.",
      limits$max_file_count
    ),
    class = "sitemapr_archive_limit",
    limit = "file_count"
  )
}

archive_rows <- function(rows_parts) {
  if (length(rows_parts) > 0L) {
    do.call(rbind, rows_parts)
  } else {
    empty_sitemap_rows()
  }
}

parse_sitemap_archive <- function(
  path,
  source_ref = path,
  limits = archive_limits()
) {
  tar_bytes <- read_archive_bytes(path, limits)
  entries <- tar_read_entries(tar_bytes)

  rows_parts <- list()
  problem_parts <- list()
  file_count <- 0L

  for (e in entries) {
    if (tar_is_directory(e$typeflag) || !tar_is_regular_file(e$typeflag)) {
      next # directories and special entries are skipped silently
    }

    file_count <- file_count + 1L
    archive_check_file_count(file_count, limits)

    result <- archive_member_result(e, source_ref)
    if (!is.null(result$problem)) {
      problem_parts[[length(problem_parts) + 1L]] <- result$problem
    } else {
      rows_parts[[length(rows_parts) + 1L]] <- result$rows
    }
  }

  if (file_count == 0L) {
    rlang::abort(
      "The tar archive contains no regular-file members.",
      class = "sitemapr_empty_archive"
    )
  }

  list(
    rows = archive_rows(rows_parts),
    problems = combine_problems(problem_parts)
  )
}
