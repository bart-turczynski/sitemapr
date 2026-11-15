# audit_sitemap(from = "root"): discovery findings (ADR-012; SITE-utjicjfu,
# SITE-zczpxmow).
#
# sitemap_tree(from = "root") explains discovery as a tree but returns no
# findings, so a consumer that reads only findings never saw a robots-declared
# sitemap that fails. Root mode runs the same discovery, then audits each
# qualifying candidate through the single-pass audit path, reusing the fetch
# record discovery already made (no second request for the root document).
#
#   robots-declared candidate  always audited when accepted; a rejected one
#                              (non-2xx, unreachable, blocked) is FETCH_FAILED.
#                              Its source-level findings name the robots.txt.
#   guessed-only candidate     audited only when its body is a recognized
#                              sitemap format (audit_guess_qualifies()); a soft
#                              404 HTML page, a wrong root or a non-2xx stays a
#                              tree row with no finding (spec §9).
#   cross-host declaration     DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST (info),
#                              whether or not the declared sitemap works.
#
# Reused internals (do NOT reimplement here):
#   discover_candidates()  R/discovery.R       candidate fetch + classification
#   audit_one_source()     R/audit-pipeline.R  single-pass read + findings
#   sitemap_tree_rows()    R/sitemap-tree.R    the tree column contract

# Does a guessed-only candidate's body look like a sitemap? Recognition, not
# validity: a corrupt gzip stream or a malformed urlset still qualifies, so a
# broken sitemap at a guessed path is reported rather than silently dropped. A
# text body qualifies only when one line is an absolute http(s) URL, so a plain
# "Not found" page does not become a text sitemap.
audit_guess_qualifies <- function(rec) {
  bytes <- attr(rec, "body")
  fmt <- sniff_format(bytes)
  if (fmt %in% c("gzip", "xml-urlset", "xml-sitemapindex", "feed")) {
    return(TRUE)
  }
  if (!identical(fmt, "text")) {
    return(FALSE)
  }
  text <- decode_text_or_null(bytes)
  !is.null(text) &&
    any(grepl("^\\s*https?://\\S+\\s*$", split_lines(text), perl = TRUE))
}

# Where a declaration came from, as findings name it: the robots.txt it was
# read from, after any redirect, or the caller's supplied text.
audit_robots_source <- function(robots_url, origin, robots_txt) {
  if (!is.null(robots_txt)) {
    return("supplied robots_txt")
  }
  if (is.na(robots_url)) robots_txt_url(origin) else robots_url
}

# The host of an absolute URL in the site-entrypoint normal form (IDNA, then
# lower-cased, as create_source_records() spells an origin), so two spellings
# of one host compare equal; NA when it does not parse.
audit_url_host <- function(url) {
  origin <- tryCatch(
    create_source_records(url, as = "site")$normalized_url[[1L]],
    error = function(e) NA_character_
  )
  if (is.na(origin)) {
    return(NA_character_)
  }
  host <- parse_url_adapter(origin)$host[[1L]]
  if (is.na(host)) NA_character_ else host
}

# DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST for one declared sitemap, or NULL when it
# is on the robots.txt's own host. sitemaps.org accepts a cross-host sitemap
# with proof of ownership, and a robots.txt reference is that proof, so this is
# evidence for the reader, not a defect.
audit_cross_host_finding <- function(url, site_host, declared_in) {
  host <- audit_url_host(url)
  if (is.na(host) || is.na(site_host) || identical(host, site_host)) {
    return(NULL)
  }
  tibble::tibble(
    code = "DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST",
    severity = "info",
    layer = "discovery",
    subject_type = "source",
    subject_ref = sitemap_subject_ref(url),
    message = sprintf(
      paste0(
        "Sitemap %s is on host %s, but it is declared in %s for host %s. ",
        "sitemaps.org accepts a cross-host sitemap when the robots.txt ",
        "declares it."
      ),
      url,
      host,
      declared_in,
      site_host
    ),
    evidence = list(finding_evidence(
      excerpt = sprintf(
        "%s declares %s (sitemap host %s, robots.txt host %s)",
        declared_in,
        url,
        host,
        site_host
      )
    )),
    is_strict_only = FALSE
  )
}

# The fetch finding for a robots-declared sitemap discovery rejected: the code a
# submitted sitemap would get for the same outcome (fetch_failure_code()), so a
# timeout is FETCH_TIMEOUT and a non-2xx status, an unreachable host or an SSRF
# block FETCH_FAILED, all `fatal` in the fetch layer. The robots provenance
# rides in the message and the evidence excerpt.
audit_declared_fetch_finding <- function(
  url,
  reason,
  http_status,
  declared,
  cnd = NULL
) {
  why <- if (!is.na(http_status)) {
    sprintf("HTTP %d", http_status)
  } else if (!is.null(cnd)) {
    sprintf("%s (%s)", reason, conditionMessage(cnd))
  } else {
    reason
  }
  tibble::tibble(
    code = fetch_failure_code(cnd),
    severity = "fatal",
    layer = "fetch",
    subject_type = "source",
    subject_ref = sitemap_subject_ref(url),
    message = sprintf(
      "Sitemap %s, declared in %s, could not be fetched: %s.",
      url,
      declared,
      why
    ),
    evidence = list(finding_evidence(
      excerpt = sprintf("%s declares %s (%s)", declared, url, why)
    )),
    is_strict_only = FALSE
  )
}

# Name the robots.txt in the source-level findings of an audited declared
# sitemap (fetch, classification, decompression), so a failure read from the
# findings alone says where the sitemap was declared. Per-entry and protocol
# findings keep their messages: they are about the document, not about how it
# was found.
# `urls` holds every spelling the audit may have used for the sitemap: the
# declared URL, its normalized form and the post-redirect URL.
audit_attribute_robots <- function(findings, urls, declared_in) {
  refs <- vapply(urls, sitemap_subject_ref, character(1L), USE.NAMES = FALSE)
  hit <- findings$subject_type == "source" &
    findings$layer %in% c("fetch", "classification", "decompression") &
    findings$subject_ref %in% refs
  if (any(hit)) {
    findings$message[hit] <- paste0(
      findings$message[hit],
      sprintf(" (Declared in %s.)", declared_in)
    )
  }
  findings
}

# Page count and gzip flag for a discovery row, from the body discovery fetched
# (as sitemap_tree_expansions() derives them, without expanding).
audit_root_row_facts <- function(rec, status, url) {
  if (is.null(rec)) {
    return(list(page_count = NA_integer_, gzip = NA))
  }
  gzip <- identical(as.character(rec$format), "gzip")
  if (!identical(status, "accepted")) {
    return(list(page_count = NA_integer_, gzip = gzip))
  }
  parsed <- tryCatch(
    parse_dispatch(attr(rec, "body"), source_sitemap = url),
    error = function(e) NULL
  )
  pages <- if (is.null(parsed)) NA_integer_ else count_pages(parsed)
  list(page_count = as.integer(pages), gzip = gzip)
}

# The audit expands an index under the URL it resolved to; sitemap_tree() names
# the children's parent by the candidate URL. Re-parent the direct children of a
# redirected candidate so the two trees agree.
audit_reparent_tree <- function(tree, final_url, candidate_url) {
  if (nrow(tree) == 0L || is.na(final_url) || final_url == candidate_url) {
    return(tree)
  }
  moved <- tree$depth == 1L & tree$parent_sitemap %in% final_url
  tree$parent_sitemap[moved] <- candidate_url
  tree
}

audit_sitemap_root <- function(
  x,
  mode,
  user_agent,
  limits,
  index_limits,
  policy,
  strm,
  use_robots,
  use_known_paths,
  robots_txt
) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    rlang::abort(
      "With `from = \"root\"`, `x` must be a single site-root URL.",
      class = "sitemapr_bad_input"
    )
  }
  site <- create_source_records(x, as = "site")
  origin <- site$normalized_url[[1L]]
  policy <- request_policy_pin(policy, site)
  site_host <- audit_url_host(origin)

  disc <- discover_candidates(
    x,
    user_agent = user_agent,
    net_limits = limits,
    policy = policy,
    use_known_paths = use_known_paths,
    use_robots = use_robots,
    robots_txt = robots_txt
  )
  records <- attr(disc, "records")
  conditions <- attr(disc, "conditions")

  outs <- list()
  own <- list()
  n <- nrow(disc)
  page_count <- rep(NA_integer_, n)
  gzip <- rep(NA, n)

  for (i in seq_len(n)) {
    url <- disc$candidate_url[[i]]
    rec <- records[[i]]
    status <- disc$status[[i]]
    declared <- identical(disc$provenance[[i]], "robots")
    facts <- audit_root_row_facts(rec, status, url)
    page_count[i] <- facts$page_count
    gzip[i] <- facts$gzip

    if (declared) {
      robots_url <- disc$robots_url[[i]]
      declared_in <- audit_robots_source(robots_url, origin, robots_txt)
      # The robots.txt's own host, after any redirect (apex to www): the
      # declaration is cross-host only against the file that made it.
      robots_host <- if (is.na(robots_url)) {
        site_host
      } else {
        audit_url_host(robots_url)
      }
      own[[length(own) + 1L]] <- audit_cross_host_finding(
        url,
        robots_host,
        declared_in
      )
    }
    if (!identical(status, "accepted")) {
      if (declared) {
        own[[length(own) + 1L]] <- audit_declared_fetch_finding(
          url,
          disc$reason[[i]],
          disc$http_status[[i]],
          declared_in,
          cnd = conditions[[i]]
        )
      }
      next
    }
    if (!declared && !audit_guess_qualifies(rec)) {
      next
    }
    src <- create_source_records(url, as = "sitemap")[1L, , drop = FALSE]
    out <- suppressWarnings(audit_one_source(
      src,
      mode = mode,
      user_agent = user_agent,
      limits = limits,
      index_limits = index_limits,
      policy = policy,
      strm = strm,
      rec = rec
    ))
    final_url <- disc$final_url[[i]]
    if (declared) {
      out$findings <- audit_attribute_robots(
        out$findings,
        unique(c(url, src$normalized_url[[1L]], final_url)),
        declared_in
      )
    }
    out$tree <- audit_reparent_tree(out$tree, final_url, url)
    outs[[length(outs) + 1L]] <- out
  }

  base <- sitemap_tree_rows(
    depth = 0L,
    parent_sitemap = NA_character_,
    sitemap_url = disc$candidate_url,
    page_count = page_count,
    gzip = gzip,
    status = disc$status,
    reason = disc$reason,
    provenance = disc$provenance
  )
  combined <- audit_combine_outputs(outs)
  own <- Filter(Negate(is.null), own)
  if (length(own) > 0L) {
    combined$findings <- combine_findings_contracts(list(
      combined$findings,
      assemble_findings(own, mode)
    ))
  }
  # The discovery checks ran only if robots.txt was read: supplied, or fetched
  # and declaring at least one sitemap. A robots.txt that failed to fetch, or
  # `use_robots = FALSE`, leaves them unproven, so the report shows them as not
  # exercised rather than passed (understating, never overstating).
  robots_read <- !is.null(robots_txt) || any(disc$provenance == "robots")
  if (isTRUE(use_robots) && robots_read) {
    combined$findings <- findings_stamp_layers(
      combined$findings,
      union(findings_layers_run(combined$findings), "discovery")
    )
  }
  combined$tree <- audit_combine_trees(list(base, combined$tree))
  combined
}
