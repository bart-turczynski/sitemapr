# Runtime mixed-namespace profile generation (Layer C; architecture.md §6).
#
# Builds on the pure-logic resolver in R/schema-catalog.R. When a document mixes
# the core namespace with one or more extension namespaces and no pre-composed
# profile is bundled, Layer C cannot validate it against a single bundled file:
# the core schema admits foreign elements only through a strict `##other`
# wildcard, which libxml2 can resolve only if the extension schemas are loaded
# alongside it.
#
# This module generates a small wrapper XSD that `xsd:import`s the core schema
# and each required extension schema, so one schema document makes every needed
# declaration available to `xml2::xml_validate()`. The wrapper is written to
# `tempdir()` (never into the read-only installed tree) and references the
# bundled schemas by ABSOLUTE path via `system.file()` — never a relative path
# into the installed tree (architecture.md §6).
#
# Generated wrappers are cached per session keyed by the S6.2 profile cache key
# (catalog_version, root_kind, sorted_namespace_set), so a repeated namespace
# combination reuses one wrapper file rather than regenerating it.

# Session cache: profile cache_key -> generated wrapper path. Reset per session;
# wrappers live in tempdir() and do not persist across R sessions.
schema_profile_cache <- new.env(parent = emptyenv())

# Minimal XML attribute-value escaping for the import lines. Bundled paths and
# namespace URIs rarely contain these, but escaping keeps the wrapper
# well-formed regardless of where the package is installed.
schema_xml_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  gsub("\"", "&quot;", x, fixed = TRUE)
}

# Build the wrapper XSD text: a no-target-namespace driver schema that imports
# each (namespace -> absolute schema path) pair in `imports`.
schema_wrapper_xsd <- function(imports) {
  lines <- vapply(
    seq_along(imports),
    function(i) {
      sprintf(
        "  <xsd:import namespace=\"%s\" schemaLocation=\"%s\"/>",
        schema_xml_escape(names(imports)[[i]]),
        schema_xml_escape(imports[[i]])
      )
    },
    character(1L)
  )
  paste0(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
    "<xsd:schema xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n",
    paste(lines, collapse = "\n"),
    "\n</xsd:schema>\n"
  )
}

# Return a generated wrapper path for `imports`, reusing a cached one when this
# cache_key was already generated this session. The wrapper is written to `dir`
# (tempdir() by default) with a unique name.
schema_cached_wrapper <- function(cache_key, imports,
                                  cache = schema_profile_cache,
                                  dir = tempdir()) {
  cached <- cache[[cache_key]]
  if (!is.null(cached) && file.exists(cached)) {
    return(cached)
  }
  path <- tempfile("sitemapr-profile-", tmpdir = dir, fileext = ".xsd")
  writeLines(schema_wrapper_xsd(imports), path)
  cache[[cache_key]] <- path
  path
}

#' Resolve a document to a concrete, ready-to-validate schema profile
#'
#' Wraps the pure resolver ([schema_resolve_profile()]) with the side effect of
#' generating (and caching) a runtime wrapper XSD when the namespace combination
#' is not pre-composed. The returned `schema_path` is always a file ready to be
#' read by `xml2::xml_validate()` — except for `"unknown-namespace"`, where no
#' profile exists and Layer C must emit `SCHEMA_UNKNOWN_NAMESPACE` instead.
#'
#' @param root_kind `"urlset"` or `"sitemapindex"`.
#' @param namespaces Character vector of namespace URIs the document uses.
#' @param schemas_dir Directory of bundled schemas (default: installed
#'   `inst/schemas`).
#' @param cache Environment used to memoise generated wrappers by cache key.
#' @param dir Directory for generated wrappers (default: `tempdir()`).
#' @return A list with `kind` (`"bundled"` / `"generated"` / `"runtime"` /
#'   `"unknown-namespace"`), `schema_path` (absolute path, or `NA` when
#'   unknown), `cache_key`, and `unknown_namespaces`.
#' @keywords internal
#' @noRd
schema_profile <- function(root_kind, namespaces,
                           schemas_dir = schema_dir(),
                           cache = schema_profile_cache,
                           dir = tempdir()) {
  res <- schema_resolve_profile(
    root_kind, namespaces,
    schemas_dir = schemas_dir
  )

  out <- list(
    kind = res$kind,
    schema_path = res$schema_path,
    cache_key = res$cache_key,
    unknown_namespaces = res$unknown_namespaces
  )

  if (identical(res$kind, "runtime")) {
    out$schema_path <- schema_cached_wrapper(
      res$cache_key, res$imports,
      cache = cache, dir = dir
    )
  }

  out
}
