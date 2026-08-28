# Nothing was watching — design

**Date:** 2026-08-28
**Status:** proposed, nothing implemented
**Target version:** v0.13.0 onwards
**Scope:** A forward look, not a spec. The companion document
(`networks-we-cannot-yet-describe.md`) asks whether netdiag *describes a
network* correctly. This one asks a different question: whether netdiag
is a **monitor**. Six areas, each with what it does today — verified
against commit `6dc9fe5` and against the running app on this machine on
2026-08-28, not assumed — and what it would take.

---

## Why this document exists

netdiag answers "what is wrong with my network *right now*" better than
anything else on this Mac. It answers "was anything wrong with my
network at 03:14 last night, and for how long" not at all, and it does
not say that it can't.

That second question is the one a monitoring product exists to answer.
Everything below follows from it, and from one live observation:

> The app was running with monitoring enabled and a 5-second cadence.
> Over 75 seconds — roughly fifteen samples of gateway RTT, loss, link
> state and VPN state — **zero bytes were written** anywhere under
> `~/net-diag`, `~/Library/Application Support` or `~/Library/Containers`.
> On `pkill NetdiagGUI` the monitor child died with it: *"no netdiag
> processes remain."*

Nothing here is a bug against a stated contract. `lib/monitor.sh:7-8`
says plainly that `--monitor` "never writes a log, never touches
baseline.jsonl", and `MonitorSeries.swift` opens by insisting the
monitor "is not a continuous recorder and never claimed to be." Both are
honest. The question this document raises is whether that is still the
right design for something described as an app that monitors and reports
on network events.

---

## Tier 0 — the finding that prompted this

### 0.1 The watcher has been dead for a fortnight and nothing said so

**Observed, on this machine, today.**

```
$ launchctl list | grep netdiag
-	126	com.netdiag.watcher

$ sort ~/net-diag/watcher.stderr.log | uniq -c
1386 bash: /Users/bfreeman/.../netdiag/bin/netdiag: Operation not permitted
```

Exit status 126 is "found but could not execute". The plist
(`lib/launchd.sh:17-24`) points at `$SCRIPT_PATH`, which is wherever the
`netdiag` on `PATH` resolves to — and `install.sh`, run from inside a
clone, deliberately points the symlink at that clone. Here that is
`~/bin/netdiag -> ~/Documents/AI-Workspace/netdiag/bin/netdiag`. A
launchd agent has no TCC grant for `~/Documents`, so every invocation
since the log was created on 11 August has failed identically: 1,386
consecutive failures, one every fifteen minutes, still failing as of
12:55 today.

This is not a developer-only accident. Anyone who clones netdiag into
`~/Documents` or `~/Desktop` — both ordinary choices — and installs from
the clone gets the same permanently-broken watcher with the same silent
failure.

`watcher.stdout.log` is **0 bytes** and has been since the day it was
created. The user-facing signal that the background watcher is working
is an empty file, which is indistinguishable from a healthy quiet run.

This matters beyond the immediate fix. It is the strongest possible
argument for the rest of this document: the one always-on component
netdiag ships was broken for two weeks *on its own author's machine*,
and the tool whose entire purpose is noticing silent failure did not
notice.

**Detect.** Three things, none expensive:

1. `install_watcher_run` should refuse to write a plist pointing into
   `~/Documents`, `~/Desktop` or `~/Downloads` — the three TCC-protected
   locations — and should point at the installed copy
   (`~/.local/share/netdiag`, which `install.sh` already creates) or say
   why it cannot.
2. The plist should run a wrapper that touches a heartbeat file on every
   invocation, so "the watcher last ran successfully at HH:MM" is a fact
   rather than an inference from an empty log.
3. A run should read that heartbeat and `launchctl list`'s exit status.

**Rule.** `WD-1` (warn, `netdiag`): "You installed the background
watcher, but it has not completed a run since <date> — it exits
immediately with 'Operation not permitted'. Nothing has been recorded in
the meantime." netdiag already refuses to lie about the network; it
should extend the same courtesy to itself.

**Cost.** Small, and it should be done first regardless of what else in
this document is adopted.

---

## Tier 1 — nothing durable records an event

This is the tier that decides whether netdiag is a monitor.

### 1.1 The live stream has no memory

**Today.** `--monitor` emits one JSON object per line on stdout and
writes nothing. The app holds `MonitorStream.recent`
(`MonitorStream.swift:52`) capped at `recentCapacity = 360`
(`:83`) — one hour at the 10 s cadence, thirty minutes at 5 s. Quit the
app and the hour is gone. Restart it and the Live tab starts from an
empty chart.

So every transition the monitor is uniquely placed to see — the link
going down and coming back four minutes later, the SSID changing
mid-meeting, loss climbing to 40% for ninety seconds, the VPN dropping,
the public IP changing — is observed, rendered, used to decide whether
to notify, and then discarded.

### 1.2 An "incident" is a run, not a period

**Today.** `helpers/summary.py:198` defines incidents as
`[r for r in records if r.get("diagnosis")]` — runs that had something
wrong in them. That is a sound definition of "how often did a check find
a problem", and it is the wrong shape for "how long was the internet
down".

A stored run is a snapshot with one timestamp. Nothing in the schema has
a `started_at`/`ended_at` pair. Consequently netdiag cannot compute, and
never claims to compute, any of: uptime percentage, outage count,
longest outage, mean time between failures, or "your connection dropped
six times yesterday, totalling eleven minutes" — the single sentence
most users of a network monitor actually want.

### 1.3 Nothing runs when the app is not running

**Today.** `gui/Resources/Info.plist:28` sets `LSUIElement`, so the app
is a menu-bar agent — correct. But there is no `SMAppService`
registration anywhere in `gui/Sources`, and no login-item UI in
`SettingsView.swift`. After a restart the app is not running, the
monitor is not running, and nothing is watching until the user
remembers to open it.

The only always-on path is the 15-minute `--quick` watcher, which (a) is
the timer-driven full-check pattern this project deliberately rejected,
(b) misses any outage shorter than fifteen minutes entirely, and (c) is
currently exiting 126 on every invocation (§0.1).

### The shape this wants: an event journal and one always-on recorder

Three sub-problems, one answer.

**A. `~/net-diag/events.jsonl`, append-only, one object per transition.**
Not per sample — a sample every five seconds forever is a database
problem, and the samples are not what anyone asks about. A *transition*
is: the value of some categorical fact changed, or a continuous metric
crossed a threshold from `lib/thresholds.sh` and stayed there past a
dwell.

```json
{"t":"event","kind":"link_down","at":"2026-08-28T03:14:22Z",
 "network":"mac:64:d1:54:4a:93:7f","iface":"en0"}
{"t":"event","kind":"link_up","at":"2026-08-28T03:18:47Z",
 "network":"mac:64:d1:54:4a:93:7f","iface":"en0","since":265}
{"t":"event","kind":"loss_high","at":"…","value":0.41,"rules":["G2"]}
{"t":"event","kind":"sleep","at":"…"}
```

Kinds worth recording, all already computed by `lib/monitor.sh`:
`link_down` / `link_up`, `ssid_change`, `gateway_change`, `ip_change`,
`public_ip_change`, `vpn_up` / `vpn_down`, `dns_fail` / `dns_ok`,
`loss_high` / `loss_ok`, `latency_high` / `latency_ok`,
`portal_detected`, plus `sleep` / `wake` / `monitor_start` /
`monitor_stop` boundaries.

Those last four are not decoration. `MonitorSeries` already refuses to
draw a line across a gap because "a smooth line through a two-minute
outage is *reassuring*"; an availability figure computed over a period
the Mac spent asleep tells the same lie with a number instead of a line.
**Every window must know what fraction of itself was actually observed**,
and any figure derived from a poorly-observed window must say so rather
than round it away.

**B. `--monitor --journal PATH` — opt-in, so the existing contract
holds.** A consumer piping `--monitor` into a program today gets a
process that touches no disk, and that should stay true. The journal is
a flag; the app passes it, ad-hoc users don't.

**C. One recorder, launchd-managed; the app is a viewer.** Replace the
15-minute `--quick` plist with a `KeepAlive` agent running
`--monitor --journal`, installed from `~/.local/share/netdiag`. The app,
on launch, checks for a running journal-writing monitor and *reads the
journal* rather than spawning a second monitor — two monitors would
contend for the link they are both measuring, which is the same reason
the Live tab's latency test asks the running monitor to speed up instead
of starting its own.

Login-item registration (`SMAppService.mainApp`) is then a convenience
for the notifier, not the thing recording history. Notifications still
require the app; the *record* does not.

**D. Availability becomes a judgement, so it obeys the thresholds rule.**
"Was this network reliable?" is a verdict, and the moment a number
decides it, `lib/thresholds.sh` owns the cutoff. That makes a fifth
judge alongside `diagnosis.sh`, `monitor.sh`, `history.py` and
`summary.py`, and `tests/test_thresholds.bats` must fail the build on an
inline cutoff in it exactly as it does for the other four.

New rules: `AV-1` (warn) "this network dropped N times in the last 24 h,
totalling M minutes"; `AV-2` (info) "flapping — N transitions in a short
window, each shorter than the dwell any single check would notice".

**Cost.** The largest item in this document, and the only one that
changes what netdiag *is*. Journal writer and rotation in bash; a new
`helpers/events.py` for the read side (`--events[=HOURS]`, and
availability inside `--summary`); an Incidents view in the app; one new
launchd plist; retention policy alongside the one
`tests/test_retention.bats` already covers.

---

## Tier 2 — netdiag measures the path, never the traffic on it

### 2.1 Nothing says which process is using the link

**Today.** No `nettop`, no `netstat -ib`, no byte counter of any kind
appears in `lib/`, `helpers/`, `bin/` or `gui/Sources` — verified by
grep, not assumed. netdiag can tell you the loaded RTT is 340 ms and
grade the bufferbloat D. It cannot tell you that Time Machine has been
uploading at 40 Mb/s for the last nine minutes.

That is the most common real cause of "the internet is slow" on a
perfectly healthy link, and the current report attributes it to the
router's queue — technically true, and it sends the user to buy a new
router.

**Detect.** Both sources are unprivileged; both were run on this machine
to confirm it:

```
nettop -P -x -J bytes_in,bytes_out -L 1     # per-process byte counts
netstat -ibn -I en0                          # cumulative interface counters
```

Two `netstat -ib` samples a second apart give current utilisation, which
also gives the denominator the speed test lacks: a 40 Mb/s result on a
200 Mb/s line means nothing until you know whether 160 Mb/s was already
in flight. `nettop -P` aggregates by process, which is the attribution.

**Rule.** `TR-1` (info, `local`): "Your Mac was sending 41 Mb/s while
this test ran — `backupd` accounted for most of it. The result below
measures what was left over, not what the line can do." And as a
qualifier on the bufferbloat and speed verdicts: a D grade earned while
a local process saturates the uplink is a different fact from a D grade
earned on an idle one, and today they are indistinguishable in the
report.

**Cost.** Small-to-medium, and unusually high value per line: one
parallel check, two rules, a qualifier on two existing verdicts. This is
the best ratio in the document after §0.1.

### 2.2 The Wi-Fi rate ceiling has no traffic to compare against

Related, and cheap once §2.1 exists: `tx_rate` is already collected
under sudo. Utilisation as a fraction of the negotiated rate is the
honest denominator for "is the radio the bottleneck", and it is the
measurement `SP-1` currently has to infer.

---

## Tier 3 — the network stops at the router

### 3.1 No device inventory

**Today.** `lib/arp.sh` parses `arp -an` for exactly two things:
duplicate IPs and an incomplete gateway entry. The table it already has
in memory is a list of every host that has spoken on this L2 segment
recently, and it is thrown away.

Storing the MAC set per network makes "a device you have not seen before
joined this network" a fact, and — more usefully for diagnosis — "the
number of active devices doubled since your last good speed test" an
explanation for a contended link.

**Rule.** `LAN-1` (info): device count and first-seen devices per
network. Deliberately *not* a security alert — a new MAC on a café
network is a stranger's laptop, not an intruder, and framing it as one
would be the kind of confident wrongness Tier 1 of the sibling document
is about. The gateway-MAC case is already handled better than a generic
rule could: `lib/netid.sh:94` keys network identity on it and the app's
`different-network` alert fires when it changes under a familiar SSID.

### 3.2 No local service reachability

**Today.** Every reachability check aims at the internet. Nothing asks
whether the printer, the NAS or the AirPlay target still answers. "The
network is fine but I cannot print" is a network event by any user's
definition and netdiag has no vocabulary for it.

**Detect.** `dns-sd -B _ipp._tcp` / `_smb._tcp` / `_airplay._tcp` with a
bounded timeout, plus TCP reach against whatever was seen before. The
existing `tcp_reach` machinery generalises; the work is in remembering a
per-network set of local services and in bounding a browse that has no
natural end.

**Cost.** Medium. Worth doing after Tier 2, and only if the timeout
discipline is convincing — an unbounded mDNS browse in a parallel batch
would blow the 35 s budget.

---

## Tier 4 — still open from `networks-we-cannot-yet-describe.md`

That document's Tier 1 is now largely closed: `MET-1`, `DH-3`, `SP-1`,
`ETH-1`/`ETH-2`, `WI-1` and `V6-3` all shipped, and `lib/path.sh` landed
the structural idea it ended on — enumerating what else is in the path
rather than five unrelated rules.

What remains open, unchanged, and still worth its own pass:

- **1.5 threshold profiles by link type.** Satellite, cellular and
  fixed-wireless are still judged against fibre cutoffs. Deferred
  deliberately, and it still deserves its own document — it changes the
  `lib/thresholds.sh` contract rather than adding under it.
- **2.2 iCloud Private Relay**, **2.3 encrypted DNS via profile.**
  `lib/path.sh` now *names* actors; no rule yet declares which of its
  measurements they invalidate. The facts exist and nothing consumes
  them.
- **3.1 the network changed mid-run**, **3.3 a roam mid-run**,
  **3.4 a second DHCP server.** Measurement soundness.
- **4.1 stuck on 2.4 GHz**, **4.2 DFS radar channel-switch outage.**
  Both become considerably easier with an event journal: a DFS switch is
  a 30-second outage with a distinctive shape, which is exactly the
  thing Tier 1 above is built to capture and today's 15-minute watcher
  cannot see.

---

## Tier 5 — it cannot be given to anyone

Not a diagnostic gap, but "complete" for an application includes
"another person can install it".

- **The app is self-signed.** `gui/Makefile:104-106` signs with a local
  `netdiag-dev` identity or ad-hoc. No `notarytool`, no `stapler`, no
  Developer ID anywhere in the repo. Anyone else who downloads a build
  gets Gatekeeper's "cannot be opened" dialog, and the honest advice is
  right-click → Open, which is exactly the habit a security-minded tool
  should not be teaching.
- **There is no distributable artifact at all.** `release.yml` publishes
  the CLI as a tagged GitHub Release, correctly and with three drift
  checks; the app is not in it. There is no DMG and no `make dmg`.
- **No Homebrew tap.** `README.md:99` and `:513` both list it as
  roadmap. The CLI's `curl | bash` installer is good, but `brew install`
  is what people expect and what makes updates automatic.

**Cost.** A Developer ID membership plus a notarize-and-staple step in
`release.yml` is a day's work and a recurring fee. The tap is
independent and cheaper. Both are gating for anyone but the author.

---

## Recommended order

Everything above is a candidate; this is the argued shortlist.

1. **§0.1 the watcher self-check (`WD-1`)** — a shipped component has
   been silently dead for two weeks. Nothing else in this document
   matters if the always-on path can fail this quietly. Smallest item
   here, and it is a bug, not a feature.
2. **§2.1 traffic attribution (`TR-1`)** — best value per line in the
   document. The data is unprivileged, already verified available, and
   it fixes a *wrong conclusion* the current report actively encourages
   ("your router queues badly" when the answer is "your backup is
   running").
3. **§1.1–1.3 the event journal and the always-on recorder** — the
   thing that makes netdiag a monitor. Large, and the only item that
   changes the product's shape, so it should follow the two cheap fixes
   rather than block them.
4. **§1.2's availability rules (`AV-1`, `AV-2`)** — worthless before the
   journal, near-free after it.
5. **§3.1 device inventory** — cheap, already-parsed data, modest value.
6. **§5 notarization and a tap** — gating for distribution, independent
   of everything else, and can proceed in parallel with any of it.

Deferred deliberately: **§3.2 local service reachability**, because the
timeout discipline needs designing before the feature does, and
**Tier 4's 1.5 threshold profiles**, for the reason its own document
already gives.

---

## The one structural idea

The sibling document ended on the observation that six of its entries
were one bug wearing different clothes: *netdiag assumes the default
route is the path its traffic takes.*

This one has an equivalent, and it is simpler:

> **netdiag is a camera, and it is being sold as a security system.**

Every capability here is present. The monitor sees link transitions, SSID
changes, VPN drops, loss spikes and portal appearances at five-second
resolution. The rules engine judges them against shared thresholds. The
alert engine decides which are worth interrupting someone over. All of
it works — and then the frame is discarded, because the only durable
artifacts are on-demand snapshots and an empty stdout log from a watcher
that has not executed since 11 August.

A camera answers "what is happening". A monitor answers "what happened,
when, and for how long". The distance between them is not new
measurements — netdiag already takes more than enough. It is an
append-only file, a process that survives a reboot, and the honesty to
say what fraction of a window it was actually awake for.
