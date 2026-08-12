# Watching it happen — design

**Date:** 2026-08-11
**Status:** approved, not yet implemented
**Target version:** v0.9.0
**Scope:** Spec 2 of two. Spec 1 (`docs/design/browsing-past-checks.md`)
made the *past* readable. This one makes the *present* visible.

---

## The problem

A full check takes 55 seconds and shows a spinner and a seconds counter
for all of them. The monitor takes a sample every 10 seconds and the app
keeps only the latest — an hour of measurements is in memory and nothing
draws it. And there is no way to ask one question ("how fast is it right
now?") without waiting for all 28 checks.

## Goals

1. Watch a scan happen, phase by phase, with each result landing as it
   completes.
2. A live latency chart, always running, no scan required.
3. On-demand speed and latency tests that answer one question quickly.

## Non-goals

- Any new *diagnosis*. Progress is not a verdict.
- Rewriting the run sequence. Everything here hangs off wrappers that
  already exist.

---

## Part A — a scan reports its own progress

### Why fd 3

`--json` must stay exactly one object on stdout — acceptance criterion 2,
`netdiag --json | jq .`. So progress cannot go there.

stderr alone does not work either: `launch_parallel` runs each parallel
check in a subshell that does `exec 1>"$out" 2>&1`, capturing *both*
streams into a per-check file. A parallel check writing progress to stderr
would write it into that file, where nobody is listening until the check
finishes — which is the moment progress stops being useful.

fd 3 survives that redirect untouched, and it is **completely unused**
today across `bin/netdiag` and every `lib/*.sh`. So:

```sh
exec 3>&2          # with --progress
exec 3>/dev/null   # without it, and the emitter becomes free
```

The app reads stderr and ignores lines that are not JSON, the same way it
already tolerates noise on the monitor stream.

### Where the events come from

Every check in the run sequence goes through one of two wrappers, each
already carrying the check's name — 17 `run_timed`, 11 `launch_parallel`.
Emitting from those two functions covers all 28, and covers every check
added later without anyone remembering to instrument it.

```json
{"t":"plan","phases":["iface","vpn","wifi","gateway", "…"],"mode":"full"}
{"t":"phase","name":"gateway","state":"start"}
{"t":"phase","name":"gateway","state":"done","rc":0,"ms":2043}
{"t":"phase","name":"wifi_scan","state":"skip","why":"not on wifi"}
{"t":"run","state":"done","exit":1}
```

**A plan, not a percentage.** `--json` produces nothing until the end, so
there is no quantity a percentage could be a percentage *of*. A `plan`
event names the phases this mode will attempt, and phases resolve to
`done` or `skip`. "17 of 28, testing under load" is true; a progress bar
would not be.

**The plan is kept honest by a test.** It is a declared list, and a
declared list drifts from the code the first time a check is added. A bats
test asserts that every name passed to `run_timed` or `launch_parallel`
appears in the plan for some mode, and vice versa — the same guard shape
`test_thresholds.bats` uses for cutoffs.

**Lines stay short.** Parallel subshells share fd 3, and a write to a pipe
is atomic only up to `PIPE_BUF`. Every event above is well under 512
bytes; anything that would grow (a `why` string) is truncated.

### Speed-test sub-progress

Ookla's CLI streams, and this is new — it only became true when the Ookla
binary replaced the Python `speedtest-cli` shim:

```
{"type":"ping","ping":{"jitter":0.510,"latency":28.927,"progress":0.400}}
```

`lib/speedtest.sh` translates those to fd 3 as
`{"t":"speed","stage":"download","progress":0.42,"mbps":180.3}`.

**Ookla's `testStart` line carries `interface.internalIp`, which is the
machine's public IPv6 address.** Only `type`, `progress`, `bandwidth` and
`latency` are forwarded. Nothing else from that stream reaches fd 3, a
log, or the clipboard. This is a deny-by-default translation, not a filter
on known-bad fields.

With `speedtest-cli` there is no stream, so the stage is announced and the
result arrives at the end. The UI shows an indeterminate stage rather than
inventing motion.

---

## Part B — `run_mode`, so a spot check is not a full check

Every stored record currently looks alike: a `--quick` run and a full run
are indistinguishable in history, which is why "1,913 checks" on a network
overstates what was actually measured. Records gain:

```json
"run_mode": "full" | "quick" | "speed-only" | "mtu-only" | "wifi-only"
```

`helpers/history.py` counts full and quick runs as checks; partial modes
contribute their *metrics* but not to severity or incident counts. A
speed test is a measurement, not an opinion about the network's health.

Absent on every existing record, so it decodes as unknown and those runs
keep counting exactly as they do today.

---

## Part C — the three views

**Scan progress replaces the spinner, in Status.** The phase list fills in
as it goes; each row shows its result the moment it lands. The elapsed
counter stays — it is the honest thing next to a list of unknown duration.

**A Live tab, next to Status / History / Networks.** Gateway and internet
RTT over the last hour from `MonitorStream.recent`, which already holds up
to 360 samples and is already `@Observable`. No CLI work at all.

Gaps are drawn as gaps. The monitor pauses for sleep, for display sleep,
and for the duration of every scan; a line interpolated across a pause
claims measurements that were never taken, which is the same error the
History charts already refuse to make.

**On-demand tools in the dropdown.** "Speed test" runs `--speed-only`
with live progress. "Latency test" does not shell out at all — it asks the
running monitor for a faster cadence for a bounded window and opens the
Live tab, then restores the cadence. Starting a second monitor to measure
latency would contend with the first for the link it is measuring.

`--speed-only` joins `--mtu-only` and `--wifi-only` on the existing
`FOCUS` mechanism, and its result is appended to history as a
`speed-only` record — the cheapest way to fix the sparsest metric in the
store, which currently has 7 samples across 1,986 runs.

---

## Error handling

| case | behaviour |
|---|---|
| `--progress` without a reader | fd 3 goes to stderr; if stderr is closed, writes fail silently and the run continues. Progress must never be able to fail a check. |
| a malformed progress line | the app skips lines that do not parse, as it does on the monitor stream |
| Ookla absent, `speedtest-cli` present | stage announced, no `progress` fraction, result at the end |
| neither present | the speed phase emits `skip` with a reason, as today |
| a phase in the plan that never reports | after the run's `done` event, unresolved phases render as "didn't run" rather than spinning forever |

## Testing

- every `run_timed`/`launch_parallel` name appears in a plan, and vice versa
- `--progress` off ⇒ **nothing** on fd 3 and stderr byte-identical to today
- `--json --progress` ⇒ stdout is still exactly one object
- events arrive `start` before `done` per phase; a skipped phase emits
  `skip` and never `done`
- parallel checks' events are never interleaved mid-line
- the Ookla translation forwards no field but the four named ones — a
  fixture containing `internalIp` must not produce it on fd 3
- `run_mode` present on every new record, absent-tolerant in history.py
- `--speed-only` writes a `speed-only` record and exits 0 on success

## Implementation order

1. `run_mode` in the JSON + `helpers/history.py` awareness. Independent,
   and it improves the existing history immediately.
2. fd 3 protocol: emitter, `--progress`, the two wrappers, the plan, the
   sync test, `docs/JSON-SCHEMA.md`.
3. `lib/speedtest.sh` streaming translation, with the deny-by-default
   field allowlist.
4. `--speed-only`.
5. Swift: `ScanProgress` model, incremental stderr parsing in
   `NetdiagRunner`.
6. Swift: Status tab progress list.
7. Swift: Live tab.
8. Swift: dropdown on-demand tools.

1–4 ship on their own: the CLI gains a documented, tested progress stream
whether or not the UI lands with it.
