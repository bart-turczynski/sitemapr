# Effective-noindex producer — <meta name=robots> + X-Robots-Tag (E.3,
# SITE-weonydlw; docs/design/layer-e-page-inspection.md §4, §5.1, §0.3;
# docs/sitemap-spec.md §13.2). Internal only.
#
# Sibling of R/page-canonical.R / R/page-hreflang.R over the same
# page_inspection_run. Emits the two committed CHANNEL codes — they say *what
# and where* the directive was seen — while the engine fold drives the message
# and the effective-indexability verdict (§5.1 option a). No fused code is
# minted, so the registry needs no migration.
#
# The three-stage model (§13.2); a naive "noindex in either channel wins" fold
# is wrong because it skips crawler scoping and assumes a conflict rule that
# does not hold across engines:
#
#   1. extract  — every directive fact, per channel, per crawler scope.
#   2. filter   — keep the directives applying to the target crawler.
#   3. fold     — resolve the survivors to an effective directive per engine.
#
# INTERPRETATION MUST NOT INVOKE robotstxtr. `robotstxtr` is a `Suggests`, and
# per §0.3 / §13.1 only the ACCESS checks (E.5/E.1b) may gate on its presence.
# Crawler scoping here is prefix/string matching on a product token, not
# robots.txt group selection, so this file has no robotstxtr dependency at all
# and degrades gracefully when it is absent.
#
# Scope is EFFECTIVE NOINDEX, not full indexability: `unavailable_after` and the
# other time-scoped directives are out of scope for v0.2, and canonical / HTTP
# status / robots access are reported by their own checks.

# Registry-conformant severity for a noindex code (findings-registry.csv). The
# producer emits the CODE and looks the severity up here so it can never
# diverge from the registry; pinned as literals because the CSV is not in the
# installed package tree. A registry severity change is a coordinated migration.
page_noindex_severity <- function(code) {
  sev <- c(
    PAGE_META_ROBOTS_NOINDEX = "warning",
    PAGE_XROBOTSTAG_NOINDEX = "warning"
  )
  unname(sev[[code]])
}

# The directive tokens that suppress indexing, and the ones that explicitly
# assert it. `none` is the documented shorthand for `noindex,nofollow`, so it
# counts as a noindex token.
page_noindex_tokens <- function() {
  c("noindex", "none")
}

page_index_tokens <- function() {
  c("index", "all")
}

# The crawler names each engine answers to in a page directive, lowercased.
# sitemapr-owned and documented in sitemap-spec §13.1 ON TOP OF robotstxtr's
# product-token vocabulary — deliberately a local constant rather than a call
# into the sibling, so interpretation stays dependency-free.
page_engine_crawlers <- function(engine) {
  switch(
    engine,
    google = c("googlebot", "googlebot-news", "googlebot-image", "google"),
    bing = c("bingbot", "msnbot", "bing"),
    yandex = c("yandexbot", "yandex"),
    character(0)
  )
}

# Split a directive value into normalized tokens: comma-separated, trimmed,
# lowercased, empties dropped. Handles the repeated/comma-separated forms both
# channels allow.
page_directive_tokens <- function(value) {
  if (length(value) == 0L) {
    return(character(0))
  }
  parts <- unlist(strsplit(as.character(value), ",", fixed = TRUE))
  parts <- tolower(trimws(parts))
  parts[nzchar(parts)]
}

# Meta-robots facts from an HTML body: one record per `<meta name content>`
# whose name is "robots" (unscoped) or an engine crawler name (scoped). A
# malformed or non-HTML body parses leniently and yields none.
page_meta_robots_facts <- function(body) {
  if (length(body) == 0L) {
    return(list())
  }
  doc <- tryCatch(xml2::read_html(body), error = function(e) NULL)
  if (is.null(doc)) {
    return(list())
  }
  nodes <- xml2::xml_find_all(doc, "//meta[@name and @content]")
  if (length(nodes) == 0L) {
    return(list())
  }
  names_attr <- tolower(trimws(xml2::xml_attr(nodes, "name")))
  content <- xml2::xml_attr(nodes, "content")
  known <- c(
    "robots",
    unlist(lapply(
      c("google", "bing", "yandex"),
      page_engine_crawlers
    ))
  )
  out <- list()
  for (i in seq_along(names_attr)) {
    if (!names_attr[[i]] %in% known) {
      next
    }
    out[[length(out) + 1L]] <- list(
      channel = "meta",
      scope = if (identical(names_attr[[i]], "robots")) {
        "*"
      } else {
        names_attr[[i]]
      },
      raw = as.character(content[[i]]),
      tokens = page_directive_tokens(content[[i]])
    )
  }
  out
}

# X-Robots-Tag facts from the response headers. A value may be bare
# ("noindex") or crawler-prefixed ("googlebot: noindex"); repeated headers and
# comma-separated values both expand. The prefix is only treated as a crawler
# scope when it names a crawler we know — otherwise the colon belongs to the
# directive value and the whole string is unscoped.
page_xrobots_facts <- function(headers) {
  values <- page_header_values(headers, "X-Robots-Tag")
  if (length(values) == 0L) {
    return(list())
  }
  known <- unlist(lapply(
    c("google", "bing", "yandex"),
    page_engine_crawlers
  ))
  out <- list()
  for (value in values) {
    scope <- "*"
    rest <- value
    m <- regmatches(value, regexec("^\\s*([^:,]+)\\s*:\\s*(.*)$", value))[[1L]]
    if (length(m) == 3L && tolower(trimws(m[[2L]])) %in% known) {
      scope <- tolower(trimws(m[[2L]]))
      rest <- m[[3L]]
    }
    tokens <- page_directive_tokens(rest)
    if (length(tokens) == 0L) {
      next
    }
    out[[length(out) + 1L]] <- list(
      channel = "header",
      scope = scope,
      raw = as.character(value),
      tokens = tokens
    )
  }
  out
}

# Extract every robots-directive fact for one artifact (§4). Returns `status`
# (observed / absent / not_applicable) and the per-occurrence `facts`.
# Extraction runs only where there is a body/headers to read; any other outcome
# is not_applicable, mirroring the canonical and hreflang extractors.
page_noindex_extract <- function(art) {
  if (!art$outcome %in% c("usable_body", "partial")) {
    return(list(status = "not_applicable", facts = list()))
  }
  facts <- c(
    page_meta_robots_facts(art$body),
    page_xrobots_facts(art$terminal_headers)
  )
  status <- if (length(facts) == 0L) "absent" else "observed"
  list(status = status, facts = facts)
}

# Stage 2 — the crawler-applicability filter. An unscoped directive ("*")
# always applies; a scoped one applies only when it names a crawler the target
# engine answers to. With no engine selected (the baseline), only unscoped
# directives apply: a `googlebot`-scoped directive is not a fact about "the
# generic crawler".
page_noindex_applicable <- function(facts, engine = NULL) {
  if (length(facts) == 0L) {
    return(list())
  }
  crawlers <- if (is.null(engine)) {
    character(0)
  } else {
    page_engine_crawlers(engine)
  }
  keep <- vapply(
    facts,
    function(f) identical(f$scope, "*") || f$scope %in% crawlers,
    logical(1L)
  )
  facts[keep]
}

# Does this channel's surviving token set assert a noindex / an explicit index?
page_channel_has <- function(facts, channel, tokens) {
  for (f in facts) {
    if (identical(f$channel, channel) && any(f$tokens %in% tokens)) {
      return(TRUE)
    }
  }
  FALSE
}

# Stage 3 — the engine fold (§13.2). Returns the effective verdict plus the
# fold path, which drives producer provenance.
#
# Google / Bing fold toward the RESTRICTIVE reading (most-restrictive wins);
# Yandex folds the opposite way (an explicit index/all overrides a noindex). So
# divergence only bites on an explicit conflict — with a noindex in one channel
# and nothing opposing it, all three engines agree.
#
# `path` is "single_channel" when only one channel carries a noindex and
# nothing opposes it (the fold is then engine-independent), "cross_channel"
# when both channels are involved, and "conflict" when an explicit index
# opposes a noindex (where engines genuinely differ).
page_noindex_fold <- function(facts, engine = NULL) {
  meta_no <- page_channel_has(facts, "meta", page_noindex_tokens())
  head_no <- page_channel_has(facts, "header", page_noindex_tokens())
  meta_yes <- page_channel_has(facts, "meta", page_index_tokens())
  head_yes <- page_channel_has(facts, "header", page_index_tokens())
  any_no <- meta_no || head_no
  any_yes <- meta_yes || head_yes

  path <- if (!any_no) {
    "none"
  } else if (any_yes) {
    "conflict"
  } else if (meta_no && head_no) {
    "cross_channel"
  } else {
    "single_channel"
  }

  # Without an engine there is no fold to apply (§13.4): report the channels
  # observed, but compute no effective verdict.
  effective <- if (is.null(engine)) {
    NA
  } else if (identical(engine, "yandex")) {
    any_no && !any_yes
  } else {
    any_no
  }

  list(
    meta_noindex = meta_no,
    header_noindex = head_no,
    explicit_index = any_yes,
    effective_noindex = effective,
    path = path
  )
}

# Producer provenance for a fold result (§0.10 / §13.2). A single-channel
# noindex is the `documented` general rule; applying the fold ACROSS channels
# (meta vs header) has no worked example in Google's docs, so that atomic fact
# is `inferred` — diagnostic only. A conflict resolves per the engine's own
# documented direction.
page_noindex_provenance <- function(fold, engine = NULL) {
  if (is.null(engine)) {
    return(NA_character_)
  }
  switch(fold$path, cross_channel = "inferred", "documented")
}

# The engine name driving the fold, from the ruleset spec assemble_findings
# will stamp. The baseline (`sitemaps.org`) and the NULL ruleset both mean
# "no engine fold" (§13.4).
page_noindex_engine <- function(ruleset = NULL) {
  if (is.null(ruleset)) {
    return(NULL)
  }
  engine <- ruleset$ruleset
  if (is.null(engine) || identical(engine, "sitemaps.org")) {
    return(NULL)
  }
  engine
}

# The per-finding context (§0.7): the structured directive facts ride the
# engine-aware `context` list-column, never the frozen `evidence` list.
page_noindex_context <- function(loc, fold, extract, engine) {
  list(
    page_noindex_loc = loc,
    page_noindex_engine = if (is.null(engine)) NA_character_ else engine,
    page_noindex_effective = fold$effective_noindex,
    page_noindex_fold_path = fold$path,
    page_noindex_explicit_index = fold$explicit_index,
    page_noindex_facts = extract$facts
  )
}

# The human-facing message. It reports the channel (what the code says) and,
# where an engine fold applies, the effective verdict — including the case
# where an explicit index overrides the noindex under Yandex's allow-wins fold.
page_noindex_message <- function(channel, loc, fold, engine) {
  where <- if (identical(channel, "meta")) {
    "a <meta name=robots> noindex"
  } else {
    "an X-Robots-Tag noindex"
  }
  if (is.null(engine)) {
    return(sprintf("Advertised page %s carries %s.", loc, where))
  }
  if (isTRUE(fold$effective_noindex)) {
    return(sprintf(
      paste0(
        "Advertised page %s carries %s; under the %s fold it is ",
        "effectively noindex."
      ),
      loc,
      where,
      engine
    ))
  }
  sprintf(
    paste0(
      "Advertised page %s carries %s, but an explicit index/all directive ",
      "overrides it under the %s fold, so it is not effectively noindex."
    ),
    loc,
    where,
    engine
  )
}

# One channel's finding, or NULL when that channel carries no applicable
# noindex. Both channel findings fire independently (D2) — the codes report
# provenance-of-signal, so a page carrying a noindex in BOTH channels yields
# both rows.
page_noindex_channel_finding <- function(
  channel,
  code,
  art,
  loc,
  base,
  fold,
  extract,
  engine
) {
  present <- if (identical(channel, "meta")) {
    fold$meta_noindex
  } else {
    fold$header_noindex
  }
  if (!isTRUE(present)) {
    return(NULL)
  }
  page_findings(
    code = code,
    severity = page_noindex_severity(code),
    subject_ref = page_subject_ref(base, loc),
    message = page_noindex_message(channel, loc, fold, engine),
    evidence = list(finding_evidence(
      excerpt = page_noindex_excerpt(extract$facts, channel)
    )),
    context = list(page_noindex_context(loc, fold, extract, engine)),
    provenance = page_noindex_provenance(fold, engine),
    is_strict_only = FALSE
  )
}

# The raw directive text for the channel, for `evidence$excerpt` (free-form).
page_noindex_excerpt <- function(facts, channel) {
  raw <- character(0)
  for (f in facts) {
    if (identical(f$channel, channel)) {
      raw <- c(raw, f$raw)
    }
  }
  if (length(raw) == 0L) {
    return(channel)
  }
  toString(unique(raw))
}

# Produce the page-layer noindex findings for a page_inspection_run. Mirrors
# page_canonical_findings(), with the addition that the ENGINE reaches the
# producer: the fold is engine-dependent, so unlike the canonical/hreflang
# producers this one needs the ruleset rather than leaving everything to the
# assembler's per-code stamp.
page_noindex_findings <- function(run, subjects = NULL, ruleset = NULL) {
  artifacts <- run$artifacts
  if (length(artifacts) == 0L) {
    return(empty_page_findings())
  }
  if (is.null(subjects)) {
    subjects <- page_default_subjects(run)
  }
  engine <- page_noindex_engine(ruleset)
  loc_art <- page_loc_artifact_map(artifacts)
  out <- list()
  for (i in seq_along(subjects$loc)) {
    loc <- subjects$loc[[i]]
    art <- loc_art[[loc]]
    if (is.null(art)) {
      next
    }
    extract <- page_noindex_extract(art)
    if (!identical(extract$status, "observed")) {
      next
    }
    applicable <- page_noindex_applicable(extract$facts, engine)
    fold <- page_noindex_fold(applicable, engine)
    base <- subjects$base[[i]]
    for (spec in list(
      list("meta", "PAGE_META_ROBOTS_NOINDEX"),
      list("header", "PAGE_XROBOTSTAG_NOINDEX")
    )) {
      finding <- page_noindex_channel_finding(
        spec[[1L]],
        spec[[2L]],
        art,
        loc,
        base,
        fold,
        extract,
        engine
      )
      if (!is.null(finding)) {
        out[[length(out) + 1L]] <- finding
      }
    }
  }
  if (length(out) == 0L) {
    return(empty_page_findings())
  }
  do.call(rbind, out)
}
