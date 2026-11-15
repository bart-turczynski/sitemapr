# ADR-012: Findings for discovery from a site root

- Status: Accepted (2026-11-15)
- Date: 2026-11-15
- Deciders: Bart Turczyński, who delegated the choice to Claude and Codex
  agreeing (consult thread `sitemapr-discovery-findings`, two turns; both
  agreed on every point below)
- Extends: ADR-007 (API entry points: no new discovery export), ADR-006
  (robots-aware discovery)
- Related: SITE-utjicjfu, SITE-zczpxmow, SITE-zaerllaz
  (`sitemap_tree(robots_txt =)`), robotstxtr ROBO-hfbdlevd (where the work
  started)

---

## Context

`sitemap_tree(from = "root")` explains discovery as a tree of accepted and
rejected candidates, but it returns no findings. A consumer that reads only
findings never learns that a sitemap declared in robots.txt is a 404, an HTML
page or a corrupt gzip stream (SITE-utjicjfu), or that a robots.txt declares a
sitemap on another host (SITE-zczpxmow). `audit_sitemap()` returns findings,
but it takes sitemap URLs, not a site root. ADR-007 argues against new
discovery exports.

## Decision

1. **Surface.** `audit_sitemap()` gains `from = c("sitemap", "root")`, plus
   `use_robots`, `use_known_paths` and `robots_txt` as in `sitemap_tree()`.
   With `from = "root"`, `x` is one site root. The audit runs discovery, then
   audits each qualifying candidate through the single-pass path.
   `audit_findings()` carries the discovery findings, and `audit_tree()` holds
   the discovery tree, equal to `sitemap_tree()` on the same site. No new export.
   The default, `from = "sitemap"`, is unchanged.
2. **One fetch.** A candidate discovery accepted is audited from the response
   discovery fetched; it is not requested again.
3. **Which candidates are audited.** Every robots-declared candidate. A
   guessed-only candidate is audited only when its body has a recognized
   sitemap format: a gzip stream, a `urlset` or `sitemapindex` root, a feed, or
   text in which one line is an absolute http(s) URL. A guess qualifies on
   recognition, not validity, so a malformed sitemap at a guessed path is still
   reported. A guessed-only 404, HTML page (a soft 404) or other XML root stays
   a tree row and is never a finding. This extends the spec rule "a guess that
   404s is never a finding" (`docs/sitemap-spec.md` §9) to soft 404s.
4. **Codes.** A failing declared sitemap reuses the code a submitted sitemap
   gets, at its registered severity **and layer**: `FETCH_TIMEOUT` and
   `FETCH_BODY_CEILING_EXCEEDED` where the fetch ended that way, `FETCH_FAILED`
   (fetch, fatal) for a non-2xx status, an unreachable host or a blocked
   address;
   `UNSUPPORTED_HTML_MASQUERADE`, `UNSUPPORTED_ROOT` and
   `UNSUPPORTED_MALFORMED_GZIP` for a body that is not a sitemap. A code carries
   one layer in `findings-registry.csv`, which the sibling port shares, so
   discovery does not re-layer it. A fatal finding stays local to its source and
   never aborts the audit.
5. **One new code.** `DISCOVERY_ROBOTS_SITEMAP_CROSS_HOST` (`info`, layer
   `discovery`, subject type `source`), for a declared sitemap whose host
   differs from the host of the robots.txt that declares it, after any redirect
   (an apex robots.txt that redirects to `www` is compared as `www`); supplied
   text is compared against the site's host. It is emitted whether or not that
   sitemap works.
   sitemaps.org accepts a cross-host sitemap when the robots.txt declares it, so
   the finding is evidence for the reader, not a defect.
6. **Provenance.** `subject_ref` stays the sitemap URL, after any redirect, as
   for a submitted sitemap. The declaring source, the robots.txt's final URL
   or `"supplied robots_txt"`, is named in the message of
   each source-level finding (fetch, classification, decompression) of a
   declared sitemap. It is also named in the evidence excerpt of the two
   findings discovery builds itself, `FETCH_FAILED` and the cross-host code.
   Findings of the audited sitemap keep their own excerpts.
7. **Run manifest.** A root audit that read a robots.txt (supplied, or fetched
   and declaring a sitemap) stamps `discovery` in `attr(findings,
   "layers_run")`, so the report's Checks section can show a clean discovery as
   passed. Without one (`use_robots = FALSE`, or a robots.txt that failed to
   fetch) the discovery checks stay not exercised: the report understates
   rather than overstates. An ordinary `from = "sitemap"` report now lists
   discovery as not exercised, because the layer has an active check.

## Consequences

- One call now answers "what is wrong with this site's sitemaps?" from a root,
  in findings, and a draft robots.txt can be checked before deployment.
- `audit_sitemap(from = "root")` fetches every accepted guess that qualifies,
  plus index children, the same requests `sitemap_tree()` makes.
- The registry gains one active row; `registry_revision` moves to `2026-11-15`.
  The sibling port has no counterpart yet, so its `validator_code` is blank
  (not comparable).
- Options not taken: a new export such as `validate_robots_sitemaps()` (ADR-007
  argues against it), and a `findings` attribute on `sitemap_tree()` (hidden
  from a consumer that reads only findings).
- Known limits, left for later: root mode takes no `discovery_limits()` (the
  default candidate cap applies); an accepted body is parsed once for the tree's
  page count and again by the audit; index children do not share discovery's
  per-host throttle bucket (ADR-008 §6); and a robots.txt that fails to fetch
  is no finding (`DISCOVERY_ROBOTS_FAILED` stays validator-only).
