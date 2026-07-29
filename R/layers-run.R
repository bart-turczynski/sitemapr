# The run manifest: which validation layers a call actually exercised
# (SITE-ysoqjxpm).
#
# The report's Checks section decides, per layer, between "ran and found
# nothing" and "never ran". R/report-checks.R infers that from the result — the
# source records, the URL rows, the `page_coverage` attribute, and the fired
# findings — and two cases cannot be proven from the result alone:
#
#   * `robots` — `check_robots = TRUE` leaves no trace when every advertised URL
#     is allowed, so a clean robots run looks exactly like a skipped one.
#   * `schema` — a gzip source records the OUTER format, so the inflated
#     document's root is invisible afterwards even though `validate_schema()`
#     did run on it.
#
# Both are facts the RUN knows and the RESULT forgets. This sink lets the
# executing code record a layer at the point it runs; the layers are stamped
# onto the findings tibble as `attr(x, "layers_run")` and the report unions them
# into its inference. Only positive evidence flows, so an absent stamp leaves
# the inference exactly as it was — an older result, or a hand-built findings
# tibble, still renders.
#
# Deliberately an attribute and never a column: the findings tibble is the
# public ten-column contract (schema v1), so a column would be a contract
# migration.
#
# Only the two layers above are recorded. The mechanism generalizes — a new
# layer needs one `layer_sink_record()` call where it executes — but recording a
# layer the inference already proves buys nothing. Note that the ARCHIVE path is
# not one of them: `validate_archive_parts()` reaches no `validate_schema()`
# call, so a `.tar.gz` genuinely does not schema-validate and its `schema =
# FALSE` is honest rather than an understatement.

# A run-scoped collector for exercised layers. Rides on the resolved source
# (`src$layer_sink`) the same way `robots_ua` and `page_sink` do, so recording a
# layer costs no new function argument.
layer_sink_new <- function() {
  sink <- new.env(parent = emptyenv())
  sink$layers <- character(0)
  sink
}

# Record `layer` as exercised. NULL-safe, so an internal producer called
# directly (or from a test) with no sink is a no-op rather than an error.
layer_sink_record <- function(sink, layer) {
  if (is.null(sink)) {
    return(invisible(NULL))
  }
  if (!layer %in% sink$layers) {
    sink$layers <- c(sink$layers, layer)
  }
  invisible(NULL)
}

# Stamp a set of exercised layers onto an assembled findings tibble. An empty
# set attaches NO attribute, keeping such a result identical to one produced
# before this stamp existed.
findings_stamp_layers <- function(findings, layers) {
  if (length(layers) == 0L) {
    return(findings)
  }
  attr(findings, "layers_run") <- layers
  findings
}

# The same stamp, read off a sink. NULL-safe for the same reason
# `layer_sink_record()` is.
layer_sink_stamp <- function(findings, sink) {
  findings_stamp_layers(
    findings,
    if (is.null(sink)) character(0) else sink$layers
  )
}

# The layers a run recorded, or `character(0)` when it carries no stamp. The one
# reader of the attribute, so a consumer never has to know whether it is there.
findings_layers_run <- function(findings) {
  layers <- attr(findings, "layers_run", exact = TRUE)
  if (is.null(layers)) {
    return(character(0))
  }
  layers
}

# Union the stamps of the per-source contracts being combined into one result.
# `[` and `new_tibble()` both drop attributes, so the union has to be taken
# before the re-impose and re-attached after it — the trap `precap_totals` hit
# in SITE-tudzmegl.
findings_layers_run_union <- function(parts) {
  layers <- unlist(lapply(parts, findings_layers_run), use.names = FALSE)
  if (is.null(layers)) {
    return(character(0))
  }
  unique(layers)
}
