#' Default limits for source-record construction
#'
#' Returns the configurable limits applied while building source records. The
#' submitted-list cap bounds how many distinct sitemap URLs a single vector
#' input may expand to (after deduplication).
#'
#' @param submitted_list_cap Maximum number of distinct records permitted from
#'   a vector ("submitted-list") input. Defaults to 25.
#' @return A named list of limits.
#' @keywords internal
#' @noRd
source_limits <- function(submitted_list_cap = 25L) {
  list(submitted_list_cap = as.integer(submitted_list_cap))
}

#' Permitted provenance values for source records
#'
#' The full v1 provenance enum. Only the first two are emitted by
#' `create_source_records()`; the remainder are produced by later slices
#' (discovery, index expansion, archive extraction).
#'
#' @return Character vector of provenance levels.
#' @keywords internal
#' @noRd
source_provenance_levels <- function() {
  c(
    "submitted-directly",
    "submitted-list",
    "guessed-path",
    "child-of-index",
    "extracted-archive"
  )
}

#' Does a raw input string carry an explicit URL scheme?
#'
#' Detects a leading `scheme://` on the *raw* user string. `rurl` defaults
#' schemeless input to `http`, which is wrong for sitemapr's entrypoint policy,
#' so scheme presence is decided here before the parse.
#'
#' @param x Character vector of raw inputs.
#' @return Logical vector, `TRUE` where a `scheme://` prefix is present.
#' @keywords internal
#' @noRd
has_explicit_scheme <- function(x) {
  grepl("^[a-zA-Z][a-zA-Z0-9+.-]*://", x)
}

#' Classify a raw input string as a local file path
#'
#' A path-like input is treated as a local file: a `file://` URL, an absolute
#' path (leading `/`), or any input with no `scheme://` prefix that is not a
#' bare host candidate. We deliberately do not require the file to exist (the
#' acceptance spec submits a non-existent path); existence is checked later by
#' the read layer, never here.
#'
#' @param x Character vector of raw inputs.
#' @return Logical vector, `TRUE` where the input denotes a local file.
#' @keywords internal
#' @noRd
is_local_file_input <- function(x) {
  file_url <- grepl("^file://", x, ignore.case = TRUE)
  absolute <- grepl("^/", x)
  has_scheme <- has_explicit_scheme(x)
  # A schemeless, non-absolute input is a bare-host candidate (a site/sitemap
  # host) unless it already exists on disk as a file.
  on_disk <- vapply(x, file.exists, logical(1), USE.NAMES = FALSE)
  existing <- !has_scheme & on_disk
  file_url | absolute | existing
}

#' Strip a `file://` prefix to a bare filesystem path
#'
#' @param x Character vector of raw inputs.
#' @return Character vector with any `file://` (and `file:///`) prefix removed.
#' @keywords internal
#' @noRd
strip_file_scheme <- function(x) {
  out <- sub("^file://", "", x, ignore.case = TRUE)
  # `file:///abs/path` -> `/abs/path`; `file://host/path` left as-is otherwise.
  out
}

#' Reduce a parsed URL row to its origin string
#'
#' Builds `scheme://host[:port]` with no path, query, or fragment. Used for the
#' `as = "site"` entrypoint policy, which treats input as a site root.
#'
#' @param scheme,host,port Parsed components (scalar per call site is fine; the
#'   function is vectorized).
#' @return Character vector of origin strings.
#' @keywords internal
#' @noRd
build_origin <- function(scheme, host, port) {
  # Drop the scheme's default port, matching `build_loc_key()` canonicalization
  # so a `:443`/`:80` site root and its bare form share one origin.
  is_default_port <- (scheme == "http" & port == 80L) |
    (scheme == "https" & port == 443L)
  drop_port <- is.na(port) | (!is.na(is_default_port) & is_default_port)
  port_part <- ifelse(drop_port, "", paste0(":", port))
  paste0(scheme, "://", host, port_part)
}

#' Turn user input into normalized source records
#'
#' Converts a single URL string, a single local file path, or a character
#' vector of sitemap URLs into a tibble of normalized source records, applying
#' sitemapr's entrypoint scheme policy and recording both the original and
#' normalized values. No network or filesystem access occurs here.
#'
#' URL mechanics (IDNA/Punycode host, dot-segment + slash path resolution,
#' lower-cased scheme/host) are delegated to `parse_url_adapter()`; the dedup
#' identity key comes from `build_loc_key()`.
#'
#' Entrypoint scheme policy:
#' \itemize{
#'   \item Schemeless input gets `https://` prepended and
#'     `scheme_inferred = TRUE`.
#'   \item Explicit `http://`/`https://` is preserved exactly, with
#'     `scheme_inferred = FALSE`.
#' }
#' No http fallback is performed here; that is the fetch layer's responsibility.
#'
#' @param x A single URL string, a single local file path, or a character
#'   vector of sitemap URLs.
#' @param as `"sitemap"` (default) treats each input as a direct sitemap
#'   URL/file and keeps its full path; `"site"` treats input as a site root and
#'   reduces the normalized URL to its origin.
#' @param limits A limits list, as from `source_limits()`.
#' @return A data.frame (tibble-shaped) of normalized source records.
#' @keywords internal
#' @noRd
create_source_records <- function(
  x,
  as = c("sitemap", "site"),
  limits = source_limits()
) {
  as <- match.arg(as)

  if (!is.character(x)) {
    rlang::abort(
      "`x` must be a character vector of URLs or file paths.",
      class = "sitemapr_input_type_error"
    )
  }
  if (length(x) == 0L) {
    rlang::abort(
      "`x` must contain at least one input.",
      class = "sitemapr_input_empty_error"
    )
  }

  provenance <- if (length(x) > 1L) "submitted-list" else "submitted-directly"

  records <- lapply(x, normalize_one, as = as, provenance = provenance)
  out <- do.call(rbind, records)

  # Dedup FIRST on the full-URL identity key, THEN enforce the list cap.
  out <- out[!duplicated(out$loc_key), , drop = FALSE]
  rownames(out) <- NULL

  over_cap <- nrow(out) > limits$submitted_list_cap
  if (provenance == "submitted-list" && over_cap) {
    rlang::abort(
      sprintf(
        paste0(
          "Submitted-list input has %d distinct sitemap URLs after ",
          "deduplication, exceeding the submitted-list cap of %d."
        ),
        nrow(out),
        limits$submitted_list_cap
      ),
      class = "sitemapr_submitted_list_cap_error",
      cap = limits$submitted_list_cap,
      n = nrow(out)
    )
  }

  out
}

#' Build a single source record from one raw input
#'
#' @param raw A length-1 character input.
#' @param as Entrypoint mode, `"sitemap"` or `"site"`.
#' @param provenance Provenance label for the record.
#' @return A one-row data.frame with the source-record columns.
#' @keywords internal
#' @noRd
normalize_one <- function(raw, as, provenance) {
  if (is_local_file_input(raw)) {
    path <- strip_file_scheme(raw)
    return(source_record_row(
      original_input = raw,
      normalized_url = path,
      scheme = NA_character_,
      host = NA_character_,
      port = NA_integer_,
      path = path,
      query = NA_character_,
      fragment = NA_character_,
      is_local_file = TRUE,
      scheme_inferred = FALSE,
      provenance = provenance,
      loc_key = path
    ))
  }

  scheme_inferred <- !has_explicit_scheme(raw)
  to_parse <- if (scheme_inferred) paste0("https://", raw) else raw

  parsed <- parse_url_adapter(to_parse)

  if (!identical(parsed$parse_status[[1L]], "ok")) {
    rlang::abort(
      sprintf("Could not parse input as a URL: %s", raw),
      class = "sitemapr_input_parse_error",
      input = raw
    )
  }

  scheme <- parsed$scheme[[1L]]
  host <- parsed$host[[1L]]
  port <- parsed$port[[1L]]
  path <- parsed$path[[1L]]
  query <- parsed$query[[1L]]
  fragment <- parsed$fragment[[1L]]

  if (identical(as, "site")) {
    # Reduce to origin: scheme://host[:port], dropping path/query/fragment.
    normalized_url <- build_origin(scheme, host, port)
    path <- NA_character_
    query <- NA_character_
    fragment <- NA_character_
    loc_key <- build_loc_key(data.frame(
      scheme = scheme,
      host = host,
      port = port,
      path = NA_character_,
      query = NA_character_,
      fragment = NA_character_,
      user = NA_character_,
      stringsAsFactors = FALSE
    ))
  } else {
    # The canonical sitemap URL is both the fetch target and the identity key:
    # `clean_url` would drop a contentful query or a non-default port and so
    # fetch the wrong resource (SITE-vrgszbnu).
    loc_key <- build_loc_key(parsed)[[1L]]
    normalized_url <- loc_key
  }

  source_record_row(
    original_input = raw,
    normalized_url = normalized_url,
    scheme = scheme,
    host = host,
    port = port,
    path = path,
    query = query,
    fragment = fragment,
    is_local_file = FALSE,
    scheme_inferred = scheme_inferred,
    provenance = provenance,
    loc_key = loc_key
  )
}

#' Construct one source-record row with a stable column set and types
#'
#' @keywords internal
#' @noRd
source_record_row <- function(
  original_input,
  normalized_url,
  scheme,
  host,
  port,
  path,
  query,
  fragment,
  is_local_file,
  scheme_inferred,
  provenance,
  loc_key
) {
  data.frame(
    original_input = as.character(original_input),
    normalized_url = as.character(normalized_url),
    scheme = as.character(scheme),
    host = as.character(host),
    port = as.integer(port),
    path = as.character(path),
    query = as.character(query),
    fragment = as.character(fragment),
    is_local_file = as.logical(is_local_file),
    scheme_inferred = as.logical(scheme_inferred),
    provenance = as.character(provenance),
    loc_key = as.character(loc_key),
    stringsAsFactors = FALSE
  )
}
