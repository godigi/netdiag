# Browsing past checks — design

**Date:** 2026-08-11
**Status:** approved, not yet implemented
**Target version:** v0.8.0
**Scope:** one of two specs. This one covers *past* runs. Live scan
progress, the always-on latency chart and on-demand probes are Spec 2.

---

## The problem

`netdiag.app` can show you one run: the one it just did. The Networks tab
will tell you a network has 1,915 checks against it, and there is no way to
open any of them.

That is not a data problem. `~/net-diag/baseline.jsonl` holds the **complete
JSON of every run** — all 29 top-level sections, including `diagnosis` with
the CLI's own prose. 1,974 finished reports are on disk right now and none
of them is reachable from the UI.

## Goals

1. From a network, browse every check ever run on it.
2. Open one and see the full report card, identical to the Status tab.
3. See how that check compares to what is normal *for that network* —
   because "3.7 ms" means nothing without "and this network usually does
   3.2 ms".

## Non-goals

- Live scan progress, the latency chart, on-demand probes (Spec 2).
- Exporting or deleting a stored run.
- Any new *measurement*. Every number in this feature already exists.

---

## Two facts that make this small

**Stored records are the same shape as `--json`.** `output_run` writes
`baseline.jsonl` with the same `build_json` that produces `--json` output,
so Swift's existing `RunSnapshot` decoder reads a two-month-old record with
no new model code. Verified by comparing the key sets.

**The run list needs no new CLI work.** `HistoryStore` already calls
`NetdiagRunner.history(limit: 0)`, and `--history` already returns per-run
`ts`, `network_id`, `severity`, `rules`, `root_cause`, `diagnosis_count`
and `metrics`. Every row of the list view is in memory today. Only the
*detail* fetch is new.

---

## CLI changes

### 1. Runs get a stable id

`--history` currently identifies a run by `ts` alone. That is not
sufficient, and `helpers/history.py` already knows it is not: it dedups on
*(timestamp, canonical JSON)* precisely because two runs can land in the
same second. If two runs share a `ts`, `ts` cannot address either one.

Each run in `--history` output gains:

```json
"id": "2026-08-11T20:51:19Z.a3f9c1d2"
```

— the timestamp, a dot, and the first 8 hex characters of the SHA-256 of
the canonical JSON that the dedup step already computes. Byte-identical
records with the same timestamp collapse to one run, as they do today, so
an id always names exactly one run.

The separator is `.` and not `#`. `#` is unambiguous and safe in bash, but
under zsh with `EXTENDED_GLOB` — the default in many setups — an unquoted
`--show=…#…` is a glob pattern and fails with "no matches found". This CLI
has to work under both shells. Timestamps here carry no fractional seconds,
and the suffix is fixed-width hex, so ids parse by splitting on the **last**
dot, which stays correct even if timestamps gain sub-second precision later.

`id` is additive; `ts` stays.

For typing by hand, `--show` also accepts a bare timestamp. If it resolves
to exactly one run it is used; if it is ambiguous, exit `3` listing the
candidate ids rather than silently picking one.

### 2. `netdiag --show=<id>`

Emits a single JSON object on stdout and exits 0.

```json
{
  "schema": 1,
  "version": "0.8.0",
  "id": "2026-08-11T20:51:19Z.a3f9c1d2",
  "run": { "…the complete stored record, unmodified…" },
  "context": {
    "network_id": "wifi:mac=10:98:5f:91:2f:0",
    "runs_on_network": 1915,
    "position": 1843,
    "first_seen": "2026-05-30T07:55:33Z",
    "last_seen": "2026-08-11T20:51:19Z"
  },
  "comparison": {
    "metrics": {
      "gateway_rtt_ms": {
        "value": 3.745,
        "median": 3.21,
        "p10": 2.90,
        "p90": 8.40,
        "percentile": 62,
        "n": 1900,
        "direction": "lower_is_better",
        "verdict": "typical",
        "summary": "3.7 ms — typical for this network (median 3.2 ms across 1,900 checks)."
      }
    }
  }
}
```

`context` holds plain facts, no judgement. `comparison` holds the
judgement, and the app renders `summary` verbatim.

**Definitions, so none of these can be read two ways:**

- The comparison population is **every run on that network**, not a recent
  window. One rule, no extra parameter, and the window picker already lets
  the user narrow the charts if they want a recent view.
- `context.runs_on_network` counts all of them; a metric's `n` counts how
  many *recorded that metric*. They differ, and the gap is the point — 1,915
  checks but only 38 bufferbloat readings.
- `context.position` is this run's 1-based chronological index among those
  runs, oldest first.
- `percentile`, `median`, `p10` and `p90` are computed on the **raw value,
  ascending**, with no direction applied. Direction is applied when deriving
  `verdict`, and only there.

**Which metrics are compared:** exactly the ones in the `METRICS` table
`helpers/history.py` already defines. That table already carries a
`direction` per metric, which is why the CLI — and not the GUI — is the
thing that knows whether higher is better. No new table.

**`verdict` is a closed set,** so the UI can style it without parsing prose:

| verdict | meaning |
|---|---|
| `typical` | inside the normal band for this network |
| `better` | at or below the better-percentile cutoff |
| `worse` | at or above the worse-percentile cutoff |
| `best` | the best value in the sample |
| `worst` | the worst value in the sample |
| `insufficient_data` | fewer than the minimum comparable samples |
| `not_measured` | this run did not record the metric |

`not_measured` is deliberately distinct from a zero. That distinction is
the reason earlier versions of this project produced false diagnoses, and
it holds here too.

### 3. Why go through the CLI at all

Swift could read `baseline.jsonl` directly — it is on disk and JSON parsing
is not diagnostic logic. Three rules argue against it, and all three
already live in Python:

- which records are dropped because they were written with `--redact` and
  their `network.id` is masked,
- how duplicates collapse,
- that `baseline-archive.jsonl` is part of the store.

A second implementation of *"which runs exist"* is a second answer to that
question, and the two will disagree the first time retention rolls over.

---

## Where the judgement lives

`CLAUDE.md` is explicit: thresholds live in `lib/thresholds.sh`, and the GUI
holds no diagnostic logic. A percentile cutoff separating "typical" from
"worse than usual" is a **numeric cutoff that judges a network**. It
belongs in `lib/thresholds.sh` like every other one.

Two new thresholds:

```sh
THRESH_COMPARE_MIN_SAMPLES=10   # below this, verdict is insufficient_data
THRESH_COMPARE_TAIL_PCTL=10     # the outer 10% at each end is "notable"
```

One symmetric tail cutoff rather than a separate "worse" and "better"
percentile. A directional pair reads fine for latency and inverts
confusingly for throughput, where a *low* percentile is the bad one — and a
cutoff whose meaning flips per metric is a cutoff that will eventually be
applied the wrong way round. With one tail, the derivation is stated once
and holds for every metric:

```
lower tail  = percentile <= TAIL_PCTL
upper tail  = percentile >= 100 - TAIL_PCTL
lower_is_better  → lower tail is "better", upper tail is "worse"
higher_is_better → lower tail is "worse",  upper tail is "better"
```

`best` and `worst` replace `better` and `worse` when the value is the
extreme of the sample. They reach Python through the environment, the way
`helpers/history.py` is already invoked from bash — never as literals in
the Python.

**This extends the guard.** `tests/test_thresholds.bats` currently fails the
build on an inline numeric cutoff in `lib/diagnosis.sh` or `lib/monitor.sh`.
Once `helpers/history.py` starts judging, it becomes the third file the test
watches. Without that, this feature quietly reopens exactly the drift the
test exists to prevent.

---

## GUI

### Structure

A `NavigationStack` inside the existing Networks tab:

```
Networks tab
└── NetworksView            (exists — network cards)
    └── RunListView         (new — every check on one network)
        └── RunDetailView   (new — one check, full report + comparison)
```

Additive by design. It does not touch the tab bar, so Spec 2 is still free
to decide the window's overall shape without unpicking this.

### The one refactor

`DashboardWindow.swift` currently holds both the window shell and the
report card (`reportCard`, `rows`, `diagnoses`, `format`, `colour`). The
card moves to `Views/RunReportView.swift`:

```swift
struct RunReportView: View {
    let snapshot: RunSnapshot
    let comparison: RunDetail.Comparison?   // nil for a live run
}
```

so the live run and a stored run render through **one** code path. Skipping
this means two report cards, and they will drift — the stored one will lag
every change made to the live one.

### RunListView

`List` with a section per day, newest first. Each row: time, severity dot,
the CLI's `root_cause` (or "No problems found"), and chips for `rules`.
Toolbar: severity filter (All / Problems only) and the existing window
picker. `List` is lazy, so 1,915 rows cost nothing.

### RunDetailView

Header (date, network name, severity), then `RunReportView` with the
comparison, then the existing `ExpertPanel` in its disclosure. Each
report-card row gains a trailing comparison chip rendering
`comparison.metrics[key].summary` verbatim, tinted by `verdict`.

### Data flow

A new `@MainActor` `RunDetailStore` calls `NetdiagRunner.show(id:)` and
holds an LRU cache of the last 20 details. `HistoryStore` is unchanged.

---

## Error handling

| case | behaviour |
|---|---|
| id not found in store or archive | exit `3`, stderr explains; app shows "That check is no longer in your history — it may have been pruned." |
| malformed `--show` argument | exit `3` — a usage error, never `2` |
| record written with `--redact` | it has no `id` (history.py excludes it), so it is unreachable by construction. The Networks tab's coverage note already reports how many were skipped and why. |
| `comparison` unavailable (n < minimum) | object still returned; every metric carries `insufficient_data` rather than the block being absent |

Exit `2` stays reserved for a real diagnosis, so wrappers can keep telling
the two apart.

## Performance

One `--show` is a bash start plus a scan of a 5.4 MB file — expect ~300 ms.
The app shows a spinner and caches the last 20. If a measured fetch exceeds
~500 ms, revisit; do not pre-build an index before measuring.

## Testing

bats coverage for the new surface:

- `--show` happy path returns a run whose `id` round-trips from `--history`
- unknown id exits 3
- a record that lives only in `baseline-archive.jsonl` is found
- two runs sharing a timestamp get distinct ids and each resolves
- a bare timestamp resolves when unique and exits 3 listing candidates when
  not
- comparison arithmetic against a fixture: median, p10, p90, percentile
- each `verdict` value is reachable, including `insufficient_data` and
  `not_measured`
- the direction table both ways: a `lower_is_better` metric in the upper
  tail is `worse`, a `higher_is_better` metric in the upper tail is `better`
- `tests/test_thresholds.bats` fails on an inline cutoff in `history.py`

No Swift test target exists, so the UI is verified by running the app
against the real 1,974-run store.

## Docs

`docs/JSON-SCHEMA.md` gains `--show` and the `id` field on `--history`
runs. `CHANGELOG.md` gains the v0.8.0 entry. `CLAUDE.md`'s CLI surface
block gains `--show`.

---

## Implementation order

1. `--history` emits `id` — schema, bats, docs.
2. Three comparison thresholds in `lib/thresholds.sh`; extend
   `tests/test_thresholds.bats` to watch `helpers/history.py`.
3. `helpers/history.py` detail + comparison mode; `--show` in `bin/netdiag`;
   bats.
4. `docs/JSON-SCHEMA.md`.
5. Swift: `RunDetail` model, `RunDetailStore`, `NetdiagRunner.show(id:)`.
6. Swift: extract `RunReportView` — pure refactor, no behaviour change,
   verified by the live Status tab looking identical.
7. Swift: `RunListView` and navigation from `NetworksView`.
8. Swift: `RunDetailView` and comparison chips.
9. Run it against the real store; capture output for `examples/`.

Steps 1–4 are shippable on their own: the CLI gains a documented, tested
feature whether or not the UI lands in the same session.
