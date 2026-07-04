# report_sitemap(): a self-contained HTML report (Layer F reporting surface).
#
# sitemapr's public functions return tidy tibbles (read_sitemap()) and the
# findings contract (validate_sitemap()) — machine shapes. report_sitemap() is
# the human-readable surface: it CONSUMES those existing shapes (it does not
# re-implement any validation) and renders a single self-contained HTML file,
# modeled section-for-section on the sitemap-validator reference renderer
# (src/lib/report-html/index.ts). Everything is inlined — CSS, JavaScript, and
# data — so the file works offline with no CDN, network, or companion assets.
#
# Sections (mirroring the reference):
#   1. hero            — source, overall status, URL / index / sitemap counts
#   2. sitemap table   — per-source format, status, URL count, and
#                        LM/Pri/CF presence
#   3. lastmod         — coverage stat cards + a by-month histogram
#   4. URL tree        — collapsible folder tree grouped by path segment
#   5. severity board  — fatal/error/warning/info counts (canonical colors)
#   6. findings        — grouped by layer, deduped by code, with evidence
#   7. URL table       — searchable + sortable + CSV-export
#
# Beyond the light-only reference, the report ships a dark variant: the palette
# is driven by CSS custom properties that default to the viewer's
# prefers-color-scheme, and a toggle stamps `data-theme` on the root element so
# both directions (force-light on a dark OS, force-dark on a light OS) win.

# ---- constants ---------------------------------------------------------------

# Cap the interactive URL table (kept small so the file stays lightweight and
# the DOM-based search/sort stay responsive); the folder tree is capped higher.
report_url_table_cap <- 1000L
report_tree_cap <- 10000L

# Canonical severity colors, shared with the validator reference renderer.
report_severity_levels <- c("fatal", "error", "warning", "info")
report_severity_colors <- c(
  fatal = "#b91c1c",
  error = "#dc2626",
  warning = "#d97706",
  info = "#6b7280"
)

# The layer display order (the findings-contract vocabulary; see
# findings_layer_order in R/findings-assemble.R).
report_layer_order <- c(
  "input",
  "fetch",
  "discovery",
  "classification",
  "decompression",
  "schema",
  "protocol",
  "index-expansion",
  "report"
)

# ---- small helpers -----------------------------------------------------------

# Human label for a sniffed/source format string.
report_format_label <- function(format) {
  switch(
    as.character(format),
    "xml-sitemapindex" = "Index",
    "xml-urlset" = "XML",
    "xml" = "XML",
    "text" = "Text",
    "gzip" = "gzip",
    as.character(format)
  )
}

# The path portion of a URL (scheme + host stripped, query/fragment dropped),
# split into non-empty segments. Deterministic and dependency-light.
report_path_segments <- function(loc) {
  p <- sub("^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+", "", loc)
  p <- sub("[?#].*$", "", p)
  segs <- strsplit(p, "/", fixed = TRUE)[[1]]
  segs[nzchar(segs)]
}

# A count badge span (pill).
report_count_badge <- function(n) {
  htmltools::tags$span(class = "smr-badge", format(n, big.mark = ","))
}

# ---- section: hero -----------------------------------------------------------

report_hero <- function(source_label, urls, sources, findings, mode) {
  n_urls <- nrow(urls)
  n_index <- if (!is.null(sources)) {
    sum(sources$format == "xml-sitemapindex", na.rm = TRUE)
  } else {
    0L
  }
  n_sitemap <- if (!is.null(sources)) {
    sum(sources$format %in% c("xml-urlset", "xml", "text"), na.rm = TRUE)
  } else {
    length(unique(stats::na.omit(urls$source_sitemap)))
  }

  blocking <- sum(findings$severity %in% c("fatal", "error"))
  is_valid <- blocking == 0L
  status_icon <- if (is_valid) "\u2705" else "\u26a0\ufe0f"
  status_label <- if (is_valid) "Valid" else "Issues found"

  count_parts <- character(0)
  if (n_index > 0L) {
    count_parts <- c(count_parts, sprintf(
      "%d index%s", n_index, if (n_index != 1L) "es" else ""
    ))
  }
  if (n_sitemap > 0L) {
    count_parts <- c(count_parts, sprintf(
      "%d sitemap%s", n_sitemap, if (n_sitemap != 1L) "s" else ""
    ))
  }

  htmltools::tags$section(
    class = "smr-hero",
    htmltools::tags$div(
      class = "smr-hero-row",
      htmltools::tags$div(
        htmltools::tags$h1(class = "smr-hero-title", "Sitemap report"),
        htmltools::tags$p(class = "smr-hero-source", source_label),
        htmltools::tags$div(
          class = "smr-hero-stats",
          htmltools::tags$span(paste0(status_icon, " ", status_label)),
          htmltools::tags$span(
            htmltools::tags$strong(format(n_urls, big.mark = ",")),
            " URLs"
          ),
          if (length(count_parts) > 0L) {
            htmltools::tags$span(paste(count_parts, collapse = ", "))
          },
          htmltools::tags$span(class = "smr-hero-mode", paste0(mode, " mode"))
        )
      ),
      htmltools::tags$button(
        id = "smr-theme-toggle",
        class = "smr-theme-toggle",
        type = "button",
        "Toggle theme"
      )
    )
  )
}

# ---- section: sitemap table --------------------------------------------------

# Per-source metadata presence (any URL from that source carries the field).
report_node_meta <- function(urls_for_node) {
  list(
    has_lastmod = any(!is.na(urls_for_node$lastmod)),
    has_priority = any(!is.na(urls_for_node$priority)),
    has_changefreq = any(!is.na(urls_for_node$changefreq))
  )
}

report_check_cell <- function(present) {
  if (isTRUE(present)) {
    htmltools::tags$td(class = "smr-c smr-yes", "\u2713")
  } else {
    htmltools::tags$td(class = "smr-c smr-no", "\u2717")
  }
}

report_sitemap_table <- function(urls, sources) {
  if (is.null(sources) || nrow(sources) == 0L) {
    return(NULL)
  }

  key_of <- function(i) {
    fu <- sources$final_url[i]
    if (is.na(fu) || !nzchar(fu)) sources$requested_url[i] else fu
  }

  rows <- lapply(seq_len(nrow(sources)), function(i) {
    key <- key_of(i)
    fmt <- as.character(sources$format[i])
    is_index <- identical(fmt, "xml-sitemapindex")
    node_urls <- urls[
      !is.na(urls$source_sitemap) & urls$source_sitemap == key, ,
      drop = FALSE
    ]
    n <- nrow(node_urls)
    ok <- is.na(sources$error_class[i])
    status_txt <- if (!is.na(sources$status[i])) {
      as.character(sources$status[i])
    } else {
      "local"
    }
    size_kb <- if (!is.na(sources$bytes[i])) {
      sprintf("%.1f", sources$bytes[i] / 1024)
    } else {
      "-"
    }
    time_ms <- if (!is.na(sources$timing[i])) {
      as.character(round(sources$timing[i] * 1000))
    } else {
      "-"
    }

    meta_cells <- if (is_index) {
      list(htmltools::tags$td(
        class = "smr-c smr-dim", colspan = "3", "-"
      ))
    } else {
      m <- report_node_meta(node_urls)
      list(
        report_check_cell(m$has_lastmod),
        report_check_cell(m$has_priority),
        report_check_cell(m$has_changefreq)
      )
    }

    htmltools::tags$tr(
      htmltools::tags$td(
        htmltools::tags$span(
          class = paste0("smr-dot ", if (ok) "smr-dot-ok" else "smr-dot-bad")
        ),
        htmltools::tags$span(class = "smr-url", key)
      ),
      htmltools::tags$td(class = "smr-dim", report_format_label(fmt)),
      htmltools::tags$td(class = "smr-num", status_txt),
      htmltools::tags$td(class = "smr-num", if (is_index) "-" else format(
        n,
        big.mark = ","
      )),
      htmltools::tags$td(class = "smr-num", size_kb),
      htmltools::tags$td(class = "smr-num", time_ms),
      meta_cells
    )
  })

  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$h2("Sitemaps"),
    htmltools::tags$div(
      class = "smr-tablewrap",
      htmltools::tags$table(
        class = "smr-table",
        htmltools::tags$thead(htmltools::tags$tr(
          htmltools::tags$th("Source"),
          htmltools::tags$th("Type"),
          htmltools::tags$th(class = "smr-num", "Status"),
          htmltools::tags$th(class = "smr-num", "URLs"),
          htmltools::tags$th(class = "smr-num", "Size (KB)"),
          htmltools::tags$th(class = "smr-num", "Time (ms)"),
          htmltools::tags$th(class = "smr-c", title = "Last modified", "LM"),
          htmltools::tags$th(class = "smr-c", title = "Priority", "Pri"),
          htmltools::tags$th(class = "smr-c", title = "Change frequency", "CF")
        )),
        htmltools::tags$tbody(rows)
      )
    )
  )
}

# ---- section: lastmod --------------------------------------------------------

report_lastmod_section <- function(urls) {
  n_total <- nrow(urls)
  lm <- urls$lastmod
  has <- !is.na(lm)
  n_with <- sum(has)
  coverage <- if (n_total > 0L) round(100 * n_with / n_total) else 0L
  cov_class <- if (coverage >= 80L) {
    "smr-good"
  } else if (coverage >= 50L) {
    "smr-warn"
  } else {
    "smr-bad"
  }

  cards <- htmltools::tags$div(
    class = "smr-cards",
    htmltools::tags$div(
      class = "smr-card",
      htmltools::tags$div(
        class = "smr-card-num", format(n_total, big.mark = ",")
      ),
      htmltools::tags$div(class = "smr-card-lbl", "Total URLs")
    ),
    htmltools::tags$div(
      class = "smr-card",
      htmltools::tags$div(
        class = "smr-card-num", format(n_with, big.mark = ",")
      ),
      htmltools::tags$div(class = "smr-card-lbl", "With lastmod")
    ),
    htmltools::tags$div(
      class = "smr-card",
      htmltools::tags$div(
        class = paste0("smr-card-num ", cov_class),
        paste0(coverage, "%")
      ),
      htmltools::tags$div(class = "smr-card-lbl", "Coverage")
    )
  )

  chart <- NULL
  if (n_with > 0L) {
    months <- format(lm[has], "%Y-%m")
    tab <- sort(table(months))
    tab <- tab[order(names(tab))]
    max_count <- max(as.integer(tab))
    bars <- lapply(seq_along(tab), function(i) {
      count <- as.integer(tab[i])
      pct <- max(1, round(100 * count / max_count))
      htmltools::tags$div(
        class = "smr-bar-row",
        htmltools::tags$span(class = "smr-bar-lbl", names(tab)[i]),
        htmltools::tags$div(
          class = "smr-bar-track",
          htmltools::tags$div(
            class = "smr-bar-fill",
            style = htmltools::css(width = paste0(pct, "%"))
          )
        ),
        htmltools::tags$span(
          class = "smr-bar-count", format(count, big.mark = ",")
        )
      )
    })
    chart <- htmltools::tagList(
      htmltools::tags$h3("Distribution by month"),
      htmltools::tags$div(class = "smr-chart", bars)
    )
  }

  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$h2("lastmod"),
    cards,
    chart
  )
}

# ---- section: URL folder tree ------------------------------------------------

# Build a reference-semantic folder tree (environments) so insertion is O(depth)
# even for large corpora, then render it depth-first to nested <details>.
report_build_tree <- function(locs) {
  new_node <- function() {
    e <- new.env(parent = emptyenv())
    e$count <- 0L
    e$children <- list()
    e
  }
  root <- new_node()
  for (loc in locs) {
    segs <- report_path_segments(loc)
    cur <- root
    cur$count <- cur$count + 1L
    for (s in segs) {
      child <- cur$children[[s]]
      if (is.null(child)) {
        child <- new_node()
        cur$children[[s]] <- child
      }
      child$count <- child$count + 1L
      cur <- child
    }
  }
  root
}

report_render_tree_node <- function(node, depth) {
  names_ <- names(node$children)
  if (length(names_) == 0L) {
    return(NULL)
  }
  counts <- vapply(names_, function(nm) node$children[[nm]]$count, integer(1))
  ord <- order(-counts, names_)
  indent <- htmltools::css(`margin-left` = paste0(depth * 16, "px"))

  lapply(ord, function(k) {
    nm <- names_[k]
    child <- node$children[[nm]]
    label <- paste0("/", nm)
    if (length(child$children) > 0L) {
      htmltools::tags$details(
        class = "smr-tree-node",
        style = indent,
        htmltools::tags$summary(
          htmltools::tags$span(class = "smr-tree-toggle", "[+]"),
          htmltools::tags$span(class = "smr-tree-name", label),
          report_count_badge(child$count)
        ),
        report_render_tree_node(child, depth + 1L)
      )
    } else {
      htmltools::tags$div(
        class = "smr-tree-leaf",
        style = indent,
        htmltools::tags$span(class = "smr-tree-name", label),
        report_count_badge(child$count)
      )
    }
  })
}

report_url_tree <- function(urls) {
  locs <- urls$loc[!is.na(urls$loc)]
  if (length(locs) == 0L) {
    return(NULL)
  }
  capped <- length(locs) > report_tree_cap
  if (capped) {
    locs <- locs[seq_len(report_tree_cap)]
  }
  tree <- report_build_tree(locs)
  if (length(tree$children) == 0L) {
    return(NULL)
  }
  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$h2("URL structure"),
    if (capped) {
      htmltools::tags$p(class = "smr-note", sprintf(
        "Tree built from the first %s of %s URLs.",
        format(report_tree_cap, big.mark = ","),
        format(length(urls$loc), big.mark = ",")
      ))
    },
    htmltools::tags$div(
      class = "smr-tree",
      report_render_tree_node(tree, 0L)
    )
  )
}

# ---- section: severity dashboard ---------------------------------------------

report_severity_dashboard <- function(findings) {
  counts <- vapply(
    report_severity_levels,
    function(s) sum(findings$severity == s),
    integer(1)
  )
  tiles <- lapply(report_severity_levels, function(s) {
    htmltools::tags$div(
      class = paste0("smr-sev smr-sev-", s),
      htmltools::tags$div(
        class = "smr-sev-num", format(counts[[s]], big.mark = ",")
      ),
      htmltools::tags$div(class = "smr-sev-lbl", s)
    )
  })
  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$h2("Severity"),
    htmltools::tags$div(class = "smr-sevgrid", tiles)
  )
}

# ---- section: findings -------------------------------------------------------

report_evidence_block <- function(ev) {
  if (is.null(ev) || is.null(ev$excerpt) || is.na(ev$excerpt)) {
    return(NULL)
  }
  loc <- ""
  if (!is.null(ev$line) && !is.na(ev$line)) {
    loc <- paste0(
      " (line ", ev$line,
      if (!is.null(ev$column) && !is.na(ev$column)) {
        paste0(", col ", ev$column)
      } else {
        ""
      },
      ")"
    )
  }
  htmltools::tags$div(
    class = "smr-evidence",
    htmltools::tags$code(ev$excerpt),
    if (nzchar(loc)) htmltools::tags$span(class = "smr-dim", loc)
  )
}

report_findings_section <- function(findings) {
  if (nrow(findings) == 0L) {
    return(htmltools::tags$section(
      class = "smr-section",
      htmltools::tags$h2("Findings"),
      htmltools::tags$p(class = "smr-ok-note", "No issues found.")
    ))
  }

  sev_rank <- stats::setNames(
    seq_along(report_severity_levels),
    report_severity_levels
  )
  present_layers <- report_layer_order[report_layer_order %in% findings$layer]

  layer_blocks <- lapply(present_layers, function(layer) {
    sub <- findings[findings$layer == layer, , drop = FALSE]
    codes <- unique(sub$code)
    # keep first sample per code, count total, order by severity then count.
    samples <- lapply(codes, function(cd) {
      rows <- sub[sub$code == cd, , drop = FALSE]
      list(row = rows[1, , drop = FALSE], count = nrow(rows))
    })
    ord <- order(
      vapply(samples, function(s) sev_rank[[s$row$severity]], integer(1)),
      -vapply(samples, function(s) s$count, integer(1))
    )
    samples <- samples[ord]

    body_rows <- lapply(samples, function(s) {
      r <- s$row
      sev <- r$severity
      ev <- if (length(r$evidence) > 0L) r$evidence[[1]] else NULL
      htmltools::tags$tr(
        htmltools::tags$td(
          class = paste0("smr-sevtext smr-sevtext-", sev), sev
        ),
        htmltools::tags$td(
          htmltools::tags$span(
            class = paste0("smr-code smr-code-", sev), r$code
          ),
          htmltools::tags$div(class = "smr-dim smr-small", paste0(
            format(s$count, big.mark = ","), " total"
          ))
        ),
        htmltools::tags$td(
          class = "smr-subject",
          htmltools::tags$span(class = "smr-dim smr-small", r$subject_type),
          if (!is.na(r$subject_ref)) htmltools::tags$div(r$subject_ref)
        ),
        htmltools::tags$td(
          r$message,
          report_evidence_block(ev)
        )
      )
    })

    htmltools::tags$div(
      class = "smr-layer",
      htmltools::tags$h3(sprintf(
        "%s (%d issue%s, %d total)",
        layer, length(codes), if (length(codes) != 1L) "s" else "", nrow(sub)
      )),
      htmltools::tags$div(
        class = "smr-tablewrap",
        htmltools::tags$table(
          class = "smr-table",
          htmltools::tags$thead(htmltools::tags$tr(
            htmltools::tags$th("Severity"),
            htmltools::tags$th("Code"),
            htmltools::tags$th("Example subject"),
            htmltools::tags$th("Example message")
          )),
          htmltools::tags$tbody(body_rows)
        )
      )
    )
  })

  n_unique <- length(unique(findings$code))
  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$h2(sprintf(
      "Findings (%d issue%s, %d total)",
      n_unique, if (n_unique != 1L) "s" else "", nrow(findings)
    )),
    layer_blocks
  )
}

# ---- section: URL table ------------------------------------------------------

report_url_table <- function(urls) {
  n_total <- nrow(urls)
  if (n_total == 0L) {
    return(NULL)
  }
  capped <- n_total > report_url_table_cap
  show <- if (capped) {
    urls[seq_len(report_url_table_cap), , drop = FALSE]
  } else {
    urls
  }

  fmt_cell <- function(v) if (is.na(v)) "-" else as.character(v)
  fmt_lm <- function(v) if (is.na(v)) "-" else format(v, "%Y-%m-%d")

  body_rows <- lapply(seq_len(nrow(show)), function(i) {
    htmltools::tags$tr(
      class = "smr-urlrow",
      htmltools::tags$td(htmltools::tags$a(
        href = show$loc[i],
        target = "_blank",
        rel = "noopener noreferrer",
        class = "smr-url",
        show$loc[i]
      )),
      htmltools::tags$td(class = "smr-dim smr-small", fmt_lm(show$lastmod[i])),
      htmltools::tags$td(
        class = "smr-dim smr-small", fmt_cell(show$changefreq[i])
      ),
      htmltools::tags$td(
        class = "smr-dim smr-small", fmt_cell(show$priority[i])
      )
    )
  })

  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$div(
      class = "smr-urltable-head",
      htmltools::tags$h2("URL analysis"),
      report_count_badge(n_total),
      htmltools::tags$div(
        class = "smr-urltable-tools",
        htmltools::tags$input(
          id = "smr-url-search",
          type = "text",
          placeholder = "Search URLs..."
        ),
        htmltools::tags$button(
          id = "smr-csv-btn", type = "button", class = "smr-btn", "CSV"
        )
      )
    ),
    if (capped) {
      htmltools::tags$p(class = "smr-note", sprintf(
        "Showing the first %s of %s URLs.",
        format(report_url_table_cap, big.mark = ","),
        format(n_total, big.mark = ",")
      ))
    },
    htmltools::tags$div(
      class = "smr-tablewrap smr-urltable-scroll",
      htmltools::tags$table(
        id = "smr-url-table",
        class = "smr-table",
        htmltools::tags$thead(htmltools::tags$tr(
          htmltools::tags$th(class = "smr-sortable", `data-col` = "0", "URL"),
          htmltools::tags$th(
            class = "smr-sortable", `data-col` = "1", "Modified"
          ),
          htmltools::tags$th(class = "smr-sortable", `data-col` = "2", "Freq"),
          htmltools::tags$th(
            class = "smr-sortable", `data-col` = "3", "Priority"
          )
        )),
        htmltools::tags$tbody(id = "smr-url-tbody", body_rows)
      )
    )
  )
}

# ---- inline CSS + JS ---------------------------------------------------------

report_styles <- function() {
  htmltools::tags$style(htmltools::HTML(
    "
:root{
  --bg:#ffffff;--fg:#1f2937;--muted:#6b7280;--card:#f8f9fa;--border:#e5e7eb;
  --link:#2563eb;--accent:#2563eb;--accent2:#1d4ed8;--badge:#f3f4f6;
  --head:#f8f9fa;--code:#f3f4f6;--track:#e5e7eb;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme=\"light\"]){
    --bg:#0b1220;--fg:#e5e7eb;--muted:#9ca3af;--card:#111827;--border:#243043;
    --link:#60a5fa;--accent:#3b82f6;--accent2:#60a5fa;--badge:#1f2937;
    --head:#111827;--code:#0f172a;--track:#243043;
  }
}
:root[data-theme=\"dark\"]{
  --bg:#0b1220;--fg:#e5e7eb;--muted:#9ca3af;--card:#111827;--border:#243043;
  --link:#60a5fa;--accent:#3b82f6;--accent2:#60a5fa;--badge:#1f2937;
  --head:#111827;--code:#0f172a;--track:#243043;
}
*{box-sizing:border-box;}
body{margin:0;background:var(--bg);color:var(--fg);
  font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,
  'Helvetica Neue',Arial,sans-serif;
  line-height:1.5;}
.smr-main{max-width:1000px;margin:0 auto;padding:2rem 1rem;}
h2{border-bottom:2px solid var(--border);padding-bottom:.4rem;font-size:1.3rem;}
h3{font-size:1rem;margin:1rem 0 .5rem;}
.smr-section{margin-bottom:2.25rem;}
.smr-note{color:var(--muted);font-size:.85rem;margin:.25rem 0 .5rem;}
.smr-dim{color:var(--muted);}
.smr-small{font-size:.8rem;}
.smr-num{text-align:right;white-space:nowrap;}
.smr-url{font-family:monospace;font-size:.8rem;word-break:break-all;
  color:var(--link);}
a.smr-url{text-decoration:none;}
a.smr-url:hover{text-decoration:underline;}
.smr-badge{display:inline-block;background:var(--badge);color:var(--muted);
  border-radius:999px;padding:1px 8px;font-size:.72rem;margin-left:6px;}
/* hero */
.smr-hero{background:linear-gradient(135deg,var(--accent),var(--accent2));
  color:#fff;border-radius:12px;padding:1.5rem 2rem;margin-bottom:2rem;}
.smr-hero-row{display:flex;justify-content:space-between;align-items:flex-start;
  gap:1rem;flex-wrap:wrap;}
.smr-hero-title{margin:0 0 .25rem;font-size:1.5rem;}
.smr-hero-source{margin:0 0 .75rem;word-break:break-all;font-size:.9rem;
  opacity:.95;}
.smr-hero-stats{display:flex;gap:1.25rem;flex-wrap:wrap;font-size:.9rem;
  align-items:center;}
.smr-hero-mode{opacity:.85;text-transform:capitalize;}
.smr-theme-toggle{background:rgba(255,255,255,.15);color:#fff;
  border:1px solid rgba(255,255,255,.35);border-radius:8px;padding:8px 14px;
  font-size:.8rem;cursor:pointer;white-space:nowrap;}
/* tables */
.smr-tablewrap{overflow-x:auto;border:1px solid var(--border);
  border-radius:8px;}
.smr-table{border-collapse:collapse;width:100%;font-size:.85rem;}
.smr-table thead tr{background:var(--head);
  border-bottom:2px solid var(--border);}
.smr-table th{text-align:left;padding:8px;font-weight:600;color:var(--muted);}
.smr-table td{padding:6px 8px;border-bottom:1px solid var(--border);
  vertical-align:top;}
.smr-c{text-align:center;}
.smr-yes{color:#16a34a;}
.smr-no{color:var(--muted);opacity:.6;}
.smr-dot{display:inline-block;width:8px;height:8px;border-radius:50%;
  margin-right:6px;}
.smr-dot-ok{background:#16a34a;}
.smr-dot-bad{background:#dc2626;}
.smr-subject{word-break:break-all;}
/* cards */
.smr-cards{display:flex;gap:.75rem;flex-wrap:wrap;margin:1rem 0 1.25rem;}
.smr-card{flex:1;min-width:120px;padding:.75rem 1rem;background:var(--card);
  border:1px solid var(--border);border-radius:8px;text-align:center;}
.smr-card-num{font-size:1.5rem;font-weight:700;line-height:1.2;}
.smr-card-lbl{font-size:.75rem;color:var(--muted);margin-top:.2rem;}
.smr-good{color:#16a34a;}.smr-warn{color:#d97706;}.smr-bad{color:#dc2626;}
/* histogram */
.smr-chart{max-height:400px;overflow-y:auto;}
.smr-bar-row{display:flex;align-items:center;gap:8px;margin:2px 0;}
.smr-bar-lbl{width:60px;text-align:right;font-size:.72rem;color:var(--muted);
  font-family:monospace;flex-shrink:0;}
.smr-bar-track{flex:1;background:var(--track);border-radius:3px;height:18px;
  overflow:hidden;}
.smr-bar-fill{background:var(--accent);height:100%;border-radius:3px;}
.smr-bar-count{width:56px;font-size:.72rem;color:var(--muted);
  font-family:monospace;}
/* tree */
.smr-tree{max-height:400px;overflow-y:auto;border:1px solid var(--border);
  border-radius:8px;padding:.75rem;}
.smr-tree-node>summary{cursor:pointer;padding:3px 0;font-size:.85rem;
  font-family:monospace;list-style:none;display:flex;align-items:center;}
.smr-tree-node>summary::-webkit-details-marker{display:none;}
.smr-tree-leaf{padding:3px 0 3px 16px;font-size:.85rem;font-family:monospace;
  color:var(--muted);display:flex;align-items:center;}
.smr-tree-toggle{display:inline-block;width:16px;font-size:.7rem;
  color:var(--muted);flex-shrink:0;}
.smr-tree-name{color:var(--fg);}
/* severity dashboard */
.smr-sevgrid{display:flex;gap:.75rem;flex-wrap:wrap;}
.smr-sev{flex:1;min-width:110px;padding:.75rem 1rem;border-radius:8px;
  text-align:center;
  border:1px solid var(--border);background:var(--card);}
.smr-sev-num{font-size:1.6rem;font-weight:700;line-height:1.1;}
.smr-sev-lbl{font-size:.78rem;text-transform:capitalize;margin-top:.15rem;
  color:var(--muted);}
.smr-sev-fatal .smr-sev-num{color:#b91c1c;}
.smr-sev-error .smr-sev-num{color:#dc2626;}
.smr-sev-warning .smr-sev-num{color:#d97706;}
.smr-sev-info .smr-sev-num{color:#6b7280;}
/* findings */
.smr-layer{margin-bottom:1.5rem;}
.smr-layer h3{text-transform:capitalize;}
.smr-sevtext{font-weight:600;}
.smr-sevtext-fatal{color:#b91c1c;}.smr-sevtext-error{color:#dc2626;}
.smr-sevtext-warning{color:#d97706;}.smr-sevtext-info{color:#6b7280;}
.smr-code{font-family:monospace;font-size:.85rem;}
.smr-code-fatal{color:#b91c1c;}.smr-code-error{color:#dc2626;}
.smr-code-warning{color:#d97706;}.smr-code-info{color:#6b7280;}
.smr-evidence{margin-top:4px;padding:4px 8px;background:var(--code);
  border-radius:3px;
  font-family:monospace;font-size:.8rem;white-space:pre-wrap;
  word-break:break-all;}
.smr-ok-note{display:inline-block;padding:4px 12px;
  background:rgba(22,163,74,.12);
  color:#16a34a;border-radius:4px;font-weight:600;}
/* url table */
.smr-urltable-head{display:flex;align-items:center;gap:12px;flex-wrap:wrap;
  margin-bottom:.75rem;}
.smr-urltable-head h2{margin:0;border:none;padding:0;}
.smr-urltable-tools{margin-left:auto;display:flex;gap:8px;align-items:center;}
.smr-urltable-tools input{padding:6px 12px;border:1px solid var(--border);
  border-radius:6px;font-size:.85rem;width:200px;background:var(--bg);
  color:var(--fg);}
.smr-btn{padding:6px 14px;background:var(--accent2);color:#fff;border:none;
  border-radius:6px;font-size:.85rem;cursor:pointer;}
.smr-sortable{cursor:pointer;user-select:none;}
.smr-urltable-scroll{max-height:600px;overflow-y:auto;}
.smr-urltable-scroll thead{position:sticky;top:0;background:var(--head);}
.smr-footer{margin-top:2rem;padding-top:1rem;border-top:1px solid var(--border);
  color:var(--muted);font-size:.82rem;}
"
  ))
}

report_scripts <- function() {
  htmltools::tags$script(htmltools::HTML(
    "
(function(){
  // theme toggle: stamp data-theme on the root; wins over the media query.
  var root=document.documentElement;
  var toggle=document.getElementById('smr-theme-toggle');
  if(toggle){
    toggle.addEventListener('click',function(){
      var cur=root.getAttribute('data-theme');
      var dark=cur?cur==='dark':
        window.matchMedia('(prefers-color-scheme: dark)').matches;
      root.setAttribute('data-theme',dark?'light':'dark');
    });
  }
  // folder-tree expand/collapse indicator.
  document.querySelectorAll('.smr-tree-node').forEach(function(d){
    d.addEventListener('toggle',function(){
      var t=d.querySelector(':scope > summary > .smr-tree-toggle');
      if(t){t.textContent=d.open?'[-]':'[+]';}
    });
  });
  // url table: search, sort, csv export (all DOM-driven, no external data).
  var tbody=document.getElementById('smr-url-tbody');
  if(tbody){
    var search=document.getElementById('smr-url-search');
    if(search){
      search.addEventListener('input',function(){
        var q=this.value.toLowerCase();
        tbody.querySelectorAll('tr.smr-urlrow').forEach(function(r){
          r.style.display=r.textContent.toLowerCase().indexOf(q)!==-1?'':'none';
        });
      });
    }
    var sortCol=-1,sortAsc=true;
    document.querySelectorAll('.smr-sortable').forEach(function(th){
      th.addEventListener('click',function(){
        var col=parseInt(this.getAttribute('data-col'),10);
        if(sortCol===col){sortAsc=!sortAsc;}else{sortCol=col;sortAsc=true;}
        var rows=Array.prototype.slice.call(
          tbody.querySelectorAll('tr.smr-urlrow'));
        rows.sort(function(a,b){
          var at=(a.children[col].textContent||'');
          var bt=(b.children[col].textContent||'');
          return sortAsc?at.localeCompare(bt):bt.localeCompare(at);
        });
        rows.forEach(function(r){tbody.appendChild(r);});
        document.querySelectorAll('.smr-sortable').forEach(function(h){
          h.textContent=h.textContent.replace(/ [\\u2191\\u2193]$/,'');
        });
        this.textContent+=sortAsc?' \\u2191':' \\u2193';
      });
    });
    var csvBtn=document.getElementById('smr-csv-btn');
    if(csvBtn){
      csvBtn.addEventListener('click',function(){
        var out=['URL,Modified,Freq,Priority'];
        tbody.querySelectorAll('tr.smr-urlrow').forEach(function(r){
          var cells=Array.prototype.map.call(r.children,function(c){
            return '\"'+(c.textContent||'').replace(/\"/g,'\"\"')+'\"';
          });
          out.push(cells.join(','));
        });
        var blob=new Blob([out.join('\\n')],{type:'text/csv'});
        var a=document.createElement('a');
        a.href=URL.createObjectURL(blob);
        a.download='sitemap-urls.csv';
        a.click();
      });
    }
  }
})();
"
  ))
}

# ---- assembly ----------------------------------------------------------------

# Render the full self-contained HTML document string from the already-computed
# `urls` tibble (with its `sources` attribute) and `findings` contract tibble.
report_render_html <- function(source_label, urls, findings, mode, title) {
  sources <- attr(urls, "sources")

  body <- htmltools::tags$main(
    class = "smr-main",
    report_hero(source_label, urls, sources, findings, mode),
    report_sitemap_table(urls, sources),
    report_lastmod_section(urls),
    report_url_tree(urls),
    report_severity_dashboard(findings),
    report_findings_section(findings),
    report_url_table(urls),
    htmltools::tags$footer(
      class = "smr-footer",
      "Generated by sitemapr report_sitemap()."
    ),
    report_scripts()
  )

  page <- htmltools::tags$html(
    lang = "en",
    htmltools::tags$head(
      htmltools::tags$meta(charset = "utf-8"),
      htmltools::tags$meta(
        name = "viewport",
        content = "width=device-width, initial-scale=1"
      ),
      htmltools::tags$meta(name = "robots", content = "noindex"),
      htmltools::tags$title(title),
      report_styles()
    ),
    body
  )

  # NB: as.character() on an <html> tag drops <head> (a Shiny-UI convenience);
  # doRenderTags() renders the full document including <head>.
  paste0("<!DOCTYPE html>\n", htmltools::doRenderTags(page))
}

#' Render a self-contained HTML report for a sitemap
#'
#' Produces a single, fully self-contained HTML report for a sitemap source,
#' modeled on the sitemap-validator reference renderer. Unlike [read_sitemap()]
#' (which returns a tidy tibble) and [validate_sitemap()] (which returns the
#' findings contract), `report_sitemap()` is the human-readable surface: it
#' *consumes* those existing outputs and renders them, and never re-implements
#' any parsing or validation itself.
#'
#' The report contains a hero banner (source, overall status, URL/index/sitemap
#' counts), a per-source sitemap table (format, HTTP status, URL count, and
#' `lastmod`/`priority`/`changefreq` presence), `lastmod` coverage cards with a
#' by-month histogram, a collapsible URL folder tree grouped by path segment, a
#' severity dashboard, the findings grouped by validation layer (deduplicated by
#' code, with evidence excerpts), and a searchable, sortable, CSV-exportable URL
#' table.
#'
#' The output is entirely self-contained: all CSS, JavaScript (search, sort,
#' CSV export, tree toggle, and a light/dark theme toggle), and data are
#' inlined, so the file references no external hosts and works offline. The
#' palette follows the viewer's `prefers-color-scheme` by default; the in-page
#' toggle stamps a `data-theme` attribute on the root element that wins in both
#' directions.
#'
#' By default the source `x` is both read (via [read_sitemap()], for the URL
#' rows and per-source metadata) and validated (via [validate_sitemap()], for
#' the findings). To avoid re-fetching a URL source, or to render results you
#' have already computed, pass them via `urls` and/or `findings`; in that case
#' `x` is used only as the report's source label.
#'
#' @param x A single source: a sitemap URL (character) or a path to a
#'   local sitemap file. When both `urls` and `findings` are supplied, `x` is
#'   used only as the displayed source label.
#' @param output Optional path to write the HTML file to. When supplied, the
#'   report is written there (UTF-8) and the path is returned invisibly;
#'   otherwise the HTML is returned as an [htmltools::HTML] string.
#' @param mode `"strict"` (the default) or `"non-strict"`, passed to
#'   [validate_sitemap()] when `findings` is not supplied.
#' @param urls Optional precomputed [read_sitemap()] result (a tibble with the
#'   `sources` attribute). When `NULL` (the default) it is computed from `x`.
#' @param findings Optional precomputed [validate_sitemap()] findings tibble.
#'   When `NULL` (the default) it is computed from `x`.
#' @param title The HTML document `<title>`. Defaults to a title derived from
#'   `x`.
#' @param user_agent The User-Agent header for HTTP fetches. Defaults to the
#'   package User-Agent.
#' @param limits Network limits for HTTP fetches, as from `fetch_limits()`.
#' @param index_limits Sitemapindex-expansion bounds, as from `index_limits()`.
#'   Defaults to `index_limits()`.
#' @return If `output` is supplied, the output path, invisibly. Otherwise, the
#'   report HTML as an [htmltools::HTML] character string.
#' @seealso [read_sitemap()] and [validate_sitemap()] for the underlying data.
#' @export
#' @examples
#' # Render a report for a local sitemap file to a temporary HTML file.
#' xml <- paste0(
#'   '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
#'   '<url><loc>https://example.com/</loc>',
#'   '<lastmod>2024-01-01</lastmod></url>',
#'   '<url><loc>https://example.com/about</loc></url>',
#'   '</urlset>'
#' )
#' path <- tempfile(fileext = ".xml")
#' writeLines(xml, path)
#' out <- tempfile(fileext = ".html")
#' report_sitemap(path, output = out)
#'
#' \dontrun{
#' # Render directly from a sitemap URL (fetches twice: read + validate).
#' report_sitemap("https://example.com/sitemap.xml", output = "report.html")
#'
#' # Reuse results you have already computed to avoid re-fetching.
#' u <- read_sitemap("https://example.com/sitemap.xml")
#' f <- validate_sitemap("https://example.com/sitemap.xml")
#' report_sitemap("example.com", urls = u, findings = f, output = "report.html")
#' }
report_sitemap <- function(
  x,
  output = NULL,
  mode = c("strict", "non-strict"),
  urls = NULL,
  findings = NULL,
  title = NULL,
  user_agent = default_user_agent(),
  limits = fetch_limits(),
  index_limits = NULL
) {
  mode <- match.arg(mode)
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    rlang::abort(
      "`x` must be a single non-empty source: a URL or a local file path.",
      class = "sitemapr_bad_input"
    )
  }
  if (is.null(index_limits)) {
    index_limits <- index_limits()
  }

  if (is.null(urls)) {
    urls <- read_sitemap(
      x,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits
    )
  }
  if (is.null(findings)) {
    findings <- validate_sitemap(
      x,
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits
    )
  }
  if (is.null(title)) {
    title <- paste0("Sitemap report \u2014 ", x)
  }

  html <- report_render_html(
    source_label = x,
    urls = urls,
    findings = findings,
    mode = mode,
    title = title
  )

  if (!is.null(output)) {
    writeBin(charToRaw(enc2utf8(html)), output)
    return(invisible(output))
  }
  htmltools::HTML(html)
}
