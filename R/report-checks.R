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
# Three independent sources of positive evidence, unioned: the inference below,
# the run manifest a validate/audit call stamps on the findings tibble
# (`attr(x, "layers_run")`, R/layers-run.R), and the fired findings. The
# inference alone cannot prove two cases, which is why the manifest exists:
#   * `robots` — `check_robots = TRUE` leaves NO trace when every URL is
#     allowed, so a clean robots run is indistinguishable from a skipped one.
#   * `schema` for a gzip payload — the source record keeps the OUTER format, so
#     the inner document's root is unknown here.
# The manifest is optional: a findings tibble without one (an older result, or a
# hand-built tibble) falls back to the inference unchanged.
#
# One understatement remains by design: a `.tar.gz` reports `schema = FALSE`,
# and that is correct rather than conservative — the archive path reaches no
# `validate_schema()` call at all.
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
    # Nothing in the result proves this one; it comes from the run manifest (or
    # from a fired robots finding) below.
    robots = FALSE,
    # The per-code cap that emits REPORT_TRUNCATED runs at every assembly.
    report = TRUE
  )
  # What the run itself recorded. Only ever adds evidence — an unrecognised
  # layer name is ignored rather than widening the table.
  ran[names(ran) %in% findings_layers_run(findings)] <- TRUE
  # A finding is proof its own layer ran, whatever the evidence above concluded.
  # It keeps the table self-consistent: a layer can never show a fired code
  # while claiming it did not run.
  ran[names(ran) %in% findings$layer] <- TRUE
  ran[report_layer_order]
}

# Whether each active code's emitter was REACHABLE on this run, from the
# registry's `ruleset` column against the ruleset the run selected
# (SITE-lbhbltzf). The second gate on "passed", independent of the layer one: a
# layer can run in full while a check inside it stays dormant because no engine
# overlay selected it.
#
#   * `baseline` — reachable on every call.
#   * `overlay`  — reachable only when SOME engine overlay is selected.
#   * an engine name — reachable only under that one engine.
#
# `run` is `character(0)` on a baseline call and on any result carrying no
# stamp, which correctly leaves the reachable set as `baseline` alone. Phrased
# as one membership test rather than a boolean chain so an unset registry cell
# reads as unreachable rather than as NA — understating, the safe direction, as
# everywhere else here.
report_code_reachable <- function(codes, run) {
  reachable <- c("baseline", run)
  if (length(run) > 0L) {
    reachable <- c(reachable, "overlay")
  }
  codes$ruleset %in% reachable
}

# One row per active registry code with its outcome: "fired" (it is in the
# findings, and therefore already rendered in the findings section), "passed"
# (its layer ran, its emitter was reachable, and it did not fire), or "not-run".
# A `reason` accompanies each "not-run" — "layer" when the layer itself is
# unproven, "ruleset" when the layer ran but this run could not reach the
# emitter — because the two are reported to the reader differently.
# Sorted by layer order, then code, so the table reads in pipeline order.
report_check_states <- function(urls, sources, findings) {
  codes <- findings_active_codes()
  ran <- report_layer_ran(urls, sources, findings)
  reachable <- report_code_reachable(codes, findings_ruleset_run(findings))

  state <- rep("not-run", nrow(codes))
  state[ran[codes$layer] & reachable] <- "passed"
  # A fired code is proof of its own reachability, and outranks both gates for
  # the same reason `report_layer_ran()` lets it outrank the layer inference.
  state[codes$code %in% findings$code] <- "fired"
  codes$state <- state
  codes$reason <- ifelse(ran[codes$layer], "ruleset", "layer")
  codes$reason[state != "not-run"] <- NA_character_

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

# How a gating `ruleset` value reads to someone who does not know the column:
# an engine name is already the name they would pass, the `overlay` tier is
# every engine at once.
report_ruleset_label <- function(ruleset) {
  ifelse(ruleset == "overlay", "any engine", ruleset)
}

# The checks this run's RULESET could not reach, reported apart from the layer
# note above rather than folded into it: their layers did run, so one combined
# note would name a layer as unexercised while checks inside it passed.
report_checks_ruleset_note <- function(skipped, run) {
  if (nrow(skipped) == 0L) {
    return(NULL)
  }
  selected <- if (length(run) == 0L) {
    "sitemaps.org baseline"
  } else {
    paste(run, "ruleset")
  }
  htmltools::tags$p(
    class = "smr-note",
    sprintf(
      paste(
        "Gated on a ruleset this run did not select (%s, applying under: %s).",
        "This run used the %s. Their layers ran but these checks did not, so",
        "they are reported as unknown rather than clean."
      ),
      format(nrow(skipped), big.mark = ","),
      toString(sort(unique(report_ruleset_label(skipped$ruleset)))),
      selected
    )
  )
}

report_checks_section <- function(urls, sources, findings) {
  states <- report_check_states(urls, sources, findings)
  skipped <- states[states$state == "not-run", , drop = FALSE]
  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$h2("Checks"),
    report_checks_summary(states),
    report_checks_table(states[states$state == "passed", , drop = FALSE]),
    report_checks_skipped_note(
      skipped[skipped$reason == "layer", , drop = FALSE]
    ),
    report_checks_ruleset_note(
      skipped[skipped$reason == "ruleset", , drop = FALSE],
      findings_ruleset_run(findings)
    )
  )
}
