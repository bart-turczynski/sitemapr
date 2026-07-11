# sitemap_audit: a first-class result container (SITE-dfwrwbeg).
#
# A `sitemap_audit` bundles the tidy shapes the package already produces into
# one object with stable, named components:
#   - urls     : the `read_sitemap()` tidy row tibble (architecture.md §7).
#   - findings : the `validate_sitemap()` findings contract (Layer F).
#   - sources  : the per-source fetch-metadata records (`read_sitemap()`'s
#                `sources` attribute).
#   - problems : the non-fatal parse `problems` companion table
#                (`read_sitemap()`'s `problems` attribute).
#   - tree     : the `sitemap_tree()` discovery/index structure.
#
# The container does NOT redefine any of those shapes: component VALUES are the
# existing tibbles/frames, and the column contract is derived from the same
# empty-shape constructors the producers use, so the container can never drift.
# This slice only ADDS the container plus accessors; it does not change the
# return contract of read_sitemap()/validate_sitemap()/report_sitemap(), and it
# does not itself run the pipeline that produces the pieces (SITE-zkjoglmx).
#
# Empty vs partial behavior. Every component always exists. `sitemap_audit()`
# with no arguments yields a fully EMPTY-but-valid audit (five zero-row
# schema tibbles). A PARTIAL audit is one where some components are supplied and
# the rest fall back to their empty schema — e.g. urls read but not yet
# validated (findings empty), or findings computed without a discovery tree
# (tree empty). Validation checks column contracts, never row counts, so a
# partial audit is a first-class valid object.

# The five component names, in their canonical display/storage order.
audit_component_names <- function() {
  c("urls", "findings", "sources", "problems", "tree")
}

# The expected column contract for each component, taken from the existing
# empty-shape constructors so the container is defined in terms of — never a
# copy of — the shapes the package already produces.
audit_component_columns <- function(name) {
  switch(
    name,
    urls = names(empty_sitemap_rows()),
    findings = names(empty_findings_contract()),
    sources = names(empty_source_metadata()),
    problems = names(empty_problems()),
    tree = names(empty_sitemap_tree())
  )
}

# The zero-row schema for a missing component (the empty/partial fallback).
audit_empty_component <- function(name) {
  switch(
    name,
    urls = project_typed_rows(empty_sitemap_rows()),
    findings = empty_findings_contract(),
    sources = empty_source_metadata(),
    problems = empty_problems(),
    tree = empty_sitemap_tree()
  )
}

# Severity ranking used by print()/summary(); mirrors the findings contract.
audit_severity_levels <- function() {
  c("fatal", "error", "warning", "info")
}

# Named severity counts over the four contract levels (zeros for absent ones).
audit_severity_counts <- function(findings) {
  levels <- audit_severity_levels()
  vapply(
    levels,
    function(s) sum(findings$severity == s, na.rm = TRUE),
    integer(1L)
  )
}

# Guard: every public accessor / method takes a `sitemap_audit`.
audit_check_class <- function(x) {
  if (!inherits(x, "sitemap_audit")) {
    rlang::abort(
      "`x` must be a `sitemap_audit` object.",
      class = "sitemapr_bad_input"
    )
  }
  invisible(x)
}

#' Low-level `sitemap_audit` constructor
#'
#' Assembles the five already-built components into the classed list without
#' validation. Callers should use [sitemap_audit()], which fills empty
#' components and validates the shapes.
#'
#' @param urls,findings,sources,problems,tree The component tibbles/frames.
#' @return A bare `sitemap_audit` object.
#' @keywords internal
#' @noRd
new_sitemap_audit <- function(urls, findings, sources, problems, tree) {
  structure(
    list(
      urls = urls,
      findings = findings,
      sources = sources,
      problems = problems,
      tree = tree
    ),
    class = "sitemap_audit"
  )
}

# Validate one component: present, a data frame, and carrying (at least) the
# contract columns. Row count is never checked (empty is valid).
audit_validate_component <- function(comp, name) {
  if (!is.data.frame(comp)) {
    rlang::abort(
      sprintf("audit component `%s` must be a data frame.", name),
      class = "sitemapr_bad_input"
    )
  }
  missing <- setdiff(audit_component_columns(name), names(comp))
  if (length(missing) > 0L) {
    rlang::abort(
      sprintf(
        "audit component `%s` is missing columns: %s.",
        name,
        toString(missing)
      ),
      class = "sitemapr_bad_input"
    )
  }
  invisible(comp)
}

#' Validate a `sitemap_audit` object
#'
#' Checks that every component is present and carries its documented column
#' contract. Empty (zero-row) and partial audits are valid; only shape
#' violations abort.
#'
#' @param x A `sitemap_audit` object.
#' @return `x`, invisibly, if valid; otherwise a classed error is raised.
#' @keywords internal
#' @noRd
validate_sitemap_audit <- function(x) {
  audit_check_class(x)
  for (name in audit_component_names()) {
    audit_validate_component(x[[name]], name)
  }
  invisible(x)
}

# Resolve a supplied-or-NULL component to a validated component tibble.
audit_resolve_component <- function(value, name) {
  if (is.null(value)) {
    return(audit_empty_component(name))
  }
  value
}

#' Assemble a sitemap audit result container
#'
#' Bundles precomputed sitemapr outputs into a single validated `sitemap_audit`
#' object with stable, named components. It performs no fetching, parsing, or
#' validation of its own: it *assembles* shapes the package already produces
#' (see [read_sitemap()], [validate_sitemap()], and [sitemap_tree()]) into one
#' first-class result and validates their column contracts.
#'
#' Because a [read_sitemap()] result already carries its per-source metadata and
#' non-fatal parse problems as the `sources` and `problems` attributes, those
#' two components are pulled from `urls` when not passed explicitly, and then
#' promoted to first-class components (the stored `urls` component is the plain
#' tidy tibble, without those attributes). Any component left `NULL` defaults to
#' its empty (zero-row) schema, so `sitemap_audit()` with no arguments is a
#' valid empty audit and any subset of components yields a valid partial audit.
#'
#' @param urls A [read_sitemap()] tidy row tibble (optionally carrying the
#'   `sources`/`problems` attributes). Defaults to the empty row schema.
#' @param findings A [validate_sitemap()] findings tibble. Defaults to the empty
#'   findings contract.
#' @param sources The per-source fetch-metadata records. Defaults to the
#'   `sources` attribute of `urls` when present, otherwise the empty schema.
#' @param problems The non-fatal parse `problems` companion table. Defaults to
#'   the `problems` attribute of `urls` when present, else the empty schema.
#' @param tree A [sitemap_tree()] discovery/index structure. Defaults to the
#'   empty tree schema.
#' @return A validated `sitemap_audit` object: a classed list with the
#'   components `urls`, `findings`, `sources`, `problems`, and `tree`. Access
#'   them with [audit_urls()], [audit_findings()], [audit_sources()],
#'   [audit_problems()], and [audit_tree()].
#' @seealso [read_sitemap()], [validate_sitemap()], and [sitemap_tree()] for the
#'   component producers.
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
#' # Assemble precomputed read + validate results into one container.
#' audit <- sitemap_audit(
#'   urls = read_sitemap(path),
#'   findings = validate_sitemap(path, mode = "non-strict")
#' )
#' audit
#' summary(audit)
#'
#' # An empty audit is valid (all components are zero-row schemas).
#' sitemap_audit()
sitemap_audit <- function(
  urls = NULL,
  findings = NULL,
  sources = NULL,
  problems = NULL,
  tree = NULL
) {
  if (is.null(sources) && !is.null(urls)) {
    sources <- attr(urls, "sources")
  }
  if (is.null(problems) && !is.null(urls)) {
    problems <- attr(urls, "problems")
  }

  urls <- audit_resolve_component(urls, "urls")
  # The promoted attributes now live in first-class components; drop them from
  # the stored `urls` so each component is the canonical single source of truth.
  attr(urls, "sources") <- NULL
  attr(urls, "problems") <- NULL

  audit <- new_sitemap_audit(
    urls = urls,
    findings = audit_resolve_component(findings, "findings"),
    sources = audit_resolve_component(sources, "sources"),
    problems = audit_resolve_component(problems, "problems"),
    tree = audit_resolve_component(tree, "tree")
  )
  validate_sitemap_audit(audit)
  audit
}

#' Access the components of a sitemap audit
#'
#' Component accessors for a [sitemap_audit()] object. Each returns the stable
#' tidy shape the package already produces: `audit_urls()` the [read_sitemap()]
#' row tibble, `audit_findings()` the [validate_sitemap()] findings contract,
#' `audit_sources()` the per-source fetch-metadata records, `audit_problems()`
#' the non-fatal parse `problems` table, and `audit_tree()` the [sitemap_tree()]
#' discovery/index structure.
#'
#' @param x A `sitemap_audit` object, as from [sitemap_audit()].
#' @return The requested component: a tibble or data frame with the documented
#'   columns (zero rows for an empty component).
#' @name audit_accessors
#' @examples
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   '<url><loc>https://example.com/</loc></url></urlset>'
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#' audit <- sitemap_audit(urls = read_sitemap(path))
#'
#' audit_urls(audit)
#' audit_findings(audit)
#' audit_sources(audit)
#' audit_problems(audit)
#' audit_tree(audit)
NULL

#' @rdname audit_accessors
#' @export
audit_urls <- function(x) {
  audit_check_class(x)
  x$urls
}

#' @rdname audit_accessors
#' @export
audit_findings <- function(x) {
  audit_check_class(x)
  x$findings
}

#' @rdname audit_accessors
#' @export
audit_sources <- function(x) {
  audit_check_class(x)
  x$sources
}

#' @rdname audit_accessors
#' @export
audit_problems <- function(x) {
  audit_check_class(x)
  x$problems
}

#' @rdname audit_accessors
#' @export
audit_tree <- function(x) {
  audit_check_class(x)
  x$tree
}

#' Access the sources and problems companions of a sitemap result
#'
#' `sources()` and `problems()` return the two companion tables the package
#' produces alongside its tidy URL rows: the per-source fetch-metadata records
#' and the non-fatal parse `problems` table. They dispatch on the object type,
#' so the same call works on a [read_sitemap()] result and on a
#' [sitemap_audit()] object:
#'
#' * On a [read_sitemap()] result, they read the `sources` / `problems`
#'   attributes the entry point attaches to the tidy tibble, so callers need not
#'   reach for `attr()`.
#' * On a [sitemap_audit()] object, they return the first-class `sources` /
#'   `problems` components, delegating to [audit_sources()] / [audit_problems()]
#'   for identical behavior.
#'
#' The default methods return the requested attribute (or `NULL` when the object
#' carries none), so they are safe to call on any object.
#'
#' @param x A [read_sitemap()] result (a tidy tibble carrying the
#'   `sources`/`problems` attributes) or a [sitemap_audit()] object.
#' @param ... Ignored; reserved for future methods.
#' @return For `sources()`, the per-source fetch-metadata records; for
#'   `problems()`, the non-fatal parse `problems` table. A [sitemap_audit()]
#'   object always yields the documented (possibly zero-row) component; a
#'   [read_sitemap()] result yields its attached companion table.
#' @seealso [audit_sources()] and [audit_problems()] for the `sitemap_audit`
#'   component accessors.
#' @name sitemap_companions
#' @examples
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   '<url><loc>https://example.com/</loc></url></urlset>'
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#' urls <- read_sitemap(path)
#'
#' sources(urls)
#' problems(urls)
#'
#' # The same accessors work on a sitemap_audit object.
#' audit <- sitemap_audit(urls = urls)
#' sources(audit)
#' problems(audit)
NULL

#' @rdname sitemap_companions
#' @export
sources <- function(x, ...) {
  UseMethod("sources")
}

#' @rdname sitemap_companions
#' @export
sources.default <- function(x, ...) {
  attr(x, "sources")
}

#' @rdname sitemap_companions
#' @export
sources.sitemap_audit <- function(x, ...) {
  audit_sources(x)
}

#' @rdname sitemap_companions
#' @export
problems <- function(x, ...) {
  UseMethod("problems")
}

#' @rdname sitemap_companions
#' @export
problems.default <- function(x, ...) {
  attr(x, "problems")
}

#' @rdname sitemap_companions
#' @export
problems.sitemap_audit <- function(x, ...) {
  audit_problems(x)
}

#' @export
print.sitemap_audit <- function(x, ...) {
  sev <- audit_severity_counts(x$findings)
  cat("<sitemap_audit>\n")
  cat(sprintf("  urls:     %d\n", nrow(x$urls)))
  cat(sprintf(
    "  findings: %d (fatal %d, error %d, warning %d, info %d)\n",
    nrow(x$findings),
    sev[["fatal"]],
    sev[["error"]],
    sev[["warning"]],
    sev[["info"]]
  ))
  cat(sprintf("  sources:  %d\n", nrow(x$sources)))
  cat(sprintf("  problems: %d\n", nrow(x$problems)))
  cat(sprintf("  tree:     %d nodes\n", nrow(x$tree)))
  invisible(x)
}

#' @export
summary.sitemap_audit <- function(object, ...) {
  list(
    n_urls = nrow(object$urls),
    findings = audit_severity_counts(object$findings),
    n_sources = nrow(object$sources),
    n_problems = nrow(object$problems),
    n_tree = nrow(object$tree)
  )
}
