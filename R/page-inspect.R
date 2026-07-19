# Engine-neutral page-inspection selection + budget orchestration (Layer E,
# Contract A budget; E.1s).
#
# Internal only. PURE ORCHESTRATION MECHANICS: given a list of advertised page
# `locs` and a page-inspection budget, it dedups by canonical loc identity,
# deterministically selects a sample, and drives page_fetch() (E.1a) over the
# selection under an aggregate budget, isolating per-URL failures. It returns a
# `page_inspection_run` object: the deduped->selected artifacts (keyed by
# canonical loc) plus coverage/budget bookkeeping. It emits NO findings, adds NO
# PAGE_* codes, maps NO outcome to a code, and sets NO finding precedence — that
# is E.1f. It does not modify page_fetch()/fetch_source(); it consumes them.
#
# Governing contracts (conform, do not restate):
#   docs/design/layer-e-page-inspection.md  §3.3 (aggregate budget), §0.1
#     (engine-neutral mechanics), §6.2 (coverage shape E.1f derives from)
#   docs/decisions/ADR-008-*.md  (deterministic reproducibility contract)
#   docs/decisions/ADR-003-*.md  §3 (all caps caller-overridable, safe
#     defaults, no hard floor)
#
# Batch budgeting decision (spec §3.3 open item): this orchestrator enforces ONE
# budget over the loc set handed to it. `validate_sitemaps*()` therefore gets a
# BATCH-WIDE budget by wiring E.1f to pass the union of every sitemap's deduped
# locs in a single run() call (the safe default: it bounds total network
# expansion regardless of how many sitemaps a batch spans). A per-sitemap budget
# is available to E.1f by calling run() once per sitemap instead. Choosing which
# loc set to pass is E.1f's; the mechanics here are identical either way.

# The aggregate page-inspection budget: the §3.3 caps, each caller-overridable
# with a safe default and NO hard floor (ADR-003 §3). The four run-wide caps
# accept a positive-infinite value (uncapped); `page_body_cap` is the per-page
# truncate-and-retain bound threaded straight to page_fetch(page_body_cap = ).
#   * max_pages    -- distinct pages fetched across the run.
#   * max_requests -- HTTP hops performed across the run (a redirect chain of k
#                     hops counts k, not 1), mirroring the §3.3 "max requests
#                     (hops count)" cap.
#   * max_bytes    -- aggregate retained body bytes across the run.
#   * page_body_cap-- per-page body cap passed to page_fetch (default 1 MB).
#   * max_seconds  -- max elapsed wall-clock time for the run.
page_inspection_budget <- function(
  max_pages = 50L,
  max_requests = 250L,
  max_bytes = 50L * 1024L^2,
  page_body_cap = page_body_cap_default(),
  max_seconds = 300
) {
  check_limit(max_pages, "max_pages", allow_inf = TRUE)
  check_limit(max_requests, "max_requests", allow_inf = TRUE)
  check_limit(max_bytes, "max_bytes", allow_inf = TRUE)
  check_limit(page_body_cap, "page_body_cap")
  check_limit(max_seconds, "max_seconds", allow_inf = TRUE)
  list(
    max_pages = max_pages,
    max_requests = max_requests,
    max_bytes = max_bytes,
    page_body_cap = page_body_cap,
    max_seconds = max_seconds
  )
}

# Dedup a vector of advertised `locs` by canonical loc identity. Reuses the
# shared canonical key (build_loc_key over parse_url_adapter -- the SAME fetch
# target/identity form R/url.R documents), so a URL advertised by several
# sitemaps/anchors resolves to ONE fetch key. Only absolute http(s) locs that
# parsed cleanly are eligible; anything else is dropped from inspection (a
# non-http scheme, an unparseable string, or an empty/NA entry is never
# fetched). Returns the per-key entries in first-seen order -- each entry keeps
# every raw advertised loc that mapped to it, so E.1f can still anchor a finding
# to each advertising subject_ref -- plus the pre-dedup eligible count.
page_inspection_dedup <- function(locs) {
  locs <- as.character(locs)
  parsed <- parse_url_adapter(locs)
  scheme <- tolower(as.character(parsed$scheme))
  status <- as.character(parsed$parse_status)
  keys <- build_loc_key(parsed)
  eligible <- !is.na(locs) &
    nzchar(locs) &
    status == "ok" &
    scheme %in% c("http", "https")

  entries <- list()
  for (i in which(eligible)) {
    key <- keys[[i]]
    if (is.null(entries[[key]])) {
      entries[[key]] <- list(fetch_url = key, advertised = locs[[i]])
    } else {
      entries[[key]]$advertised <- c(entries[[key]]$advertised, locs[[i]])
    }
  }
  list(entries = entries, eligible = sum(eligible))
}

# Deterministically select which deduped keys to fetch. Ordering is a STABLE
# hash order over the keys (rlang::hash of the canonical key string -- an md5
# digest, stable across sessions and platforms), with the key itself as the
# tie-break. Because the order is a property of the key SET, not of input order,
# re-running the same input picks the SAME sample in the SAME order (ADR-008's
# reproducibility contract). `full` mode returns every key in that order;
# `sample` mode returns its first `sample_size`. Both the selection AND the
# emitted order are deterministic.
page_inspection_select <- function(keys, sample_size, mode) {
  if (length(keys) == 0L) {
    return(character(0))
  }
  digests <- vapply(keys, rlang::hash, character(1), USE.NAMES = FALSE)
  ordered <- keys[order(digests, keys)]
  if (identical(mode, "full")) {
    return(ordered)
  }
  ordered[seq_len(min(as.integer(sample_size), length(ordered)))]
}

# Which run-wide cap (if any) is already reached BEFORE the next fetch starts.
# Checked in a fixed order so priority is deterministic; the first cap reached
# stops the run. A cap is only ever consulted while a selected key still remains
# to fetch, so exhausting the selection naturally (nothing left) never records a
# cap -- a fully-covered run is not "partial". Returns NA when no cap bit.
page_inspection_cap_hit <- function(st, budget, clock, start) {
  if (st$attempted >= budget$max_pages) {
    return("max_pages")
  }
  if (st$requests >= budget$max_requests) {
    return("max_requests")
  }
  if (st$bytes >= budget$max_bytes) {
    return("max_bytes")
  }
  if ((as.numeric(clock()) - start) >= budget$max_seconds) {
    return("max_seconds")
  }
  NA_character_
}

# Fetch one page with failure isolation. page_fetch() already captures
# safety_refused / transport_fail / http_status / redirect_over_budget etc. as a
# per-URL artifact WITHOUT throwing, so the loop continues on any such outcome.
# The tryCatch here is a defensive belt for an unexpected error: it still yields
# an artifact (transport_fail) so one failure NEVER aborts the sample.
page_inspection_fetch_one <- function(
  url,
  budget,
  limits,
  user_agent,
  ssrf_guard,
  policy,
  throttle_state,
  fetch
) {
  tryCatch(
    fetch(
      url,
      page_body_cap = budget$page_body_cap,
      limits = limits,
      user_agent = user_agent,
      ssrf_guard = ssrf_guard,
      policy = policy,
      throttle_state = throttle_state
    ),
    error = function(cnd) {
      page_fetch_artifact(
        requested_url = url,
        outcome = "transport_fail",
        request_user_agent = user_agent
      )
    }
  )
}

# Fold one artifact's contribution into the running budget/coverage tallies.
# `completed` counts a usable_body or partial outcome (a usable head region);
# every other outcome is a `failed` fetch; `partial` is also counted on its own.
page_inspection_tally <- function(st, art) {
  st$attempted <- st$attempted + 1L
  st$requests <- st$requests + length(art$hops)
  st$bytes <- st$bytes + length(art$body)
  if (art$outcome %in% c("usable_body", "partial")) {
    st$completed <- st$completed + 1L
  } else {
    st$failed <- st$failed + 1L
  }
  if (identical(art$outcome, "partial")) {
    st$partial <- st$partial + 1L
  }
  invisible(st)
}

# Drive page_fetch over the selected keys under the aggregate budget. Threads
# ONE shared throttle_state across every fetch (so per-host pacing works over
# the whole run) and reads the injected clock for wall-time capping. Stops at
# the first cap reached, recording which cap bit; otherwise runs the full
# selection. Accumulates artifacts (keyed by canonical key) + tallies in a
# mutable state env.
page_inspection_fetch_loop <- function(
  selected,
  entries,
  budget,
  limits,
  user_agent,
  ssrf_guard,
  policy,
  throttle_state,
  clock,
  fetch
) {
  start <- as.numeric(clock())
  st <- new.env(parent = emptyenv())
  st$artifacts <- list()
  st$attempted <- 0L
  st$completed <- 0L
  st$partial <- 0L
  st$failed <- 0L
  st$requests <- 0L
  st$bytes <- 0L
  st$caps_hit <- character(0)

  for (key in selected) {
    cap <- page_inspection_cap_hit(st, budget, clock, start)
    if (!is.na(cap)) {
      st$caps_hit <- cap
      break
    }
    entry <- entries[[key]]
    art <- page_inspection_fetch_one(
      entry$fetch_url,
      budget,
      limits,
      user_agent,
      ssrf_guard,
      policy,
      throttle_state,
      fetch
    )
    st$artifacts[[key]] <- list(
      fetch_url = entry$fetch_url,
      advertised = entry$advertised,
      artifact = art
    )
    page_inspection_tally(st, art)
  }

  st$elapsed <- as.numeric(clock()) - start
  st
}

# Run one page-inspection pass over `locs`: dedup -> deterministic select ->
# budgeted, failure-isolated fetch. Returns a `page_inspection_run` -- the
# per-key artifacts plus a `coverage` list shaped so E.1f can derive its
# coverage metadata (§6.2) and its transport findings.
#
# @param locs Character vector of advertised page URLs.
# @param budget A page_inspection_budget().
# @param sample_size Default sample N (caller-overridable); ignored in `full`.
# @param mode "sample" (default N) or "full" (all deduped locs, subject to the
#   caps).
# @param limits fetch_limits() forwarded to page_fetch (timeout, redirect cap,
#   500 MB per-resource ceiling).
# @param user_agent HTTP User-Agent forwarded to page_fetch.
# @param ssrf_guard Forwarded to page_fetch (per-hop SSRF guard).
# @param policy request_policy() forwarded to page_fetch; its `throttle` seeds
#   the shared throttle_state when one is not supplied.
# @param throttle_state Optional pre-built shared per-host throttle state; NULL
#   builds one from `policy$throttle` using the injected clock so pacing and
#   wall-time capping share one clock.
# @param clock Injectable time source (defaults to Sys.time) so wall-time
#   capping is testable offline.
# @param fetch The acquisition primitive; defaults to page_fetch (injectable).
page_inspection_run <- function(
  locs,
  budget = page_inspection_budget(),
  sample_size = 50L,
  mode = c("sample", "full"),
  limits = fetch_limits(),
  user_agent = default_user_agent(),
  ssrf_guard = TRUE,
  policy = request_policy(),
  throttle_state = NULL,
  clock = Sys.time,
  fetch = page_fetch
) {
  mode <- match.arg(mode)
  dedup <- page_inspection_dedup(locs)
  entries <- dedup$entries
  selected <- page_inspection_select(names(entries), sample_size, mode)

  if (is.null(throttle_state)) {
    throttle_state <- throttle_state_new(policy$throttle, now = clock)
  }

  st <- page_inspection_fetch_loop(
    selected,
    entries,
    budget,
    limits,
    user_agent,
    ssrf_guard,
    policy,
    throttle_state,
    clock,
    fetch
  )

  coverage <- list(
    eligible = dedup$eligible,
    deduplicated = length(entries),
    selected = length(selected),
    attempted = st$attempted,
    completed = st$completed,
    partial = st$partial,
    failed = st$failed,
    skipped = length(selected) - st$attempted,
    requests = st$requests,
    bytes = st$bytes,
    elapsed = st$elapsed,
    mode = mode,
    caps_hit = st$caps_hit,
    partial_run = length(st$caps_hit) > 0L
  )

  structure(
    list(artifacts = st$artifacts, coverage = coverage),
    class = "page_inspection_run"
  )
}
