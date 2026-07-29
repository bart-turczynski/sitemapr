# Shared RFC 8288 `Link` response-header parser (Layer E, Contract B
# extraction). Internal only.
#
# ONE parser serves both header-reading producers — R/page-canonical.R
# (rel=canonical) and R/page-hreflang.R (rel=alternate + hreflang) — so the two
# can never disagree about what a link-value means. Before this file, canonical
# substring-matched `rel` itself (missing `rel="alternate canonical"`, matching
# `rel="canonical-ish"`) and hreflang ignored the header entirely.
#
# Governing contracts (conform, do not restate):
#   RFC 8288 §3   a Link field value is a comma-separated list of link-values,
#                 each a `<URI-Reference>` followed by `;`-separated parameters
#            §3.3 `rel` is a WHITESPACE-SEPARATED LIST of relation types whose
#                 ORDER IS NOT SIGNIFICANT; occurrences of the parameter after
#                 the first MUST be ignored. Types compare case-insensitively.
#            §3.4 `hreflang` MAY appear more than once in one link-value, each
#                 occurrence naming another language for the same target.
#   docs/design/layer-e-page-inspection.md §4 — pure extraction, no verdicts.
#
# Nothing here fetches, resolves, or judges: it returns RAW URI references and
# RAW parameter values. Resolution against the response base and the ADR-005
# identity comparison stay in the producers.

# The link-values of every `Link` response header, in order. Returns a list of
# records: `uri` (the raw reference inside the angle brackets) and `params` (the
# parsed parameter list). Repeated header fields are all consulted
# (page_header_values preserves them); a segment carrying no bracketed URI is
# not a link-value and is skipped.
page_link_header_entries <- function(headers) {
  values <- page_header_values(headers, "Link")
  if (length(values) == 0L) {
    return(list())
  }
  # Split on the commas that separate link-values (a comma preceding the next
  # `<uri>`). The lookahead keeps a comma inside the target reference or inside
  # a quoted parameter value from tearing an entry in two.
  segments <- unlist(strsplit(toString(values), ",(?=\\s*<)", perl = TRUE))
  out <- list()
  for (seg in segments) {
    m <- regmatches(seg, regexec("^\\s*<([^>]*)>(.*)$", seg))[[1L]]
    if (length(m) < 3L) {
      next
    }
    out[[length(out) + 1L]] <- list(
      uri = trimws(m[[2L]]),
      params = page_link_params(m[[3L]])
    )
  }
  out
}

# The parameters of one link-value, as a list of `name` (lowercased) / `value`
# (unquoted) records. Order and repeats are preserved: §3.3 needs the FIRST
# `rel` and §3.4 needs EVERY `hreflang`.
page_link_params <- function(params) {
  # Split on the semicolons that separate parameters, but NOT on one inside a
  # quoted value (`title="a; b"`): each run is either a quoted-string (with
  # RFC 8288 quoted-pairs) or a stretch of non-semicolon characters. The split
  # is PCRE because TRE mis-matches this alternation, returning a single run
  # that spans the separators.
  rx <- "(\"[^\"\\\\]*(\\\\.[^\"\\\\]*)*\"|[^;])+"
  chunks <- regmatches(params, gregexpr(rx, params, perl = TRUE))[[1L]]
  out <- list()
  for (chunk in chunks) {
    one <- page_link_one_param(trimws(chunk))
    if (is.null(one)) {
      next
    }
    out[[length(out) + 1L]] <- one
  }
  out
}

# One `name` / `name=value` parameter, or NULL when the chunk carries no name.
# A valueless parameter reads as an empty value (equivalent to absent for every
# parameter this module consumes).
page_link_one_param <- function(chunk) {
  rx <- "^([^=[:space:]]+)[[:space:]]*(=[[:space:]]*(.*))?$"
  m <- regmatches(chunk, regexec(rx, chunk))[[1L]]
  if (length(m) < 4L) {
    return(NULL)
  }
  list(name = tolower(m[[2L]]), value = page_link_unquote(m[[4L]]))
}

# Undo the RFC 8288 quoted-string form of a parameter value, including
# quoted-pairs (`\"` -> `"`). A bare token value is returned trimmed.
page_link_unquote <- function(value) {
  if (!grepl("^\".*\"$", value)) {
    return(trimws(value))
  }
  inner <- substr(value, 2L, nchar(value) - 1L)
  gsub("\\\\(.)", "\\1", inner)
}

# Every value of one parameter of a link-value, in order (case-insensitive name
# match). §3.4's repeated `hreflang` is why this returns a vector.
page_link_param_values <- function(entry, name) {
  if (length(entry$params) == 0L) {
    return(character(0))
  }
  hit <- vapply(
    entry$params,
    function(p) identical(p$name, tolower(name)),
    logical(1)
  )
  vapply(entry$params[hit], function(p) p$value, character(1))
}

# The relation types of one link-value, lowercased. §3.3: `rel` is a
# whitespace-separated LIST, and only the FIRST `rel` parameter counts.
page_link_rel_tokens <- function(entry) {
  rels <- page_link_param_values(entry, "rel")
  if (length(rels) == 0L) {
    return(character(0))
  }
  tokens <- strsplit(trimws(rels[[1L]]), "[[:space:]]+")[[1L]]
  tolower(tokens[nzchar(tokens)])
}

# Does this link-value declare `rel` as ONE OF its relation types? Membership,
# not a substring test: order stops mattering (`rel="alternate canonical"`
# counts) and a merely prefixed type (`rel="canonical-ish"`) stops matching.
page_link_has_rel <- function(entry, rel) {
  rel %in% page_link_rel_tokens(entry)
}
