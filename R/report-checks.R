# Report section: which checks ran, and which of them passed (SITE-sftfhtlv).
#
# A report that lists only what FAILED cannot tell "checked and found nothing"
# apart from "never checked at all" — a clean sitemap rendered only "No issues
# found.", which is exactly as informative as an empty page. This section closes
# that gap by enumerating the registry's checks and their outcome.
#
# It is registry-driven (R/findings-registry.R), never a hand-kept list, and two
# rules keep it honest:
#
#   1. ELIGIBILITY. Only `status == "active"` codes count. A `validator-only`
#      row names a check the sibling port has and this one does not, so
#      reporting it as passed would advertise a check that cannot run here.
#   2. POSITIVE EVIDENCE ONLY. A layer counts as having run only when something
#      in the result proves it ran. A layer that cannot be proven is reported as
#      NOT RUN — never as passed. Understating is the safe direction: the
#      sibling currently reports two of its page checks as passed while their
#      inputs are wired to nothing, and that is the failure mode to avoid.
#
# The findings tibble carries no run manifest, so the evidence is assembled from
# what the result objects do expose: the per-source fetch/classification
# records, the presence of URL rows, the `page_coverage` attribute page
# inspection stamps, and the findings themselves (a fired code proves its own
# layer ran).

# Per-layer run evidence: a named logical over `report_layer_order`, TRUE only
# where the run demonstrably exercised that layer.
#
# Deliberate understatements, each unavoidable with the evidence at hand:
#   * `robots` — `check_robots = TRUE` leaves NO trace when every URL is
#     allowed, so a clean robots run is indistinguishable from a skipped one. It
#     can only be proven by a robots finding.
#   * `schema` / `protocol` for a gzip or tar payload — the source record keeps
#     the OUTER format, so the inner document's root is unknown here. URL rows
#     still prove the protocol layer ran; schema validation stays unproven.
report_layer_ran <- function(urls, sources, findings) {
  if (is.null(sources)) {
    sources <- empty_source_metadata()
  }
  # Only a source that parsed reached the classification/schema stages.
  parsed <- is.na(sources$error_class)
  fmt <- as.character(sources$format)[parsed]

  ran <- c(
    # Input resolution runs on every call, before anything else can.
    input = TRUE,
    # A transport outcome — an HTTP status, or the error class of a failed
    # attempt — means a fetch happened. A local file records neither.
    fetch = any(!is.na(sources$status) | !is.na(sources$error_class)),
    # Robots.txt-based discovery is its own entry point, never part of a
    # single-source read, so a report can never prove it ran.
    discovery = FALSE,
    # Every source that parsed had its bytes sniffed and classified.
    classification = any(parsed),
    # Only a gzip or tar payload is decompressed at all.
    decompression = any(fmt %in% c("gzip", "tar")),
    # XSD validation runs for the two supported roots only: an unsupported root
    # short-circuits to a classification finding instead.
    schema = any(fmt %in% c("xml-urlset", "xml-sitemapindex")),
    # URL rows exist only because they were parsed, and every parsed row goes
    # through the entry- and document-level protocol checks.
    protocol = nrow(urls) > 0L,
    # The expander engages under a sitemapindex root and nowhere else.
    `index-expansion` = any(fmt == "xml-sitemapindex"),
    # Page inspection stamps its batch-wide coverage; the attribute is absent
    # exactly when `inspect_pages = FALSE` (validate_sitemap() Value).
    page = !is.null(attr(findings, "page_coverage")),
    robots = FALSE,
    # The per-code cap that emits REPORT_TRUNCATED runs at every assembly.
    report = TRUE
  )
  # A finding is proof its own layer ran, whatever the evidence above concluded.
  # This is what makes `robots` reachable, and it keeps the table
  # self-consistent: a layer can never show a fired code while claiming it did
  # not run.
  ran[names(ran) %in% findings$layer] <- TRUE
  ran[report_layer_order]
}

# One row per active registry code with its outcome: "fired" (it is in the
# findings, and therefore already rendered in the findings section), "passed"
# (its layer ran and it did not fire), or "not-run" (its layer is unproven).
# Sorted by layer order, then code, so the table reads in pipeline order.
report_check_states <- function(urls, sources, findings) {
  codes <- findings_active_codes()
  ran <- report_layer_ran(urls, sources, findings)

  state <- rep("not-run", nrow(codes))
  state[ran[codes$layer]] <- "passed"
  state[codes$code %in% findings$code] <- "fired"
  codes$state <- state

  codes[order(factor(codes$layer, levels = report_layer_order), codes$code), ]
}

# The one-line tally above the table. Names the denominator (the registry's
# active checks) so the numbers are anchored to something a reader can look up.
report_checks_summary <- function(states) {
  n_passed <- sum(states$state == "passed")
  n_fired <- sum(states$state == "fired")
  n_skipped <- sum(states$state == "not-run")
  htmltools::tags$p(
    class = "smr-note",
    sprintf(
      paste(
        "%s of %s registry checks ran on this sitemap: %s passed, %s",
        "reported an issue. %s were not exercised by this run."
      ),
      format(n_passed + n_fired, big.mark = ","),
      format(nrow(states), big.mark = ","),
      format(n_passed, big.mark = ","),
      format(n_fired, big.mark = ","),
      format(n_skipped, big.mark = ",")
    )
  )
}

report_check_row <- function(states, i) {
  htmltools::tags$tr(
    htmltools::tags$td(
      htmltools::tags$span(class = "smr-code smr-code-info", states$code[i])
    ),
    htmltools::tags$td(class = "smr-dim", states$layer[i]),
    htmltools::tags$td(class = "smr-dim smr-small", states$severity[i])
  )
}

# The passed checks themselves, collapsed by default: the count is the headline
# and the enumeration is for a reader who wants to audit it, so it must not push
# the findings off the screen.
report_checks_table <- function(passed) {
  if (nrow(passed) == 0L) {
    return(NULL)
  }
  rows <- lapply(seq_len(nrow(passed)), function(i) {
    report_check_row(passed, i)
  })
  htmltools::tags$details(
    class = "smr-checks",
    htmltools::tags$summary(sprintf(
      "%s check%s passed",
      format(nrow(passed), big.mark = ","),
      if (nrow(passed) != 1L) "s" else ""
    )),
    htmltools::tags$div(
      class = "smr-tablewrap",
      htmltools::tags$table(
        class = "smr-table",
        htmltools::tags$thead(htmltools::tags$tr(
          htmltools::tags$th("Check"),
          htmltools::tags$th("Layer"),
          htmltools::tags$th("Severity if it fires")
        )),
        htmltools::tags$tbody(rows)
      )
    )
  )
}

# The layers this run cannot vouch for, named so the omission is explicit rather
# than a silent gap in the table.
report_checks_skipped_note <- function(skipped) {
  if (nrow(skipped) == 0L) {
    return(NULL)
  }
  layers <- unique(skipped$layer)
  htmltools::tags$p(
    class = "smr-note",
    sprintf(
      paste(
        "Not exercised (%s): %s. These checks neither passed nor failed \u2014",
        "nothing in this run proves they ran, so they are reported as",
        "unknown rather than clean."
      ),
      format(nrow(skipped), big.mark = ","),
      toString(layers)
    )
  )
}

report_checks_section <- function(urls, sources, findings) {
  states <- report_check_states(urls, sources, findings)
  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$h2("Checks"),
    report_checks_summary(states),
    report_checks_table(states[states$state == "passed", , drop = FALSE]),
    report_checks_skipped_note(
      states[states$state == "not-run", , drop = FALSE]
    )
  )
}
