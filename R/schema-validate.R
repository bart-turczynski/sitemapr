# XSD schema validation, Layer C finding-producer (architecture.md §3, §6).
#
# Internal only. `validate_schema()` takes a parsed sitemap document and returns
# schema findings (`layer = "schema"`) in the docs/findings-contract.md shape.
# It is the C-layer half of the findings pipeline: it produces stable, scoped
# rows but does NOT assemble the final tibble. Specifically, the `mode` column,
# strict/non-strict severity adjustment and filtering, de-duplication, and the
# final sort are all Layer F's job (SITE-ymzvnlpr); they are deliberately not
# done here. The rows emitted here carry: code, severity, layer, subject_type,
# subject_ref, message, evidence, and is_strict_only.
#
# Resolution and runtime profile generation live in R/schema-catalog.R and
# R/schema-profile.R. This module wires those to xml2::xml_validate() and maps
# the outcome to two stable codes:
#   * SCHEMA_INVALID — the document fails XSD validation; one finding per
#     libxml2 error, scoped (where possible) to the offending element and its
#     namespace, so a broken extension element in a mixed document is reported
#     against that extension rather than the whole document.
#   * SCHEMA_UNKNOWN_NAMESPACE — the document uses a namespace the catalog does
#     not recognise; one finding per unknown namespace and no validation against
#     it (architecture.md §6).
#
# XXE safety (architecture.md §6): the caller parses with `read_sitemap_xml()`,
# which uses xml2's default libxml2 options — `NOENT`/`DTDLOAD` are never set,
# so external entities are not expanded. libxml2 cannot XSD-validate a tree that
# still contains entity-reference nodes; that case is reported as a single clean
# SCHEMA_INVALID finding (never the raw internal parser message). No Java, no
# subprocess, no network: validation is pure libxml2 via xml2.

# Construct the schema-layer findings tibble. The single source of truth for the
# columns this producer emits (a contract-shaped subset; `mode` and
# `remediation_hint` are added by Layer F). Each `evidence` entry is the named
# list `list(excerpt, line, column)` from the findings contract.
schema_findings <- function(
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
    layer = rep("schema", n),
    subject_type = as.character(subject_type),
    subject_ref = as.character(subject_ref),
    message = as.character(message),
    evidence = if (length(evidence) > 0L) evidence else vector("list", n),
    is_strict_only = as.logical(is_strict_only)
  )
}

# A zero-row schema-findings tibble (a fully valid document, or a non-sitemap
# root that is not Layer C's concern).
empty_schema_findings <- function() {
  schema_findings()
}

# Append a fragment to a subject_ref base, tolerating an absent base.
schema_ref_fragment <- function(base, fragment) {
  if (is.na(base) || !nzchar(base)) {
    return(fragment)
  }
  paste0(base, fragment)
}

# The distinct namespace URIs actually used by elements in `doc`. Declared
# namespaces are the candidate set (a handful); each is kept only if some
# element is in it, so an over-declared but unused namespace does not trigger a
# spurious SCHEMA_UNKNOWN_NAMESPACE. The per-namespace existence probe
# short-circuits at the first match, so this stays cheap on large documents.
schema_document_namespaces <- function(doc) {
  declared <- unique(unname(xml2::xml_ns(doc)))
  declared <- declared[nzchar(declared)]
  if (length(declared) == 0L) {
    return(character())
  }
  used <- vapply(
    declared,
    function(uri) {
      node <- xml2::xml_find_first(
        doc,
        sprintf("//*[namespace-uri()='%s']", uri)
      )
      !inherits(node, "xml_missing")
    },
    logical(1L)
  )
  declared[used]
}

# One SCHEMA_UNKNOWN_NAMESPACE finding per unrecognised namespace.
schema_unknown_ns_findings <- function(namespaces, subject_ref) {
  rows <- lapply(namespaces, function(ns) {
    schema_findings(
      code = "SCHEMA_UNKNOWN_NAMESPACE",
      severity = "error",
      subject_type = "document",
      subject_ref = subject_ref,
      message = sprintf(
        paste0(
          "Namespace '%s' is not recognised by the schema catalog; the ",
          "document was not validated against it."
        ),
        ns
      ),
      evidence = list(finding_evidence(excerpt = ns)),
      is_strict_only = FALSE
    )
  })
  do.call(rbind, rows)
}

# Map one libxml2 validation error string to a SCHEMA_INVALID finding, scoped to
# the offending element and its namespace when the message names one (libxml2
# prefixes structural and datatype errors with `Element '{ns}local'`).
schema_invalid_row <- function(err, subject_ref) {
  match <- regmatches(
    err,
    regexec("^Element '\\{([^}]*)\\}([^']*)'", err)
  )[[1]]

  if (length(match) == 3L) {
    el_ns <- match[[2L]]
    el_local <- match[[3L]]
    schema_findings(
      code = "SCHEMA_INVALID",
      severity = "error",
      subject_type = "field",
      subject_ref = schema_ref_fragment(
        subject_ref,
        paste0("#field:", el_local)
      ),
      message = sprintf(
        "Element <%s> in the %s namespace scope failed XSD schema validation.",
        el_local,
        schema_namespace_label(el_ns)
      ),
      evidence = list(
        finding_evidence(excerpt = sprintf("{%s}%s", el_ns, el_local))
      ),
      is_strict_only = FALSE
    )
  } else {
    schema_findings(
      code = "SCHEMA_INVALID",
      severity = "error",
      subject_type = "document",
      subject_ref = subject_ref,
      message = "The document failed XSD schema validation.",
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    )
  }
}

# Map a non-empty libxml2 error set to SCHEMA_INVALID findings. A tree that
# still holds entity-reference nodes (XXE-safe, never expanded) cannot be walked
# by the XSD validator; report that as one clean finding rather than leaking the
# internal parser message.
schema_invalid_findings <- function(errors, subject_ref) {
  errors <- errors[!is.na(errors) & nzchar(errors)]
  if (any(grepl("entity reference", errors, fixed = TRUE))) {
    return(schema_findings(
      code = "SCHEMA_INVALID",
      severity = "error",
      subject_type = "document",
      subject_ref = subject_ref,
      message = paste0(
        "The document contains XML entity references, which are not expanded ",
        "for safety (XXE protection), so it cannot be schema-validated as-is."
      ),
      evidence = list(finding_evidence()),
      is_strict_only = FALSE
    ))
  }
  if (length(errors) == 0L) {
    # xml_validate reported invalid but surfaced no message; emit one row so the
    # failure is never silently dropped.
    errors <- ""
  }
  rows <- lapply(errors, schema_invalid_row, subject_ref = subject_ref)
  do.call(rbind, rows)
}

#' Validate a parsed sitemap document against its XSD profile
#'
#' Layer C finding-producer: resolves the document's schema profile (generating
#' a runtime mixed-namespace wrapper when needed), runs `xml2::xml_validate()`,
#' and maps the outcome to schema findings. Produces no rows for a valid
#' document. Does not assemble the final findings contract (no `mode`, no
#' filtering/dedup/sort — those are Layer F).
#'
#' @param doc A parsed `xml2` document (parse it with the XXE-safe
#'   `read_sitemap_xml()`; external entities are never expanded).
#' @param subject_ref Stable `sitemap://…` reference for the document, used as
#'   the base of each finding's `subject_ref`. `NA` yields fragment-only refs.
#' @param schemas_dir,cache,dir Forwarded to `schema_profile()` (bundled-schema
#'   directory, the runtime-wrapper cache, and the wrapper output directory).
#' @return A schema-findings tibble (zero rows when the document is valid).
#' @keywords internal
#' @noRd
validate_schema <- function(
  doc,
  subject_ref = NA_character_,
  schemas_dir = schema_dir(),
  cache = schema_profile_cache,
  dir = tempdir()
) {
  root_kind <- schema_root_kind(xml2::xml_name(xml2::xml_root(doc)))
  if (is.na(root_kind)) {
    # An unsupported root is rejected by the parse layer as a classed condition;
    # it is not a schema finding.
    return(empty_schema_findings())
  }

  namespaces <- schema_document_namespaces(doc)
  profile <- schema_profile(
    root_kind,
    namespaces,
    schemas_dir = schemas_dir,
    cache = cache,
    dir = dir
  )

  if (identical(profile$kind, "unknown-namespace")) {
    return(schema_unknown_ns_findings(
      profile$unknown_namespaces,
      subject_ref
    ))
  }

  schema <- xml2::read_xml(profile$schema_path)
  result <- xml2::xml_validate(doc, schema)
  if (isTRUE(as.logical(result))) {
    return(empty_schema_findings())
  }

  schema_invalid_findings(attr(result, "errors"), subject_ref)
}
