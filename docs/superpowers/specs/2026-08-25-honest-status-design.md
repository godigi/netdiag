# Honest status: never claim health we did not measure

**Date:** 2026-08-25
**Status:** implemented
**Branch:** `fix/monitor-loss-quantum`

## The report

Two screenshots, taken ~4 minutes apart on a network the user describes as down:

- **Menu bar dropdown** — green check, "All good — watching", "Nothing has
  changed in 4m". Directly beneath it, `LAST 24 HOURS` lists three red
  criticals, the newest 4 m old. Every instrument cell — INTERNET, LOSS,
  ROUTER — reads `—`. A third header line reads "Last check 36m ago ·
  checking internet connection degraded".
- **Dashboard Home** — headline "Your Mac is losing 100.0% of the packets it
  sends to your router", rule G2, critical. Router and Internet rows carry a
  red ✗ next to the value "not measured". Wi-Fi signal, Under load, Packet
  size (MTU) and Clock each carry a **green** dot next to the value "not
  measured". Under "What we found", G2's critical "reboot the router" sits
  immediately above TCP-1's green "The network is up; don't worry about the
  ping numbers above."

The user's three questions — is this helpful, why is the icon green, and
shouldn't loss say 100% — have one answer between them: **the app renders
"no data" and "no problem" identically, and in two of these places it does so
because the CLI genuinely could not measure and said `ok` anyway.**

## Root causes (verified, not inferred)

### 1. The monitor cannot measure a total outage — its pings are killed before they report

macOS `ping` waits for the last reply after the final packet is sent. Measured
on this machine, against a black-holed address:

```
$ time ping -q -c 5 -i 0.2 192.0.2.1
5 packets transmitted, 0 packets received, 100.0% packet loss
                                            11.017 s total
```

0.8 s of sending, ~10 s of waiting. The monitor's probes are wrapped in
`with_timeout 6` (gateway, 10 packets) and `with_timeout 8` (internet, 20
packets). Both are therefore **SIGTERMed before `ping` prints its statistics
line**, on exactly the networks the statistics line matters on.

`_mon_loss_fold` (`lib/monitor.sh:318`) is correct in what it then does — no
parseable summary means it returns `|`, clearing the window rather than
freezing it, because "could not measure" must not read as "measured, clean".
The consequence is that a total outage yields `MON_GW_LOSS=""`,
`MON_INET_LOSS=""`, `MON_GW_RTT=""`, `MON_INET_RTT=""`.

The same `-W` bound fixes it, and the fix is measured too:

```
$ time ping -q -c 5 -i 0.2 -W 2000 192.0.2.1
5 packets transmitted, 0 packets received, 100.0% packet loss
                                             2.032 s total
```

This is why the **scanner** reported 100.0% loss in the same minute the
**monitor** reported nothing: `lib/internet_ping.sh:76` and `lib/gateway.sh:29`
use `with_timeout 15`, which clears the ~14 s worst case by one second.
The scanner is right by a one-second margin, not by design.

### 2. With every loss value empty, no rule can fire — so severity stays `ok`

`loss_at_least` and `loss_below` (`lib/common.sh:447`, `:456`) both guard on
`loss_measured` first, deliberately: a rule that needs "the gateway is provably
clean" must not fire when the gateway was never pinged. Correct in isolation,
but it means G1/G2/G3 (which need `loss_at_least`) and P1/P2 (which need
`loss_below`) are **all** false when loss is unmeasured. No rule fires,
`MON_SEVERITY` stays `ok`.

### 3. `status.measurement` reports `measured` on the strength of a failed curl

`_mon_probe_web` reads `curl -w '%{http_code}'`, which prints `000` on a
connection failure — verified:

```
$ curl -4 -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 1 --max-time 2 \
      https://192.0.2.1/generate_204
000        (exit 28)
```

`000` is non-empty, so the `elif [ -n "$code_a" ] || [ -n "$code_b" ]` branch
treats it as "both canaries answered but neither returned 204 — most commonly a
captive portal", sets `MON_WEB_OK=0`, and that non-empty value satisfies
`MON_MEASUREMENT_STATE="measured"`. The `.checking` stage added in this branch
is therefore unreachable in precisely the case it was written for.

**Together, 1 + 2 + 3 are the green check.** `link.up` true, `severity` `ok`,
`measurement` `measured` → `StageResolver.resolve` returns `.healthy` → "All
good — watching", while every cell it sits above reads `—`.

### 4. The dashboard paints green dots on rows it never measured

`RunReportView.rows` (`gui/.../RunReportView.swift:126`) sets each row's health
from `health(legacyRules, categories)`, which returns `.healthy` whenever no
rule in that category fired. It never asks whether the row has a value. So
`Under load: not measured`, `Packet size (MTU): not measured` and
`Clock: not measured` each get a green dot — a symbol that in every other row
means "checked, fine". This is the dashboard half of the same conflation.

### 5. `format()` throws away 100% loss

```swift
private func format(_ value: Double?, _ fmt: String, loss: Double?) -> String {
    guard let value else { return "not measured" }        // ← returns before reading `loss`
    ...
}
```

100% loss has no average RTT by definition, so the Router and Internet rows
print "not measured" for the one run where loss is the entire story — directly
under a headline quoting "100.0% of the packets". Red ✗ beside "not measured"
is the visible symptom.

### 6. G2 and TCP-1 contradict each other, by construction

`lib/diagnosis.sh:65` fires G1/G2/G3 on gateway loss with no ICMP-filtered
guard. `lib/diagnosis.sh:167` fires TCP-1 whenever TCP reach succeeds and
gateway loss is ≥ `THRESH_ICMP_FILTERED_LOSS_PCT`. Both conditions hold on any
ICMP-filtering network, so the report says "reboot your router" and "the
network is up; don't worry" at once, and the headline picks the former.

**Correction to an earlier draft of this document:** `lib/monitor.sh` does
*not* already suppress G1/G2/G3 on a filtered network, and the scanner is not
"behind" it. `_mon_icmp_filtered` (`lib/monitor.sh:654`) gates the *internet*
leg only — L1/L2 behind ICMP-1. The gateway leg deliberately does the
opposite, and says so at `lib/monitor.sh:588`: a monitor that withheld G2 on a
hotel network would name a different rule set than a scan one second later, so
G2 fires, `status.icmp_filtered` marks the numbers untrustworthy, and the alert
engine declines to notify.

That design succeeds at its own goal — the user is not being *notified* — but
it never addressed the report itself, which prints both conclusions with equal
weight and lets the headline pick the critical one. It also means any
ICMP-filtering network exits `2`.

### 7. The header's third line is a stale scan *reason*, presented as an event

`coordinator.scanKind` is assigned the `reason` string passed to `launch`
(`NetdiagCoordinator.swift:371`), and alert-triggered scans pass
`"checking \(def.title.lowercased())"` (`:463`). `lastCheckLine` renders it as
a badge, producing "Last check 36m ago · checking internet connection
degraded". It reads as a live event, it is 36 minutes old, and it names the
same alert the `LAST 24 HOURS` list names below — the "two separate event
spots" in the report.

## Design

The organising principle: **green is a claim, and a claim needs evidence.**
Absence of a firing rule is not evidence. Every change below either produces
the evidence, or refuses to render green without it.

### A. CLI — make an outage measurable (`lib/monitor.sh`, `lib/thresholds.sh`)

Add a bounded per-reply wait to both monitor probes so the statistics line
always prints inside `with_timeout`:

- New threshold `PING_REPLY_WAIT_MS=2000` in `lib/thresholds.sh` (the file
  `CLAUDE.md` names as the only home for a cutoff). 2000 ms, not 1000, because
  this network's own sparkline showed a 1590 ms spike; a reply slower than 2 s
  is already past every latency threshold we have.
- `_mon_probe_gateway`: `ping -q -c 10 -i 0.2 -W "$PING_REPLY_WAIT_MS"` →
  ~2 s send + ≤2 s wait, inside `with_timeout 6`.
- `_mon_probe_internet`: same flag on both targets → ~4 s + ≤2 s, inside
  `with_timeout 8`.

Audit the scanner's call sites for the same latent failure and widen where the
worst case exceeds the wrapper. `lib/bufferbloat.sh:55` (`-c 45 -i 0.2` under
`with_timeout 12` → 9 s + 10 s worst case) is over budget today and is
included; `lib/gateway.sh` and `lib/internet_ping.sh` clear their 15 s wrapper
by ~1 s and get the same `-W` for margin rather than a wider timeout.

### B. CLI — `measurement` must mean a probe succeeded

- `_mon_probe_web`: treat `000` as **no answer** (`MON_WEB_OK=""`), not as an
  intercepted response. A captive portal returns a redirect or a 200 page; a
  failed connection returns `000`. These are different facts and only one of
  them is evidence.
- `MON_MEASUREMENT_STATE="measured"` requires *positive* evidence: a gateway or
  internet RTT, a complete ping summary (loss computed from a real
  transmitted/received pair, including a 100% one), or a genuine 204. A probe
  that produced nothing leaves the state `unknown`, and `.checking` renders.

With A in place this path is rare — a real outage now measures 100% loss and
fires G2 — but it is the backstop that keeps the green card honest when a
probe is genuinely unavailable.

### C. CLI — one verdict per network condition (`lib/diagnosis.sh`)

When TCP-1's condition holds, suppress G1/G2/G3 and let TCP-1 speak alone —
**in `lib/monitor.sh` and `lib/diagnosis.sh` together, in the same commit.**

Justification: if TCP to 1.1.1.1:443 completes, packets *are* traversing the
gateway, so the gateway is forwarding and simply declining to answer pings
itself. `THRESH_ICMP_FILTERED_LOSS_PCT` is already documented as being set
"well above `LOSS_CRIT_PCT`" precisely so that this inference is safe; acting
on it is the consistent conclusion. No number is lost: TCP-1's own prose
quotes the gateway loss figure.

The `lib/monitor.sh:588` objection — that withholding G2 makes the stream
disagree with a scan — is answered by changing both engines at once. The
invariant that matters is *monitor ≡ scanner*, not *G2 always fires*. The
parity test at `tests/test_monitor.bats:107` currently encodes the latter and
is updated to assert TCP-1 **without** G2, on both sides.

`status.icmp_filtered` and the alert engine's suppression are untouched — they
solve notification, which is a different problem from what the report says.
Side effect, deliberate: an ICMP-filtering network stops exiting `2`.

Rejected alternative — demote G1/G2/G3 to `info` and keep both. Parity and
`icmp_filtered` survive, but the report still prints "reboot your router" next
to "don't worry", and a user cannot act on "reboot your router (probably
don't)".

### D. GUI — no green dot without a value (`RunReportView.swift`)

- A row whose value is unmeasured renders a neutral grey `minus.circle`, never
  `.healthy` green. The rule severity still wins when a rule *did* fire, so the
  red ✗ on Router/Internet stays.
- `format(_:_:loss:)` reads `loss` before it gives up on `value`: nil RTT with
  100% loss renders "100% loss", not "not measured".

### E. GUI — the header states current condition only (`DropdownView.swift`)

- Drop `scanKind` from `lastCheckLine`'s badge. "Last check 36m ago" is the
  fact; the reason that scan was triggered belongs to the alert that triggered
  it, and that alert is already in `LAST 24 HOURS` directly below.
- The instrument row gets the same treatment as D: with A landed, `LOSS` reads
  `100%` in red; `INTERNET` reads `no reply` in red rather than a neutral `—`,
  because a 100% loss reading is data, not its absence.

That leaves exactly one place where an event appears (`LAST 24 HOURS`) and one
place where the present condition appears (the stage card) — the "two separate
event spots" collapse to one.

## Testing

- `tests/test_monitor.bats` — a probe whose ping output is a complete
  100%-loss summary yields `loss_pct: 100`, `measurement: measured`, and G2;
  a probe whose output is empty yields `loss_pct: null` and
  `measurement: unknown`.
- `tests/test_monitor.bats` — `_mon_probe_web` with `000` from both canaries
  leaves `MON_WEB_OK` empty.
- New bats case in the diagnosis suite — TCP reach OK plus 100% gateway loss
  emits TCP-1 and **not** G2.
- `tests/test_thresholds.bats` already fails the build on an inline cutoff;
  `PING_REPLY_WAIT_MS` must be added to `lib/thresholds.sh` to pass it.
- `VerifyMode` — a `.healthy` stage is unreachable when `measurement` is
  `unknown` (already asserted in this branch) plus a new case asserting a
  100%-loss sample renders `.watching(.critical)`, not `.healthy`.
- Manual: re-run against a blocked path (`sudo pfctl` rule or an unplugged
  uplink) and confirm the dropdown shows red with `LOSS 100%`.

## Verification (run on this machine, 2026-08-25)

The regression, before and after, against a black-holed address under the
monitor's own `with_timeout 6`:

```
BEFORE (v0.10.0 flags):  summary lines: 0          ← the measurement was lost
AFTER  (-W 2000):        10 packets transmitted, 0 packets received, 100.0% packet loss
```

Driving `_mon_probe_gateway` + `_mon_rules` against `192.0.2.1` with TCP also
failing — the reported scenario end to end:

```
real 0m4.124s                                       (inside the 6 s wrapper)
MON_GW_LOSS=[100]  MON_GW_RTT=[]
RULES=[G2] SEVERITY=[critical] MEASUREMENT=[measured]
```

Previously this produced `MON_GW_LOSS=[]`, `RULES=[]`, `SEVERITY=[ok]` — the
green check in the screenshot.

- `bats tests/` — 233 passed, 1 failed. The failure,
  `netid_run's NETWORK_GROUP equals the group key history.py assigns`
  (`tests/test_history.bats:116`), **also fails on `main`** with these changes
  stashed and is unrelated to this work: it concerns network-identity grouping
  between `lib/netid.sh` and `helpers/history.py`. Not fixed here.
- `shellcheck -x bin/netdiag lib/*.sh` — clean (the CI scope; `.bats` files are
  excluded by `.github/workflows/shellcheck.yml`).
- `swift build -c release` — clean, no warnings.
- `swift run NetdiagGUI --verify` — all `StageResolver` and stage-card checks
  pass, including the new `unknown measurement → checking, not healthy`.
- `./bin/netdiag --quick --redact` — 4.0 s, healthy, exit 0.
- `./bin/netdiag --monitor --monitor-count 1` — emits `measurement: measured`,
  `icmp_filtered: false`, real loss and RTT on the live network.

**Not verified:** the red/amber dropdown against a genuine outage. Reproducing
one would mean changing routing or firewall state, which this project forbids
(`CLAUDE.md`, read-only). The state was exercised through `_mon_rules` and the
`--verify` harness instead; the pixels were not.

## Out of scope

Anything about *how* alerts dwell before notifying, the Trends/Networks views,
and the alert-toggle work already committed on this branch.
