# ADR-008: Deterministic bounded-concurrency semantics for child fetches

- Status: Accepted
- Date: 2026-07-11
- Deciders: Bart Turczyński
- Related: `docs/decisions/ADR-003-network-safety-policy.md`
  (limits, per-hop guard), `R/index-expansion.R` (traversal loop,
  aggregate budgets), `R/fetch.R` (`request_throttle()` / throttle state),
  SITE-dkyusnsu (this contract), SITE-tktfxoxe (implementation)

---

## Context

`sitemap_tree()` and index expansion walk a `sitemapindex` by fetching each
child sitemap, parsing it, and (for nested indexes) recursing. Today every
child fetch is **sequential**: `expand_index_node()` loops over the deduped,
capped child list and calls `fetch_and_parse_child()` one child at a time
(`R/index-expansion.R`). For a large index tree this is network-bound and slow,
because each fetch's round-trip latency is paid serially even though the
requests are independent.

Concurrency is the obvious speedup, and `httr2::req_perform_parallel()` gives us
a well-defined primitive to build on: it performs a list of requests with a
`max_active` worker cap, **returns the responses in request order** (not
completion order), and takes an `on_error` argument (`"return"` /`"continue"`)
that decides whether a failed request aborts the pool or is captured in place
and reported alongside the successes.

Introducing concurrency into a library whose contract today is a *deterministic*
row/finding table raises a sharp risk: if any observable output depends on the
order children happen to complete, two runs of the same input could disagree,
and the aggregate budgets (`max_total_sitemaps` / `max_total_urls`) could
truncate at different catalog positions from run to run. That is unacceptable
for a package used to produce reproducible audits.

Several questions therefore needed a settled answer before implementation
(SITE-tktfxoxe) begins:

1. What exactly is allowed to change when concurrency is on, and what must stay
   bit-for-bit identical to sequential mode?
2. How do the two independent rate limits — a global worker cap and the existing
   per-host throttle — compose?
3. How are the aggregate traversal budgets enforced when many fetches are in
   flight at once, so we never over-fetch and always truncate at the same point?
4. How does a single child's failure behave — abort the walk, or degrade to the
   same finding it produces today?
5. How do nested indexes fit into a level-bounded scheduler?
6. Today's per-host throttle state is scoped **per phase**, not per operation.
   Does concurrency inherit that seam, or must it unify it?

This ADR records the **approved** answers. It is a decision record, not an
implementation: no concurrency code lands here.

---

## Decision

### 0. Load-bearing invariant: concurrency is a scheduling optimization only

**The observable output of a traversal is byte-identical between sequential and
concurrent mode.** Concretely, for the same input and the same limits/policy,
the following are identical regardless of the order in which child fetches
complete:

- the URL **rows** and their **order**,
- the **`sources`** fetch-metadata records and their order,
- the **`problems`** / **findings** and their order,
- the **`tree`** rows and their order, and
- the exact **budget-truncation point** — which child is the last accepted and
  which is the first rejected with `reason = "url-budget"` /
  `"index-expansion"`.

Output is always emitted in **source / catalog order** — the deduped, capped
child order that `dedup_and_cap_children()` already fixes — never in child
**completion** order. This mirrors `httr2::req_perform_parallel()`, which
returns responses in request order: concurrency changes *when* a child's bytes
arrive, never *where* its rows land in the result.

Everything below is subordinate to this invariant. Any behaviour the scheduler
cannot make byte-identical to sequential mode is out of scope for opt-in
concurrency and must instead be an explicit, separately-flagged behaviour
change.

### 1. Opt-in; default sequential; sequential always available

Concurrency is **opt-in**. The default remains **sequential** expansion,
byte-identical to today's `expand_index()` path. A caller enables concurrency
explicitly (e.g. a `max_active`/worker argument or a concurrency object on the
request boundary; the exact surface is fixed by SITE-tktfxoxe). Sequential mode
is not a legacy fallback that may be removed — it is the reference semantics the
concurrent path is validated against, and it is always selectable, including as
`max_active = 1`, which MUST be observably identical to the sequential path.

### 2. Two independent rate limits: worker cap and per-host throttle

Two caps compose, and both are respected simultaneously:

- **Global worker cap.** A single `max_active` bound on the number of child
  fetches in flight across the whole operation, mapping directly onto
  `httr2::req_perform_parallel(max_active =)`. Default **4–6** (small, polite;
  final value fixed by SITE-tktfxoxe). The cap is global to one traversal, not
  per index level.
- **Per-host throttle.** The existing `request_throttle()` pacing
  (`policy$throttle`, keyed by canonical `host:port` buckets via
  `throttle_host_key()`) is **layered on top of** the worker cap. The worker cap
  bounds concurrency; the throttle bounds *rate per host*. A host with a
  configured `min_interval` is paced to that interval even when idle workers are
  available, so the two never fight: the effective behaviour is "at most
  `max_active` in flight, and no host fetched faster than its throttle allows."

The per-hop SSRF guard (ADR-003) and sitemapr's re-asserted transport controls
run per child exactly as in sequential mode; concurrency never widens the guard
surface or lets a redirect skip a hop check.

### 3. Budgets reserved before dispatch

The aggregate budgets (`max_total_sitemaps`, `max_total_urls`) are enforced by
**reserving budget before dispatch**, never by discarding already-fetched work
after the fact:

- The scheduler walks children in catalog order and only **dispatches** a child
  for which a sitemap-count slot is still available, so it **never over-fetches**
  past `max_total_sitemaps`.
- The URL-row budget (`max_total_urls`) is only known after a leaf parses. To
  keep truncation deterministic, results are **committed in catalog order**: a
  leaf's rows are admitted only once every earlier child in catalog order has
  been committed, and a leaf that would breach `max_total_urls` is left out
  **whole** (never partially) and recorded as a rejected tree row —
  bit-for-bit the rule `add_leaf_index_child()` already applies sequentially.
- The truncation point therefore lands at **the same catalog position**
  sequential mode would cut, independent of completion order. In-flight fetches
  beyond the truncation point are cancelled (see §5) and contribute nothing.

### 4. Partial failure: captured in place, same finding as today

A single child fetch error does **not** abort the traversal. This is the
`httr2::req_perform_parallel(on_error = "continue")` analog: the error is
captured in place, attributed to that child, and the walk continues to the
budget. The captured failure becomes the **same** problem/finding it produces
today — `fetch` / `classification` problems with the same wording and the same
rejected `tree` row (`unfetchable` / `http-error` / `unparseable`) that
`index_unfetchable_child()`, `index_http_error_child()`, and
`index_unparseable_child()` emit — so a run with one dead child yields an
identical result table whether that child was fetched sequentially or
concurrently.

### 5. Nested indexes and cancellation / error propagation

- **Nested indexes.** Concurrency is bounded **within a level**: the children of
  one index are the dispatchable unit. When a child is itself a `sitemapindex`,
  its own children are **enqueued** for scheduling once that index has been
  fetched and parsed (they cannot be known before). Depth, per-index child cap,
  and cycle detection on the identity key apply exactly as today, evaluated in
  catalog order before dispatch, so the set of visited nodes is unchanged.
- **Cancellation.** Once a budget stop is decided (§3), children in catalog
  order *after* the truncation point are not dispatched, and any already-
  dispatched-but-not-yet-committed fetch beyond that point is cancelled; a
  cancelled fetch produces no rows, no source record, and no finding. Because
  commit order is catalog order, cancellation can never remove a child that
  sequential mode would have kept.
- **Error propagation.** Per-child *fetch* errors are captured (§4), never
  propagated. Only a **non-per-child** failure — a caller streaming-callback
  error (`sitemapr_stream_callback_error`), a resource-ceiling abort
  (`sitemapr_body_ceiling`), or an internal scheduler fault — aborts the whole
  operation, and it does so **deterministically**: the abort is attributed to
  the earliest child in catalog order that triggers it, so which error surfaces
  does not depend on completion timing.

### 6. Throttle unification: one per-operation host-bucket store (requirement)

Today the per-host throttle state is scoped **per phase**, not per operation.
`expand_index()` builds one `throttle_state` (via `throttle_state_new()`) and
shares it across all children of that single call, including nested indexes —
but `sitemap_tree()` runs **discovery** (`R/discovery.R`, `R/robots.R`) with its
own throttle state and then calls `expand_index()` **once per accepted
top-level candidate** (`sitemap_tree_expansions()` passes no `throttle_state`,
so each call builds a fresh one). Consequently two same-host indexes discovered
in one `sitemap_tree()` walk, and the discovery requests that preceded them, do
**not** pace against each other: each phase has its own host buckets.

**The concurrency scheduler MUST own a single per-operation host-bucket store,
shared across discovery and every index expansion of that operation.** This is a
requirement of the SITE-tktfxoxe implementation, not an optional refinement:
without it, "polite, host-throttled" concurrency would still let one operation
hammer a single host across phase boundaries, defeating the throttle. Concretely
the operation builds one `throttle_state` up front and threads it through
discovery, robots, and all `expand_index()` calls (the `throttle_state`
parameter already exists on `fetch_source()`, `expand_index()`, and the
discovery/robots helpers precisely so this store can be threaded in). This
unification is a behaviour change relative to today's per-phase pacing, but it
only makes pacing **stricter** (never looser) and does not affect the row/
finding/tree output, so it stays within the §0 invariant.

---

## Consequences

### Positive

- A concrete, testable contract: the concurrent path is validated by asserting
  its output is byte-identical to the sequential reference under every permuted
  completion order (see `tests/testthat/test-concurrency-contract.R`).
- Reproducible audits are preserved: rows, findings, order, and the truncation
  point are completion-order-independent by construction.
- Rate limiting is well-defined: a global worker cap and a per-host throttle
  compose without fighting, and the throttle now binds the whole operation.
- Partial failure and cancellation are deterministic and match today's findings.

### Negative / accepted trade-offs

- Committing results in catalog order means a fast-completing later child may
  wait on a slow earlier child before its rows are admitted; the scheduler holds
  completed-but-not-yet-committed leaves briefly. This bounds throughput below a
  completion-order-emit design, and is the deliberate price of determinism.
- Unifying the throttle store across phases (§6) makes discovery + expansion
  pace against one set of host buckets, so a `sitemap_tree()` run against a
  single-host site is paced more strictly than today. Accepted: stricter pacing
  is the polite direction and does not change observable output.

### Next step — implementation child

**SITE-tktfxoxe** implements this contract. It must provide a **scheduler
abstraction** that:

- owns the single per-operation host-bucket throttle store (§6) and threads it
  through discovery, robots, and all index expansions;
- drives `httr2::req_perform_parallel()` (or an equivalent bounded worker pool)
  under the global `max_active` cap (§2), layered on the per-host throttle;
- dispatches children in catalog order with budget reservation (§3) and commits
  their results in catalog order, so rows/sources/problems/tree and the
  truncation point are byte-identical to the sequential `expand_index()` path;
- captures per-child fetch failures in place as today's findings (§4) and
  cancels post-truncation in-flight fetches (§5); and
- keeps sequential mode (`max_active = 1` / concurrency off) as the reference
  path it is diffed against.

When SITE-tktfxoxe lands, it deletes the `skip()` guards in
`tests/testthat/test-concurrency-contract.R` and implements against those
assertions.
