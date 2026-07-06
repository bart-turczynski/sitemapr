#' Default limits for a bounded HTTP fetch
#'
#' Returns the configurable network limits the fetch engine applies per
#' request. Each limit resolves from the matching argument, falling back to a
#' `getOption("sitemapr.*")` value, then to the ADR-003 default. No limit is a
#' non-overridable hard cap: a caller may raise any of them by passing an
#' argument or setting the option.
#'
#' Defaults (ADR-003 §3): request timeout 30 s, max redirects 5, per-resource
#' safety ceiling 500 MB. The 50 MB sitemap-protocol size limit is NOT enforced
#' here — it is a non-fatal validation finding (`PROTOCOL_SIZE_EXCEEDED`); the
#' fetch layer only records body size and guards memory with the ceiling.
#'
#' @param timeout Per-request timeout in seconds (numeric).
#' @param max_redirects Maximum number of redirects to follow (integer).
#' @param max_bytes Per-resource safety ceiling in bytes (integer): the hard cap
#'   on the body read into memory. Exceeding it discards the body and raises a
#'   `sitemapr_body_ceiling` condition. Default 500 MB.
#' @return A named list of limits with coerced types.
#' @keywords internal
#' @noRd
fetch_limits <- function(
  timeout = getOption("sitemapr.timeout", 30),
  max_redirects = getOption(
    "sitemapr.max_redirects",
    5L
  ),
  max_bytes = getOption(
    "sitemapr.max_bytes",
    500L * 1024L^2
  )
) {
  list(
    timeout = as.numeric(timeout),
    max_redirects = as.integer(max_redirects),
    max_bytes = as.integer(max_bytes)
  )
}

#' Build the default User-Agent string
#'
#' Assembles `sitemapr/<version> (+<contact-url>)` at runtime. `<version>`
#' comes from the installed package version and `<contact-url>` from the
#' package `URL` field, so no contact URL literal appears in package source
#' (ADR-003 §5). Callers may override the UA via a `user_agent` argument to the
#' public entrypoints; this function supplies the value used when they do not.
#'
#' If the `URL` field is unavailable (`NA` or missing), the `(+<contact-url>)`
#' suffix is omitted and the bare `sitemapr/<version>` string is returned.
#'
#' @return A length-1 character User-Agent string.
#' @keywords internal
#' @noRd
default_user_agent <- function() {
  version <- as.character(utils::packageVersion("sitemapr"))
  url <- utils::packageDescription("sitemapr")$URL

  if (is.null(url) || is.na(url) || !nzchar(url)) {
    return(sprintf("sitemapr/%s", version))
  }

  # The URL field may list multiple URLs (comma/whitespace separated); the
  # first entry is the canonical contact URL. DESCRIPTION deliberately lists the
  # GitHub repo first (ahead of the pkgdown site) so the crawler contact URL
  # points at the repo README/issues; keep that order.
  contact <- trimws(strsplit(url, "[,[:space:]]+")[[1L]][[1L]])
  sprintf("sitemapr/%s (+%s)", version, contact)
}

#' Construct a one-row source-metadata record for a fetch
#'
#' Builds the fetch metadata record attached to each source. Every argument
#' defaults to `NA` (or an empty list for the list-columns) so the fetch engine
#' can construct the record incrementally as a request progresses. The
#' downstream-populated fields (`root`, `namespaces`, `profile_id`) come from
#' the parse/schema slices and default to empty here by design.
#'
#' Column order and types are part of the fetch-metadata contract
#' (`docs/findings-contract.md`, PRD §2): 13 columns, `redirect_chain` and
#' `namespaces` are list-columns holding variable-length vectors.
#'
#' @param requested_url,final_url,content_type,charset Character scalars
#'   (default `NA`).
#' @param error_class,format,root,profile_id Character scalars (default `NA`);
#'   `root`, `namespaces`, and `profile_id` are populated by downstream slices.
#' @param status,bytes Integer scalars (default `NA`).
#' @param timing Numeric elapsed seconds (default `NA`).
#' @param redirect_chain,namespaces List-columns of variable-length vectors
#'   (default empty list).
#' @return A one-row data.frame with the 13 contract columns.
#' @keywords internal
#' @noRd
source_metadata <- function(
  requested_url = NA_character_,
  final_url = NA_character_,
  status = NA_integer_,
  redirect_chain = list(),
  content_type = NA_character_,
  charset = NA_character_,
  bytes = NA_integer_,
  timing = NA_real_,
  error_class = NA_character_,
  format = NA_character_,
  root = NA_character_,
  namespaces = list(),
  profile_id = NA_character_
) {
  data.frame(
    requested_url = as.character(requested_url),
    final_url = as.character(final_url),
    status = as.integer(status),
    redirect_chain = I(list(redirect_chain)),
    content_type = as.character(content_type),
    charset = as.character(charset),
    bytes = as.integer(bytes),
    timing = as.numeric(timing),
    error_class = as.character(error_class),
    format = as.character(format),
    root = as.character(root),
    namespaces = I(list(namespaces)),
    profile_id = as.character(profile_id),
    stringsAsFactors = FALSE
  )
}
