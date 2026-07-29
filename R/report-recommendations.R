# Report section: recommendations (SITE-babrgssv).
#
# Prescriptive guidance, as distinct from the findings section's diagnostics: a
# finding says what is wrong with the document, a recommendation says what to do
# next and cites the source that says so. Every input is already computed for
# some other section (lastmod coverage, per-source byte size and format,
# per-source URL counts, the advisory-field columns), so nothing here re-parses
# or re-fetches anything.
#
# CITATION DISCIPLINE. Each recommendation names its source and carries exactly
# ONE provenance tag (ADR-009 §0, sitemap-spec.md §12.0) for the fact it rests
# on: `documented` (quoted from an engine's CURRENT primary source),
# `inherited_protocol` (a sitemaps.org baseline bound). Where sitemapr picked
# the TRIGGER POINT — the 50% staleness share, the 80%-of-a-bound
# "approaching" band — that choice is stated in the recommendation's own prose,
# never smuggled in as a second competing tag (§12.0 atomicity).
#
# Two of the sibling port's thresholds are deliberately NOT reproduced as it
# states them, because §12.6 classifies them otherwise:
#   * 1,000 child sitemaps per index is not a current bound in any source — the
#     documented figure is 50,000 for baseline, Google, Bing and Yandex alike.
#   * 500 sitemap-index files is a Google Search Console SUBMISSION/property
#     cap, not a file-format rule, and is rendered here scoped as one.
# Bing's 2008 10 MB and 2009 XML-only statements are historical (§12.6) and the
# anonymous sitemap ping is deprecated (§12.4); neither is cited.

# Document-format bounds the recommendations measure against.
report_rec_url_limit <- 50000L
# 50 MB verbatim from sitemaps.org: 52,428,800 bytes (binary MiB), NOT the round
# 50,000,000 — the same figure R/protocol-validate.R enforces.
report_rec_size_limit <- 52428800
report_rec_index_child_limit <- 50000L
# Google Search Console's cap on sitemap-index FILES per property (submission
# scope, not file conformance).
report_rec_index_files_limit <- 500L

# sitemapr's own trigger points (stated in the rendered prose, never as
# provenance): flag a bound at 80% of it, and call a lastmod corpus stale when
# more than half of the dated URLs are over a year old.
report_rec_near_fraction <- 0.8
report_rec_stale_fraction <- 0.5
report_rec_stale_days <- 365

# The cited sources, keyed for reuse. Each is the CURRENT primary document for
# the fact it backs (docs/references.md); the URLs are content links, and the
# report inlines every asset, so nothing here is loaded at render time.
report_rec_source <- function(key) {
  switch(
    key,
    sitemaps_org = list(
      label = "sitemaps.org \u2014 protocol",
      url = "https://www.sitemaps.org/protocol.html"
    ),
    google_build = list(
      label = "Google \u2014 Build and submit a sitemap",
      url = paste0(
        "https://developers.google.com/search/docs/crawling-indexing/",
        "sitemaps/build-sitemap"
      )
    ),
    google_large = list(
      label = "Google \u2014 Large sitemaps and sitemap indexes",
      url = paste0(
        "https://developers.google.com/search/docs/crawling-indexing/",
        "sitemaps/large-sitemaps"
      )
    ),
    bing_lastmod = list(
      label = "Bing \u2014 The importance of the lastmod tag (Feb 2023)",
      url = paste0(
        "https://blogs.bing.com/webmaster/february-2023/",
        "The-Importance-of-Setting-the-lastmod-Tag-in-Your-Sitemap"
      )
    ),
    bing_2025 = list(
      label = "Bing \u2014 Sitemaps in AI-powered search (Jul 2025)",
      url = paste0(
        "https://blogs.bing.com/webmaster/July-2025/",
        "Keeping-Content-Discoverable-with-Sitemaps-in-AI-Powered-Search"
      )
    )
  )
}

# One recommendation: a title, the prescriptive detail, its single provenance
# tag, and the source keys backing it.
report_rec <- function(title, detail, provenance, sources) {
  list(
    title = title,
    detail = detail,
    provenance = provenance,
    sources = sources
  )
}

# No `lastmod` anywhere. The strongest freshness signal a sitemap can carry is
# simply absent, which no finding covers (an absent optional element is legal).
report_rec_lastmod_absent <- function(urls) {
  n_total <- nrow(urls)
  if (n_total == 0L || !all(is.na(urls$lastmod))) {
    return(NULL)
  }
  report_rec(
    "Add <lastmod> to your URLs",
    sprintf(
      paste(
        "None of the %s URLs carries a <lastmod>. Google uses it when it is",
        "consistently accurate, and Bing treats it as a key recrawl signal,",
        "so leaving it out discards the strongest freshness hint a sitemap",
        "has. Emit the real last-modification time, with a time component,",
        "in ISO 8601."
      ),
      format(n_total, big.mark = ",")
    ),
    "documented",
    c("google_build", "bing_2025")
  )
}

# A majority-stale `lastmod` corpus. Distinct from the PROTOCOL_LASTMOD_*
# heuristics, which look for dishonest dates (all identical, or equal to
# generation time); this looks at whether the dates are being MAINTAINED.
report_rec_lastmod_stale <- function(urls, now = Sys.time()) {
  dated <- urls$lastmod[!is.na(urls$lastmod)]
  if (length(dated) == 0L) {
    return(NULL)
  }
  age_days <- as.numeric(difftime(now, dated, units = "days"))
  n_stale <- sum(age_days > report_rec_stale_days)
  share <- n_stale / length(dated)
  if (share <= report_rec_stale_fraction) {
    return(NULL)
  }
  report_rec(
    "Most dated URLs have not been touched in over a year",
    sprintf(
      paste(
        "%s of %s dated URLs (%.0f%%) carry a <lastmod> older than %s days;",
        "sitemapr flags a corpus once more than half of them are. If the",
        "content really is that old, nothing is wrong. If it is not, the",
        "dates are stale rather than accurate \u2014 and Bing disregards",
        "<lastmod> entirely once it judges a sitemap's dates dishonest."
      ),
      format(n_stale, big.mark = ","),
      format(length(dated), big.mark = ","),
      100 * share,
      format(report_rec_stale_days, big.mark = ",")
    ),
    "documented",
    "bing_lastmod"
  )
}

# `priority` / `changefreq` present. Both are advisory, and the two largest
# engines document that they ignore them, so the maintenance cost buys nothing —
# but the fields are legal, so this can only ever be advice, never a finding.
report_rec_advisory_fields <- function(urls) {
  n_priority <- sum(!is.na(urls$priority))
  n_changefreq <- sum(!is.na(urls$changefreq))
  if (n_priority + n_changefreq == 0L) {
    return(NULL)
  }
  report_rec(
    "Consider dropping <priority> and <changefreq>",
    sprintf(
      paste(
        "%s URLs carry <priority> and %s carry <changefreq>. Google and Bing",
        "both state they ignore these fields, so keeping them accurate costs",
        "effort and bytes without affecting crawling. Yandex documents",
        "<priority> as affecting crawl load order, so keep them if Yandex is",
        "a target; otherwise they can go."
      ),
      format(n_priority, big.mark = ","),
      format(n_changefreq, big.mark = ",")
    ),
    "documented",
    c("google_build", "bing_2025")
  )
}

# The worst per-source count against the 50,000-URL bound. Exceeding it is
# already PROTOCOL_URL_COUNT_EXCEEDED; this covers the approach, which no
# finding reports and which is where splitting is still cheap.
report_rec_url_count <- function(urls, sources) {
  if (is.null(sources) || nrow(sources) == 0L) {
    return(NULL)
  }
  counts <- vapply(
    seq_len(nrow(sources)),
    function(i) {
      key <- report_source_key(sources, i)
      sum(!is.na(urls$source_sitemap) & urls$source_sitemap == key)
    },
    integer(1)
  )
  worst <- max(counts)
  if (worst < report_rec_near_fraction * report_rec_url_limit) {
    return(NULL)
  }
  report_rec(
    "A sitemap is at or near the 50,000-URL limit",
    sprintf(
      paste(
        "%s lists %s URLs \u2014 %.0f%% of the 50,000-URL limit a single",
        "sitemap may carry (sitemapr flags from 80%% of the bound). Split it",
        "into several sitemaps behind a sitemap index; an index may itself",
        "reference up to 50,000 children."
      ),
      report_source_key(sources, which.max(counts)),
      format(worst, big.mark = ","),
      100 * worst / report_rec_url_limit
    ),
    "inherited_protocol",
    "sitemaps_org"
  )
}

# The worst source size against the 50 MB uncompressed bound. Only a source
# whose recorded bytes ARE the uncompressed document counts: for a gzip or tar
# payload the record holds the compressed transfer size, which the bound does
# not apply to.
report_rec_size <- function(sources) {
  if (is.null(sources) || nrow(sources) == 0L) {
    return(NULL)
  }
  measurable <- !(as.character(sources$format) %in% c("gzip", "tar"))
  bytes <- sources$bytes
  bytes[is.na(bytes) | !measurable] <- 0L
  worst <- max(bytes)
  if (worst < report_rec_near_fraction * report_rec_size_limit) {
    return(NULL)
  }
  report_rec(
    "A sitemap is at or near the 50 MB uncompressed limit",
    sprintf(
      paste(
        "%s is %.1f MB uncompressed \u2014 %.0f%% of the 50 MB",
        "(52,428,800-byte) limit for a single sitemap (sitemapr flags from",
        "80%% of the bound). Split it, and serve it gzip-compressed: the",
        "limit applies to the uncompressed document either way."
      ),
      report_source_key(sources, which.max(bytes)),
      worst / 1024^2,
      100 * worst / report_rec_size_limit
    ),
    "inherited_protocol",
    "sitemaps_org"
  )
}

# Child sitemaps against the 50,000-per-index bound. NOTE the figure: the
# sibling port's 1,000 has no current source behind it (§12.6).
report_rec_index_children <- function(sources) {
  if (is.null(sources) || nrow(sources) == 0L) {
    return(NULL)
  }
  fmt <- as.character(sources$format)
  n_children <- sum(fmt != "xml-sitemapindex")
  if (
    !any(fmt == "xml-sitemapindex") ||
      n_children < report_rec_near_fraction * report_rec_index_child_limit
  ) {
    return(NULL)
  }
  report_rec(
    "This index is at or near the 50,000-child limit",
    sprintf(
      paste(
        "The run expanded %s child sitemaps \u2014 %.0f%% of the 50,000",
        "children a sitemap index may reference (sitemapr flags from 80%% of",
        "the bound). Split the index into several, each referenced from a",
        "parent index."
      ),
      format(n_children, big.mark = ","),
      100 * n_children / report_rec_index_child_limit
    ),
    "inherited_protocol",
    "sitemaps_org"
  )
}

# Search Console's cap on index FILES per property. Submission scope: it does
# not make a document invalid, so it is rendered only when the run itself is
# past it, and its title says whose cap it is.
report_rec_index_files <- function(sources) {
  if (is.null(sources) || nrow(sources) == 0L) {
    return(NULL)
  }
  n_index <- sum(as.character(sources$format) == "xml-sitemapindex")
  if (n_index <= report_rec_index_files_limit) {
    return(NULL)
  }
  report_rec(
    "More index files than Search Console accepts per property",
    sprintf(
      paste(
        "This run covers %s sitemap-index files. Google Search Console",
        "accepts at most %s per property \u2014 an operational submission",
        "cap, not a format rule, so the documents stay valid; consolidate",
        "them behind fewer indexes before submitting."
      ),
      format(n_index, big.mark = ","),
      format(report_rec_index_files_limit, big.mark = ",")
    ),
    "documented",
    "google_large"
  )
}

# Every recommendation this run triggers, in a fixed order (freshness first,
# then advisory fields, then the size/count bounds).
report_recommendations <- function(urls, sources) {
  recs <- list(
    report_rec_lastmod_absent(urls),
    report_rec_lastmod_stale(urls),
    report_rec_advisory_fields(urls),
    report_rec_url_count(urls, sources),
    report_rec_size(sources),
    report_rec_index_children(sources),
    report_rec_index_files(sources)
  )
  recs[!vapply(recs, is.null, logical(1))]
}

# The provenance tag on a recommendation. It reuses the findings section's
# executable/diagnostic split so one vocabulary reads the same way everywhere,
# but never claims a recommendation is a verdict: the tag says how well sourced
# the advice is, and the title attribute spells that out.
report_rec_badge <- function(provenance) {
  htmltools::tags$span(
    class = "smr-badge smr-prov smr-prov-exec",
    title = "The engine or protocol source backing this recommendation.",
    provenance
  )
}

report_rec_sources_block <- function(keys) {
  links <- lapply(keys, function(key) {
    src <- report_rec_source(key)
    htmltools::tags$a(
      href = src$url,
      target = "_blank",
      rel = "noopener noreferrer",
      src$label
    )
  })
  htmltools::tags$div(
    class = "smr-rec-src smr-dim smr-small",
    "Source: ",
    links
  )
}

report_rec_block <- function(rec) {
  htmltools::tags$div(
    class = "smr-rec",
    htmltools::tags$div(
      class = "smr-rec-head",
      htmltools::tags$span(class = "smr-rec-title", rec$title),
      report_rec_badge(rec$provenance)
    ),
    htmltools::tags$p(class = "smr-rec-detail", rec$detail),
    report_rec_sources_block(rec$sources)
  )
}

report_recommendations_section <- function(urls, sources) {
  recs <- report_recommendations(urls, sources)
  if (length(recs) == 0L) {
    return(htmltools::tags$section(
      class = "smr-section",
      htmltools::tags$h2("Recommendations"),
      htmltools::tags$p(
        class = "smr-ok-note",
        "Nothing to recommend: no threshold or advisory field applies."
      )
    ))
  }
  htmltools::tags$section(
    class = "smr-section",
    htmltools::tags$h2("Recommendations"),
    lapply(recs, report_rec_block)
  )
}
