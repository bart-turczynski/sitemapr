# ADR-011: The robots safety level, and an engine's documented meaning for a ceiling-cut robots.txt

- Status: Proposed
- Date: 2026-11-08
- Deciders: Bart Turczyński
- Related: `docs/decisions/ADR-009-per-engine-validation-profiles.md` (§2 state
  table, §3 safety precedence; **amended by this ADR on acceptance**),
  `docs/decisions/ADR-010-page-inspection.md` (§2(a), which restates the ADR-009
  §3 body-ceiling rule; **amended by this ADR on acceptance**),
  `docs/decisions/ADR-003-network-safety-policy.md` (the guard; unchanged),
  robotstxtr `design/adr/0001-safety-level-vs-engine-ruleset.md` (accepted
  2026-11-05, robotstxtr MR !83, ROBO-xdlzicrq; slice 6 is this ADR),
  robotstxtr `design/engine-profiles.md` (governed by ADR-009),
  SITE-senkdjer (this ADR).

---

## Context

robotstxtr's ADR 0001 separates two settings that ADR-009 §3 treated as one:

- the **engine ruleset**, which decides what a fetch outcome *means*;
- the **safety level** (`safety_level`, `"strict"` or `"crawler"`), which decides
  what the fetch *may do*: which redirects it follows and which addresses it
  connects to.

Its slice 2 has landed (robotstxtr MR !84, ROBO-pezlychx): every fetching entry
point takes `safety_level = "strict"`, the contract publishes
`safety_levels = c("strict", "crawler")`, and `"crawler"` is refused as
unavailable. robotstxtr admits it in slice 3, after ssrfr gains an opt-in
downgrade flag (slice 1).

robotstxtr's `design/engine-profiles.md` is governed by ADR-009, so ADR 0001
cannot change it on two points that ADR-009 §3, as amended by ADR-010 §2, rules
out in so many words (robotstxtr ADR 0001, Consequences):

1. **Safety precedence.** ADR-009 §3 maps every SSRF block, scheme restriction
   and HTTPS→HTTP downgrade rejection to `evidence_status = safety_refused`. Under
   `"crawler"`, robotstxtr follows a downgrade as an ordinary hop and records an
   address-class refusal (`loopback`, `private`, `cloud-metadata` and the rest of
   ADR 0001 §3's list) as a new value, `unreachable_local`: "not dialed: the
   address is internal, so a public crawler could not reach it either".
2. **A ceiling-cut body.** ADR-009 §3 says a reached body ceiling is "never
   `allow_all` / `disallow_all`" and that `use_rules` over a partial or unusable
   body keeps `matcher_status = not_evaluated`. Two engines document what they do
   with an oversized file. Yandex treats a file over 500 KB as open (`allow_all`).
   Google parses the first 500 KiB (512,000 bytes) and ignores the rest
   (`use_rules` on that prefix). robotstxtr already keeps the prefix of a 2xx cut at `max_bytes`
   (ROBO-ldpahknv), so it can apply either reading. The section's last sentence
   leaves "per-engine parse limits and excess-content behavior" to the
   interpretation layer, but the sentence before it rules both readings out.

The maintainer decided on 2026-11-05 that the amendment is a new sitemapr ADR,
not an edit of ADR-009 (SITE-senkdjer).

sitemapr's side is small. It calls `robots_evaluate_url_v1()` without
`safety_level` (`R/robots-facts.R`), so it always gets `"strict"`. It no longer
passes the deprecated `ssrf_guard` (sitemapr MR !117, commit 600f842). Its own
fetches, of sitemap documents, index children, inspected pages and the
robots.txt it reads for `Sitemap:` discovery (ADR-006), run sitemapr's guard
(ADR-003), which has no safety level.

---

## Decision

### 1. Safety precedence holds under `safety_level = "strict"`

ADR-009 §3's safety bullet holds unchanged for:

- every robotstxtr fetch under `safety_level = "strict"`, the default;
- every fetch sitemapr makes itself (sitemap documents, index children,
  inspected pages, the discovery robots.txt). ADR-003 governs those, ADR-010 §3 maps a page's refusal to
  `PAGE_SSRF_BLOCKED`, and neither ADR changes here.

Under robotstxtr's `safety_level = "crawler"`, robotstxtr's ADR 0001 §3 governs
instead:

- An HTTPS→HTTP redirect is an ordinary hop within the five-hop budget, not a
  refusal.
- An **address-class** refusal is `evidence_status = unreachable_local`. No
  connection is made at either level: for an internal address the safety
  level changes the label, never what the fetch dials. The one thing
  `"crawler"` reaches that `"strict"` does not is the target of a downgrade
  redirect. The guard checks that target like every other hop, so a downgrade
  to an internal address is not dialed either and is `unreachable_local`. `unreachable_local` is neither `safety_refused` nor
  `transport_fail`, and occurs under `"crawler"` only.
- A **URL-shape** refusal (`scheme`, `userinfo`, `port`, `parse`,
  `numeric-literal`, `malformed-address`) stays `safety_refused`.

`safety_refused` keeps one meaning at both levels: refused for safety, where no
crawler would refuse. It stays reserved for the three refusal classes ADR-009 §3
names. robotstxtr's published invariant "`safety_block_reason` set ⇒
`safety_refused`" widens to "⇒ `safety_refused` or `unreachable_local`", and
`transport_fail` never carries a `safety_block_reason`.

**What a ruleset may make of `unreachable_local`.** Only the meaning that engine
documents for a robots.txt it could not reach, under ADR-009 §0's provenance
gate. Today that is `context_required` for `rfc9309`, `google` and
`assumed_rfc9309`, and `documentation_gap` for `yandex` and `bing`
(engine-profiles.md §4's network row). So no address refusal becomes an allow or
a deny under `"crawler"` either. A later engine reading that does would be a
documented cell in engine-profiles.md, not a change to this ADR.

**The finding.** sitemapr's robots layer maps a row whose evidence is
`unreachable_local` to `ROBOTS_INDETERMINATE` (`info`), the code that already
covers "robots.txt could not be fetched or evaluated" (findings-contract.md),
SSRF blocks included. That is ADR-009 §6's rule: a shared code for shared
semantics. No registry row is added. robotstxtr ADR 0001's slice 6 names "the
findings mapping (ADR-003 §3, ADR-010 §3)" as where the value gets its finding,
but those two map sitemapr's own fetches (`PAGE_SSRF_BLOCKED`,
`PAGE_FETCH_FAILED`), which never produce `unreachable_local`. The robots-layer
mapping lives in findings-contract.md, so that is where the finding is decided,
and ADR-003 §3 and ADR-010 §3 are unchanged. The finding's `evidence.excerpt` carries robotstxtr's legacy
`fetch_outcome`, which stays `ssrf_blocked` at both levels (ADR 0001 §8), so the
excerpt does not say which level produced the row. That is moot while sitemapr
never passes `safety_level`; see Revisit conditions.

### 2. A ruleset may give a ceiling-cut robots.txt its engine's documented meaning

A robots.txt 2xx that robotstxtr cut at its body ceiling and kept as a prefix
(`body_truncated = TRUE`, `termination_reason = ceiling`, `stored_bytes` set)
stays `evidence_status = incomplete`. A ruleset MAY resolve such a row to a
policy verdict only when all of these hold:

- the engine **documents** what it does with a file over its size limit, and the
  cell is tagged `documented` (ADR-009 §0). No `inferred` or
  `application_choice` reading qualifies;
- the retained prefix is long enough to prove the documented condition. A prefix
  that only might cross the engine's limit does not qualify. `body_truncated =
  TRUE` means the server sent more than `stored_bytes`, so the file is strictly
  longer than its prefix;
- the cut is robotstxtr's own size ceiling (`termination_reason = ceiling`). A
  deadline, a transport failure or a safety refusal never qualifies, whatever
  was received before it;
- the cell is recorded in robotstxtr's engine-profiles.md with its threshold and
  source, and published in the engine contract's policy table.

Two readings qualify today (robotstxtr ADR 0001 §5). The thresholds are
robotstxtr's to own and are quoted here only to fix what this ADR permits:

| Ruleset | Condition | Result | robotstxtr slice |
|---|---|---|---|
| `yandex` | `stored_bytes ≥ 512000` with `body_truncated`: the file is longer than 512,000 bytes, so over "500 KB" under either reading of the unit | `allow_all` ("considered open") | 8, ROBO-arrtietl |
| `google` | `stored_bytes ≥ 512000`: the prefix holds Google's whole 500 KiB parse window | `use_rules`, matched on the first 512,000 bytes only (`matcher_status` and `url_decision` set) | 9, ROBO-ptibdnvy |

**The Google window is 512,000 bytes, not 524,288.** Google documents "500
kibibytes (KiB)", which is 500 × 1,024 = 512,000 bytes; robotstxtr's own
`R/fetch-policy.R` uses that figure for RFC 9309 §2.5's 500 KiB. robotstxtr ADR
0001 §5, slice 9's acceptance and ROBO-ptibdnvy instead write "500 KiB (524,288
bytes)", and `match_google_v1()` reads 524,288 bytes, which is 512 KiB. A rule
between bytes 512,000 and 524,288 would then give a verdict Google ignores. This
ADR permits only the documented window: a match past byte 512,000 is not a
`documented` reading. Google does not document how it parses a line that the
limit cuts in two. robotstxtr's engine-profiles.md states its handling of that
line and tags it apart from the `documented` window, before slice 9 ships. robotstxtr corrects the figure before slice 9 ships
(robotstxtr ROBO-phfbpfiy).

Every other ruleset (`rfc9309`, `assumed_rfc9309`, `bing`), and a prefix below
the threshold, keeps ADR-009 §3's rule: no `allow_all` / `disallow_all`, and
`use_rules` over the cut body keeps `matcher_status = not_evaluated`. RFC 9309
§2.5 sets a parse floor of 500 KiB, not a maximum, so a verdict from the prefix
would be one crawler's reading, not the protocol's.

This permission covers the robots interpretation layer only. ADR-010 §2's page
cap, which keeps a page body's head region, is not an engine's documented limit:
an absence read from a `partial` page body stays `unknown`, never `missing`. A
robots.txt over the ceiling that robotstxtr keeps no prefix of (`body_too_large`:
a 3xx, an unknown status, or a status mismatch) stays `incomplete` with no
verdict, whatever the ruleset, as does the 500 MB per-resource discard on
sitemapr's own fetches (ADR-003 §3).

**The finding.** No sitemapr code changes, but its output does once robotstxtr
ships slice 9. A Google `use_rules` verdict on the prefix is a matcher verdict,
so under the default Google context a robots.txt cut at the ceiling stops
reporting `ROBOTS_INDETERMINATE` for every listed URL and reports
`ROBOTS_DISALLOWED` where a rule denies one. The sitemapr release that first
supports that robotstxtr version carries a NEWS bullet for it.

A Yandex `allow_all` reached from a 2xx is not something sitemapr's
conservative trichotomy (`robots_decision_trichotomy()`) can tell from a 403's
allow-all, so it reads as undetermined and reports `ROBOTS_INDETERMINATE`, as it
does today. Conservatism declines to claim an allow; it never invents a deny.

---

## Consequences

### Positive

- robotstxtr's ADR 0001 can land in full: the `"crawler"` level (slices 3–5),
  the `ssrf_guard` removal (slice 7, ROBO-jzoptbrw) and the two cut-file readings
  (slices 8 and 9) no longer conflict with the ADR that governs
  engine-profiles.md.
- The standing rule from ADR 0001 becomes part of the shared vocabulary: the
  ruleset never changes what the fetch does, and the safety level never changes
  what an outcome means.
- Point 1 changes nothing for sitemapr's users. sitemapr runs robotstxtr at
  `"strict"`, and its own fetches have no safety level.

### Negative / accepted trade-offs

- `evidence_status` gains a value, and robotstxtr's invariant widens. A consumer
  that wants "a crawler could not reach it" has to combine `unreachable_local`
  with `transport_fail`. Accepted: the maintainer chose the finer value
  (robotstxtr ADR 0001 §3, 2026-11-05).
- An `incomplete` row can now carry a resolved policy, so `evidence_status` alone
  no longer predicts `policy_status`. A consumer has to read both, as ADR-009 §2
  already asks for every other row.
- Under `"crawler"`, sitemapr's `ROBOTS_INDETERMINATE` excerpt cannot tell an
  unreachable address from a strict refusal (both read `ssrf_blocked`).
- Under `yandex`, a cut file's `allow_all` reports `ROBOTS_INDETERMINATE` with
  the message "could not be evaluated", which is wrong for a file the engine
  documents as open. Accepted for now: telling it from a 403's allow-all needs a
  discriminator the v1 fields do not carry (`R/robots-facts.R`), and the finding
  never claims a deny.

### Changes to ADR-009 and ADR-010 on acceptance

Apply these when the maintainer accepts this ADR, and not before:

1. **ADR-009 header.** Extend the Status line with "amended <date> by ADR-011 —
   §3 safety precedence holds under robotstxtr `safety_level = "strict"`; a
   ruleset may give a ceiling-cut robots.txt its documented meaning", and add
   ADR-011 to Related.
2. **ADR-009 §2.** In the `evidence_status` list, add `unreachable_local`
   (robotstxtr, `"crawler"` only; ADR-011 §1). Under the state table, add: "A
   ceiling-cut robots.txt with `evidence_status = incomplete` may resolve as
   ADR-011 §2 permits; every other `incomplete` row takes the first row."
3. **ADR-009 §3, `incomplete` sub-bullet.** Append: "A robots.txt 2xx cut at
   the ceiling keeps its prefix and stays `incomplete`; a ruleset may still
   read that prefix as ADR-011 §2 permits."
4. **ADR-009 §3, safety bullet.** Append: "This holds under robotstxtr
   `safety_level = "strict"` and for every fetch sitemapr makes itself. Under
   `"crawler"`, a downgrade is followed and an address-class refusal is
   `unreachable_local` (ADR-011 §1)."
5. **ADR-009 §3, the "Neither is ever" sentence.** Add after it: "Both
   halves of that sentence, the `allow_all` / `disallow_all` ban and the
   `not_evaluated` matcher status, give way for a ceiling-cut robots.txt that a
   ruleset reads by its engine's documented size rule (ADR-011 §2)."
6. **ADR-010 §2(a).** After "`partial` is never `allow_all` / `disallow_all`",
   add a note that ADR-011 §2 permits a robots ruleset's documented reading of a
   ceiling-cut robots.txt, and leaves the page cap's `partial` unchanged. Add
   ADR-011 to Related.
7. **This ADR.** Status becomes "Accepted", with the date.

---

## Alternatives considered

- **Edit ADR-009 in place.** Rejected by the maintainer (2026-11-05): a new ADR
  keeps the reasoning for both points in one record, as ADR-010 did for the
  body-ceiling split.
- **Map `unreachable_local` to `transport_fail` in sitemapr's reading.**
  Rejected: robotstxtr keeps the two apart, and merging them here would lose a
  distinction the producer chose to publish. The finding already merges them
  where it matters, in `ROBOTS_INDETERMINATE`.
- **Mint a `ROBOTS_UNREACHABLE_LOCAL` code.** Rejected: the user's action is the
  same as for any robots.txt that would not fetch, and ADR-009 §6 keeps shared
  semantics on a shared code.
- **Let any ruleset read a cut prefix as `use_rules`.** Rejected: only an engine
  that documents its limit makes the prefix the whole of what it reads. For
  `rfc9309` that would turn a floor into a maximum.
- **Mark a cut file `partial` rather than `incomplete`.** Rejected: ADR-010 keeps
  `partial` for an intentional truncate-and-retain cap, whose absence reads are
  `unknown`. A Google prefix read in full is not that, and a Yandex `allow_all`
  reads nothing from the body.

---

## Revisit conditions

- sitemapr exposes `safety_level` to its own callers. The `ROBOTS_INDETERMINATE`
  excerpt then needs to say which level produced the row, for example by quoting
  `evidence_status` instead of the legacy `fetch_outcome`.
- An engine documents a different size rule, or a reading for an unreachable
  robots.txt that resolves to an allow or a deny.
- robotstxtr adds a safety level beyond `"strict"` and `"crawler"`; ADR 0001 §6
  rejects a third level today.
