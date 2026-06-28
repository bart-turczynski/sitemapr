# Schema profile catalog (Layer C; architecture.md §6).
#
# Pure logic and lookups only — NO XML parsing or validation happens here.
# This file answers one question: given a document's root kind (urlset vs
# sitemapindex) and the set of XML namespaces it uses, which XSD profile should
# Layer C validate it against, and how is that decision cached?
#
# The bundled schemas live in `inst/schemas/` (read-only after install). The
# core Sitemap Protocol 0.9 namespace is special: it maps to `sitemap.xsd` for a
# `urlset` root and `siteindex.xsd` for a `sitemapindex` root. Every other
# (extension) namespace maps 1:1 to a bundled schema file.
#
# Resolution prefers pre-composed profiles before runtime generation:
#   1. core-only docs validate directly against the bundled core schema;
#   2. mixed-namespace docs prefer a pre-composed profile in
#      `inst/schemas/generated/` if one exists;
#   3. otherwise the resolver returns a "runtime" decision, leaving wrapper
#      generation to R/schema-profile.R (S6.3);
#   4. a namespace the catalog does not recognise yields an
#      "unknown-namespace" decision (mapped to SCHEMA_UNKNOWN_NAMESPACE in
#      Layer C, never a generated import).
#
# Profile cache key is (catalog_version, root_kind, sorted_namespace_set) per
# architecture.md §6. The catalog version is bumped whenever the bundled file
# set, namespace map, or resolution semantics change, so a cached profile from
# an older catalog is never reused.

# Catalog version. Bump on any change to the bundled file set, the namespace
# map, or resolution semantics so stale cached profiles are not reused.
schema_catalog_version <- "1"

# The core Sitemap Protocol 0.9 namespace, shared by `urlset` and
# `sitemapindex` roots. Always implied by a sitemap document's root element.
schema_core_namespace <- "http://www.sitemaps.org/schemas/sitemap/0.9"

# Extension namespace URI -> bundled schema file. The core namespace is handled
# separately (it maps to one of two files depending on the root kind).
schema_extension_catalog <- function() {
  c(
    "http://www.google.com/schemas/sitemap-image/1.1"   = "sitemap-image.xsd",
    "http://www.google.com/schemas/sitemap-video/1.1"   = "sitemap-video.xsd",
    "http://www.google.com/schemas/sitemap-news/0.9"    = "sitemap-news.xsd",
    "http://www.google.com/schemas/sitemap-pagemap/1.0" = "sitemap-pagemap.xsd",
    "http://www.w3.org/1999/xhtml"                      = "xhtml-hreflang.xsd"
  )
}

# Short, stable slug per extension namespace, used to name a pre-composed
# profile in inst/schemas/generated/ deterministically (sorted by slug).
schema_namespace_slugs <- function() {
  c(
    "http://www.google.com/schemas/sitemap-image/1.1"   = "image",
    "http://www.google.com/schemas/sitemap-video/1.1"   = "video",
    "http://www.google.com/schemas/sitemap-news/0.9"    = "news",
    "http://www.google.com/schemas/sitemap-pagemap/1.0" = "pagemap",
    "http://www.w3.org/1999/xhtml"                      = "hreflang"
  )
}

# Absolute path to the installed (or, under devtools, the source) schema dir.
# "" when the package is not installed and not loaded from source.
schema_dir <- function() {
  system.file("schemas", package = "sitemapr")
}

# The bundled core schema file for a root kind: sitemap.xsd for urlset,
# siteindex.xsd for sitemapindex, NA for any other (unsupported) root.
schema_core_file <- function(root_kind) {
  switch(root_kind,
    urlset = "sitemap.xsd",
    sitemapindex = "siteindex.xsd",
    NA_character_
  )
}

# Map a root element's local name to a supported root kind, or NA for any other
# element. Pure name lookup; the caller supplies the local name (a urlset/
# sitemapindex with any namespace prefix resolves to the same local name).
schema_root_kind <- function(root_local_name) {
  if (identical(root_local_name, "urlset")) {
    "urlset"
  } else if (identical(root_local_name, "sitemapindex")) {
    "sitemapindex"
  } else {
    NA_character_
  }
}

# Normalise a namespace set: drop empty/NA, de-duplicate, sort. The core
# namespace is retained when present so the cache key reflects the full set.
schema_sorted_namespace_set <- function(namespaces) {
  ns <- namespaces[!is.na(namespaces) & nzchar(namespaces)]
  sort(unique(ns))
}

# Profile cache key per architecture.md §6: catalog version, root kind, and the
# sorted namespace set, joined into one stable string. Order-insensitive in the
# namespace set (it is sorted) and stable across releases for a fixed catalog.
schema_cache_key <- function(root_kind, namespaces,
                             catalog_version = schema_catalog_version) {
  ns <- schema_sorted_namespace_set(namespaces)
  paste(c(catalog_version, root_kind, ns), collapse = "|")
}

# Deterministic basename for a pre-composed mixed-namespace profile, e.g.
# "urlset-image-news.xsd". Extension namespaces are mapped to slugs and sorted
# so the name is independent of namespace order. Used only to probe for a
# pre-composed file in inst/schemas/generated/.
schema_profile_basename <- function(root_kind, extension_namespaces) {
  slugs <- schema_namespace_slugs()[extension_namespaces]
  slugs <- sort(slugs[!is.na(slugs)])
  paste0(paste(c(root_kind, slugs), collapse = "-"), ".xsd")
}

#' Resolve the Layer C schema profile for a document
#'
#' Pure decision logic: given the document's root kind and the set of XML
#' namespaces it uses, decide which XSD profile validates it. No XML is parsed
#' or validated here; the returned `kind` tells Layer C how to obtain the schema
#' document.
#'
#' @param root_kind `"urlset"` or `"sitemapindex"` (see [schema_root_kind()]).
#' @param namespaces Character vector of namespace URIs present in the document
#'   (may include the core namespace; order and duplicates do not matter).
#' @param schemas_dir Directory holding the bundled schemas. Defaults to the
#'   installed `inst/schemas`.
#' @return A list describing the resolution:
#'   * `kind` — one of `"bundled"` (validate against the single bundled core
#'     schema), `"generated"` (a pre-composed profile exists on disk),
#'     `"runtime"` (a wrapper must be generated, S6.3), or
#'     `"unknown-namespace"` (an unrecognised namespace is present).
#'   * `cache_key` — the `(catalog_version, root_kind, sorted_namespace_set)`
#'     key (see [schema_cache_key()]).
#'   * `root_kind`, `namespaces` — the (sorted) inputs echoed back.
#'   * `schema_path` — absolute path to the validating schema for `"bundled"`
#'     and `"generated"`; `NA` for `"runtime"`/`"unknown-namespace"`.
#'   * `imports` — named character vector (namespace -> absolute schema path) of
#'     every schema a runtime wrapper must `xsd:import`; empty for core-only.
#'   * `unknown_namespaces` — namespaces not in the catalog (only for
#'     `"unknown-namespace"`).
#' @keywords internal
#' @noRd
schema_resolve_profile <- function(root_kind, namespaces,
                                   schemas_dir = schema_dir()) {
  ns <- schema_sorted_namespace_set(namespaces)
  cache_key <- schema_cache_key(root_kind, ns)

  base <- list(
    cache_key = cache_key,
    root_kind = root_kind,
    namespaces = ns,
    schema_path = NA_character_,
    imports = character(),
    unknown_namespaces = character()
  )

  extension_ns <- setdiff(ns, schema_core_namespace)
  catalog <- schema_extension_catalog()
  unknown <- setdiff(extension_ns, names(catalog))
  if (length(unknown) > 0L) {
    return(utils::modifyList(base, list(
      kind = "unknown-namespace",
      unknown_namespaces = unknown
    )))
  }

  core_path <- file.path(schemas_dir, schema_core_file(root_kind))

  # Core-only: the bundled core schema validates the document directly.
  if (length(extension_ns) == 0L) {
    return(utils::modifyList(base, list(
      kind = "bundled",
      schema_path = core_path
    )))
  }

  # Mixed namespaces: a wrapper must import the core schema and each extension
  # schema. Prefer a pre-composed profile if one was generated at build time.
  imports <- c(core_path, file.path(schemas_dir, catalog[extension_ns]))
  names(imports) <- c(schema_core_namespace, extension_ns)
  composed <- file.path(
    schemas_dir, "generated",
    schema_profile_basename(root_kind, extension_ns)
  )
  if (file.exists(composed)) {
    return(utils::modifyList(base, list(
      kind = "generated",
      schema_path = composed,
      imports = imports
    )))
  }

  utils::modifyList(base, list(
    kind = "runtime",
    imports = imports
  ))
}
