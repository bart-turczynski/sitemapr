# Package load hooks.
#
# rurl's internal `full_parse` cache defaults to an unbounded (`max_entries =
# Inf`) store: every distinct URL parsed via `parse_url_adapter()` (R/url.R) is
# retained for the life of the session. Validating several large sitemaps (e.g.
# 10 x 50 000 URLs) would leave ~500 000 entries cached forever — a latent
# session-memory footprint, not a speed bug.
#
# The cache is worth KEEPING: for distinct URLs it costs ~nothing, and for the
# repeats the pipeline produces (the same loc re-parsed across stages, or
# duplicate locs) it is a large win. So we do not disable it — we only switch it
# to a bounded LRU so its footprint is capped at roughly one max sitemap's worth
# of entries. See memory layer-d-50k-perf.md.

# Bound applied to rurl's `full_parse` cache at load. Resolves from
# `getOption("sitemapr.rurl_cache_max")`, then the default of 50 000 (the
# sitemap-protocol per-file URL limit — one max sitemap's worth of entries).
rurl_cache_max <- function(
  max_full_parse = getOption("sitemapr.rurl_cache_max", 50000L)
) {
  as.integer(max_full_parse)
}

.onLoad <- function(libname, pkgname) {
  # Guard against a rurl that is unavailable or a future release whose
  # `rurl_cache_config()` no longer accepts `max_full_parse`: a failure here
  # must never block package load.
  if (!requireNamespace("rurl", quietly = TRUE)) {
    return(invisible(NULL))
  }
  tryCatch(
    rurl::rurl_cache_config(max_full_parse = rurl_cache_max()),
    error = function(e) invisible(NULL)
  )
  invisible(NULL)
}
