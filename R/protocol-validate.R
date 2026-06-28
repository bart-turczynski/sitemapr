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
# This file covers the SITE-fraetonj (D.1) slice: the findings constructor and
# the per-`<loc>` URL rules. The remaining Layer D surface — count/field-value
# rules, hreflang policy, extension fields, text-sitemap rules, and
# unsupported-input diagnostics — lands in sibling sub-issues that extend
# `validate_protocol()`.
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
protocol_findings <- function(code = character(0),
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

# One evidence list, with the excerpt clamped to the contract's 500-char cap.
protocol_evidence <- function(excerpt = NA_character_,
                              line = NA_integer_,
                              column = NA_integer_) {
  if (!is.na(excerpt)) {
    excerpt <- substr(excerpt, 1L, 500L)
  }
  list(excerpt = excerpt, line = as.integer(line), column = as.integer(column))
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
protocol_url_finding <- function(code, severity, subject_type, base, i, loc,
                                 message, is_strict_only = FALSE) {
  protocol_findings(
    code = code,
    severity = severity,
    subject_type = subject_type,
    subject_ref = protocol_ref_fragment(base, paste0("#entry:", i)),
    message = message,
    evidence = list(protocol_evidence(excerpt = loc)),
    is_strict_only = is_strict_only
  )
}

# Per-`<loc>` URL rules over the parsed rows. Returns a (possibly empty)
# protocol-findings tibble. `sitemap_url` is the sitemap's own absolute URL,
# used for scope; `NA` skips the scope check (undefined without an origin).
validate_loc_urls <- function(rows, sitemap_url, base) {
  loc <- rows$loc
  keep <- !is.na(loc) & nzchar(loc)
  idx <- which(keep)
  if (length(idx) == 0L) {
    return(empty_protocol_findings())
  }

  kind <- loc_absoluteness(loc[idx])
  out <- list()

  # Non-absolute (relative or non-http(s) scheme) -> a single clear finding per
  # entry; the remaining URL-structure checks assume an absolute http(s) URL.
  bad <- idx[kind != "http(s)"]
  for (j in bad) {
    out[[length(out) + 1L]] <- protocol_url_finding(
      "PROTOCOL_URL_NOT_ABSOLUTE", "error", "entry", base, j, loc[j],
      sprintf(
        "<loc> '%s' is not an absolute http/https URL.", loc[j]
      )
    )
  }

  absolute <- idx[kind == "http(s)"]
  if (length(absolute) == 0L) {
    if (length(out) == 0L) {
      return(empty_protocol_findings())
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
    l <- loc[j]
    host <- as.character(parsed$host[k])

    if (is.na(host) || !nzchar(host)) {
      out[[length(out) + 1L]] <- protocol_url_finding(
        "PROTOCOL_URL_NO_HOST", "error", "entry", base, j, l,
        sprintf("<loc> '%s' has no host component.", l)
      )
      next
    }

    if (nchar(l) >= 2048L) {
      out[[length(out) + 1L]] <- protocol_url_finding(
        "PROTOCOL_URL_TOO_LONG", "warning", "entry", base, j, l,
        sprintf(
          "<loc> is %d characters; sitemap URLs must be under 2048.", nchar(l)
        )
      )
    }

    if (has_invalid_escape(l)) {
      out[[length(out) + 1L]] <- protocol_url_finding(
        "PROTOCOL_URL_INVALID_ESCAPE", "error", "entry", base, j, l,
        sprintf("<loc> '%s' contains an invalid percent-escape.", l)
      )
    }

    if (grepl("#", l, fixed = TRUE)) {
      out[[length(out) + 1L]] <- protocol_url_finding(
        "PROTOCOL_URL_FRAGMENT", "info", "entry", base, j, l,
        sprintf(
          "<loc> '%s' contains a fragment, which crawlers ignore.", l
        )
      )
    }

    user <- as.character(parsed$user[k])
    if (!is.na(user) && nzchar(user)) {
      out[[length(out) + 1L]] <- protocol_url_finding(
        "PROTOCOL_URL_USERINFO", "info", "entry", base, j, l,
        sprintf("<loc> '%s' contains userinfo, which crawlers ignore.", l)
      )
    }

    if (!is.na(authority_self)) {
      in_scope <- identical(loc_authority(parsed[k, , drop = FALSE]),
                            authority_self) &&
        startsWith(as.character(parsed$path[k]), dir_self)
      if (!in_scope) {
        out[[length(out) + 1L]] <- protocol_url_finding(
          "PROTOCOL_URL_OUT_OF_SCOPE", "warning", "entry", base, j, l,
          sprintf(
            paste0(
              "<loc> '%s' is outside the sitemap's scope (same host and ",
              "same-or-lower path as %s)."
            ),
            l, sitemap_url
          )
        )
      }
    }
  }

  # Duplicate detection on the full-URL identity key, over the absolute,
  # host-bearing entries only. Each repeat past the first occurrence of a key is
  # flagged against its own entry, naming the first occurrence.
  has_host <- !is.na(parsed$host) & nzchar(as.character(parsed$host))
  if (any(has_host)) {
    keys <- build_loc_key(parsed)
    keys[!has_host] <- NA_character_
    first_seen <- new.env(parent = emptyenv())
    for (k in which(has_host)) {
      key <- keys[k]
      if (is.null(first_seen[[key]])) {
        assign(key, absolute[k], envir = first_seen)
      } else {
        j <- absolute[k]
        first_entry <- get(key, envir = first_seen)
        out[[length(out) + 1L]] <- protocol_url_finding(
          "PROTOCOL_DUPLICATE_LOC", "warning", "entry", base, j, loc[j],
          sprintf(
            "<loc> duplicates entry %d (identity key '%s').", first_entry, key
          )
        )
      }
    }
  }

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
#' This is the D.1 slice: it implements the per-`<loc>` URL rules. Later
#' sub-issues extend it with count/field, hreflang, extension, text-sitemap, and
#' unsupported-input checks.
#'
#' @param rows A parsed row tibble from [sitemap_rows()] / the format parsers.
#' @param sitemap_url The sitemap's own absolute URL, used for same-origin scope
#'   comparison. `NA` skips the scope check.
#' @param subject_ref The document-level `sitemap://…` base for each finding's
#'   `subject_ref`; defaults to the authority form derived from `sitemap_url`.
#'   `NA` yields fragment-only refs.
#' @return A protocol-findings tibble (zero rows when the document conforms).
#' @keywords internal
#' @noRd
validate_protocol <- function(rows, sitemap_url = NA_character_,
                              subject_ref = sitemap_subject_ref(sitemap_url)) {
  if (is.null(rows) || nrow(rows) == 0L) {
    return(empty_protocol_findings())
  }
  validate_loc_urls(rows, sitemap_url, subject_ref)
}
