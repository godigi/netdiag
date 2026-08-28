# Changelog

All notable changes to `netdiag` are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — netdiag remembers what happened [event journal, `--events`]

The first item of Tier 1 from `docs/design/nothing-was-watching.md`, and
the one that decides whether netdiag is a monitor at all. It could always
say what was wrong *now*. It could not say what was wrong at 03:14, or for
how long, and it did not say that it couldn't.

The monitor already computed the answer and threw it away. `_changes()` in
`helpers/monitor_sample.py` has always diffed each cycle against the last
— VPN up and down, SSID changes, roams, public-IP changes, every rule
firing and clearing, each with a user-facing sentence — and every one of
those was rendered into a sample, used to decide whether to notify, and
then discarded. Nothing durable recorded a transition.

- **`--monitor --journal PATH`** appends one line per transition. Opt-in,
  because `--monitor`'s documented contract is a process that writes
  nothing to disk, and a consumer piping the stream into its own program
  should keep getting exactly that. A bad path fails at startup with exit
  3 rather than dropping every event for days.
- **Two kinds the journal adds to the change set**: `monitor-started`, so
  a reader can tell "no events because nothing happened" from "no events
  because nothing was running"; and `gap`, carrying the seconds the
  monitor was not looking.
- **`--events[=HOURS]`** reads it back: transitions in the window, faults
  paired into episodes with durations, and how much of the window was
  actually observed. `netdiag --events=24` now answers the question the
  design document opens with.
- **`--install-recorder`** is a KeepAlive launchd agent running that
  monitor, so the journal keeps filling across reboots. Separate from the
  watcher rather than folded into it: the watcher stores a snapshot every
  fifteen minutes, so any outage shorter than its cadence happens entirely
  between two clean runs. It refuses TCC-protected paths for the same
  reason `ND-1` exists.
- Retention mirrors `baseline.jsonl` — past `NETDIAG_KEEP_EVENTS` the
  oldest roll into `events-archive.jsonl` rather than being deleted.

**Three honest cases the episode pairing has to survive**, and does: an
episode still open at the end is measured **to the last event, never to
now**, because the recorder may have stopped an hour ago and "ongoing for
four hours" would be inventing observation; a monitor restart closes an
open episode there with `duration_is_lower_bound`, rather than letting it
span a period nobody watched; and a `gap` inside an episode is recorded as
`unobserved_s` rather than absorbed into its duration, because a four-hour
outage and a four-hour closed lid produce identical silence.

**The reader does not judge.** No uptime verdict, no outage
classification, no threshold — whether four minutes of downtime is
acceptable is a verdict, and verdicts fire from `lib/diagnosis.sh` against
`lib/thresholds.sh`. `AV-1`/`AV-2` are the next piece and are deliberately
absent here rather than smuggled into a helper.

19 new tests in `tests/test_events.bats`, including that `--monitor`
without `--journal` still writes nothing under `HOME`.


### Fixed — the app was never decoding `wan`

`RunSnapshot.init(from:)` declared `wan` in `CodingKeys`, declared it as a
property, and never assigned it. Every run therefore held the default
`WAN()`, so the NAT topology row's own conditions —
`s.wan.doubleNat.detected`, `s.wan.upnp.state == "enabled"` — could never
be true. The row could only appear because a *rule* fired, and when it did
it rendered an empty default rather than the topology the CLI had actually
measured. `suitability` was unassigned the same way.

Swift's synthesised `Decodable` conformance would have caught this; a
hand-written `init(from:)` has no check that every declared key is
consumed, and the symptom — a field holding its default — is
indistinguishable from a run where the field was genuinely absent. That
indistinguishability is why it survived.

New `tests/test_gui_decoding.bats` parses the `CodingKeys` block and the
`init(from:)` body out of the Swift source and asserts they match in both
directions, plus a planted-key check that the guard fails when it should.
A bats test rather than a `--verify` one because it is a fact about the
source text, not about runtime behaviour, which is exactly what `--verify`
cannot see here.

`suitability` is decoded only so that parity holds: no `suitability` key
is emitted anywhere in `helpers/` or `lib/`, `docs/JSON-SCHEMA.md` does
not document one, and no view reads the property. It is flagged in place
as a deletion candidate rather than quietly blessed.

### Added — netdiag notices when its own watcher stops [ND-1]

The first item from `docs/design/nothing-was-watching.md`, and a bug
before it is a feature: `com.netdiag.watcher` failed **1,386 consecutive
times over seventeen days** on this project's own machine while every
visible signal said it was fine. `launchctl list` reported exit status
126 throughout. `watcher.stderr.log` grew to 124 KB of a single repeated
`Operation not permitted`. `watcher.stdout.log` — the file the install
message tells you to `tail -f` — stayed at **0 bytes**, which is exactly
what a healthy watcher with nothing to report looks like.

The cause is TCC and it is not developer-specific. The plist runs
whatever `netdiag` on `PATH` resolves to; `install.sh` run from inside a
clone points that symlink at the clone; and a launchd agent has no
consent grant for `~/Documents`, `~/Desktop` or `~/Downloads`. Clone
netdiag into any of the three, install from it, and the watcher can
never execute. There is no grant to ask for either — the TCC prompt
would be attributed to Homebrew's bash, and "give bash Full Disk Access"
is worse advice than shipping no watcher at all.

Four changes, in the order they matter:

- **`--install-watcher` refuses those paths** and prints what to do
  instead, exiting 3 and writing no plist. A plist that exists is a
  plist launchd keeps failing to run every fifteen minutes forever.
- **A heartbeat, not just an exit status.** The plist now sets
  `NETDIAG_WATCHER=1`, and `bin/netdiag` writes
  `~/net-diag/watcher.heartbeat` on its normal exit path when it sees
  that variable. Exit status says a process started and returned;
  it cannot say a run reached the end. Nothing but the plist sets the
  variable, so an interactive run can never make a dead watcher look
  alive — and it is deliberately not written from the `EXIT` trap,
  because a run that aborted did not complete.
- **New `lib/watchdog.sh`** reads the plist, `launchctl`'s exit status
  and that heartbeat, and decides one state: `ok`, `pending`, `stale`,
  `never`, `failing` or `blocked`. One decision, read by the Report
  card row, by `ND-1` and by the app — three consumers that could
  otherwise describe the same watcher three different ways.
- **`ND-1` (warn, new `netdiag` category)** fires on the four broken
  states. `pending` — installed more recently than
  `THRESH_WATCHER_INTERVAL_S × THRESH_WATCHER_STALE_FACTOR` — stays
  quiet, because a watcher installed a minute ago has not run yet and
  accusing it then teaches users to ignore the rule.

`netdiag` is its own category rather than borrowing `baseline` because a
category names the row whose number a rule judges, and tinting the Speed
row red over a broken launchd agent is the same mistake as `G1`'s green
dot beside "35% loss", pointed the other way. The Report card row is
capped at `warn` for a related reason: `bad` rows sort above the network
itself, and nothing about the network is wrong when this fires.

The `watcher` object in `--json` is **`null` when none is installed**,
which is most runs — an object of nulls would claim "installed, and
nothing about it is known". `program` is dropped under `--redact` rather
than masked: it is an absolute path under `$HOME`, so it carries the
account name whether or not that string is anything `redact()` knows to
look for.

`THRESH_WATCHER_INTERVAL_S` also retires the inline `900` that used to
live in `lib/launchd.sh` — the cadence now decides a verdict, so it
belongs where every other number that decides a verdict lives.

21 new tests in `tests/test_watchdog.bats`, including a guard that every
state the machine can produce is one both `lib/diagnosis.sh` and
`lib/headline.sh` handle: a seventh state added in one place would
otherwise render as nothing at all, which is the exact failure this
whole rule exists to end.

### Docs — nothing was watching

New `docs/design/nothing-was-watching.md`. Nothing implemented. The
sibling document asks whether netdiag describes a network correctly;
this one asks whether netdiag is a **monitor**, and concludes that it is
a camera being sold as a security system. Every "what netdiag does
today" claim is verified against the code at `6dc9fe5` and against the
running app, not assumed.

The finding that prompted it is a live one, on this machine:
**`com.netdiag.watcher` has been failing on every invocation since 11
August and nothing said so.** `launchctl list` reports exit status 126,
`watcher.stderr.log` holds 1,386 identical `Operation not permitted`
lines, and `watcher.stdout.log` is 0 bytes — indistinguishable from a
healthy quiet run. The cause is not developer-specific: the plist points
at whatever `netdiag` on `PATH` resolves to, `install.sh` run from a
clone points that symlink at the clone, and a launchd agent has no TCC
grant for `~/Documents`. Anyone who clones there gets the same
permanently-broken, silently-broken watcher. `ND-1` is proposed so the
tool that exists to notice silent failure notices its own. (This entry
and the design document originally called it `WD-1`, which was already
taken by the WiFi-flapping rule; both now say `ND-1`.)

The rest follows from one observation: with monitoring enabled at a 5 s
cadence, 75 seconds of sampling wrote **zero bytes** anywhere on disk,
and the monitor died with the app. Both behaviours are documented and
intentional — `lib/monitor.sh:7-8` promises exactly that — but they mean
every transition the monitor is uniquely placed to see is observed,
rendered, used to decide whether to notify, and then discarded. An
"incident" in `helpers/summary.py:198` is a *run that had a diagnosis*,
not a period with a start and an end, so uptime, outage count, longest
outage and "your connection dropped six times last night, totalling
eleven minutes" are all unanswerable.

The proposal is an append-only `events.jsonl` of *transitions* (not
samples), written by an opt-in `--monitor --journal PATH` so the
existing no-disk contract still holds for other consumers; one
launchd-managed recorder that survives a reboot, with the app as a
viewer rather than a second monitor competing for the link; and
`sleep`/`wake` boundaries recorded as first-class events, because an
availability figure computed over a window the Mac spent asleep tells
the same lie `MonitorSeries` already refuses to draw as a line.
Availability becomes a fifth judge bound by the `lib/thresholds.sh`
rule.

Also catalogued: netdiag measures the path but never the traffic on it
(no `nettop`, no `netstat -ib` anywhere — so a D bufferbloat grade earned
while a backup saturates the uplink is indistinguishable from one earned
on an idle link, and the report blames the router); the `arp -an` table
is parsed for duplicates and then discarded rather than kept as a device
inventory; nothing asks whether the printer still answers; and the app
is self-signed with no notarization, no DMG and no Homebrew tap, so it
cannot be handed to anyone else.

Recommended order puts the two cheap items first — the watcher
self-check, then traffic attribution, whose data was verified available
unprivileged — ahead of the journal, which is the only item that changes
what netdiag is.

### Fixed — `--history=N` no longer mixes two populations in one object

`--limit` windowed `severity_counts`, `metric_samples` and `metric_stats`
but not `run_count`, `check_count`, `first_seen` or `last_seen`, so one
network object carried all-time counts beside windowed statistics with
nothing saying which was which. On this developer's store `--history=5`
returned `run_count: 1913` next to `severity_counts: {}` — a network with
a long, well-recorded history of problems reporting none of them — and a
consumer dividing one by the other got a problem rate off by two orders
of magnitude.

Every quantity now describes the window, so
`sum(networks[].run_count) == counts.runs` and
`sum(severity_counts.values()) == check_count` hold at every limit, and a
network with nothing in the window is no longer listed.

Identity is deliberately *not* windowed. `label`, `gateways`, `isps`,
`ssids`, `synthesized` and `bridged_from` answer "which network is this",
not "what is in this window"; recomputing them from a narrow window would
rename a network, or empty the fields the app's search matches on,
whenever the recent runs happened not to carry an ISP string.

`--show` is unaffected — it answers before `--limit` is applied and
compares a run against its network's whole population by design. The app
is unaffected too: it always asks for the unlimited form. This is for
every other consumer of a documented CLI surface.

### Fixed — the report card no longer contradicts its own numbers

An audit of everything netdiag *says* — CLI prose, the Report card, and
the app — for output an average person would misread, and for two
statements on one screen that disagree. Twenty findings; these are the
ones where the app was telling the user two different things at once.

**A category names the measurement a rule judges, not the cause it
blames.** The app tints a report-card row by the category of the rules
that fired, and that one confusion produced most of what follows.

- `G1` ("gateway packet loss with weak Wi-Fi") was catalogued under
  `wifi`, because the radio is its cause. So a Mac losing 35% of its
  packets to its own router showed **a green all-clear dot beside the
  words "35% loss"**, while the red mark went to a Wi-Fi row that, on an
  unprivileged run, had no number in it at all. `G1` is now `router`,
  matching `G2` — the same measurement, differing only in whether a weak
  signal was available to explain it.
- New optional `also` field on `--rules-catalog` (schema 2 → 3, additive)
  for a rule that genuinely judges two measurements. `G1` carries
  `"also": "wifi"` so the row with the loss figure *and* the row naming
  the cause both light up. A consumer reading only `category` is
  unaffected.
- **`router` no longer bleeds into the Internet row.** It was there to
  catch `N1`, but it also caught `G3` — whose own sentence reads "not to
  the wider internet, so your internet service itself looks fine from
  here", printed directly beneath an amber Internet row.
- **`dhcp` no longer tints the DNS row.** `DH-1` is "your address lease
  expires soon"; it was turning "6 of 6 resolvers OK" amber.
- **`ipv6`, `topology`, `vpn` and `speed` now tint something.** They
  matched no row at all, so a run firing `V6-1`, `NAT-1` or `WAN-1`
  showed an entirely green card sitting above its own amber findings. The
  card gains Packet loss, IPv6, VPN, NAT topology and Local network rows —
  the ones `lib/headline.sh` has always had and the app had dropped.
- `tests/test_rules_catalog.bats` now fails the build when any category
  has no row claiming it. The old failure was silent: a new rule family
  simply coloured nothing and the card looked healthy.

**"Not measured" was answering the wrong question.** On a `--quick` run —
the depth *both* primary buttons run — five of the card's rows read "not
measured", which an average reader takes as *we tried and failed*. The
truth is *we skipped it because you asked for the fast answer*, which the
CLI's own card has always said. Absent values now name the run's depth
("not measured (quick check)"). The Wi-Fi row says "not recorded (needs
sudo)" rather than "not measured", because on Home it sits inches below a
live radio reading taken from macOS directly — the card was flatly
denying a number the same screen was showing. That live row is now
labelled "now".

**A reading the CLI told us not to trust is no longer painted as a
measurement.** `TCP-1` and `ICMP-1` both mean real traffic is fine and
only ping is being dropped — normal on hotel and corporate networks. The
card showed the loss figure anyway, so a red "100% loss, no reply" row
sat directly above the CLI's own "your internet is fine; don't worry
about the ping numbers above", and a **green dot** sat beside "100% loss,
no reply" whenever no internet-category rule had fired. Those rows now
read `n/a — ping blocked`, and `n/a` counts as unmeasured, so it cannot
earn an all-clear dot. Same treatment for an IPv6-only network, where the
IPv4 probe cannot succeed by construction.

**Bufferbloat grade C beside a D or an F was downgraded to a warning.**
`lib/headline.sh` tested `*C*` before `*D*|*F*`, and `case` takes the
first arm that matches — so a grade F link printed a yellow "noticeable
lag under load" directly above `B2`'s red "enough to ruin voice/video
calls and multiplayer games". Two severities for one fact, one screen
apart; every C-plus-D/F pair was affected. The mapping is now a named
function (`bufferbloat_card_verdict`) checked against `B1`/`B2` for all
25 grade pairs. The app's "Under load" row also shows both legs now, not
just the gateway's — its tint already came from either.

**The headline sentence could describe an unrelated rule.**
`lib/monitor.sh` appends rules in evaluation order, not severity order, so
an `info` `VPN-1` sits ahead of a `critical` `L1`. The app took the first
rule it could look up, and a VPN user losing most of their packets got a
red "Detecting a network problem" card whose body read "A VPN is carrying
your traffic right now." The worst rule now wins, asserted in `--verify`.

Also: the headline now follows the same precedence as the dropdown's
stage card (scanning and paused were missing, so a sleeping display
showed "Monitoring paused" in one place and a stale alert in another); a
suppressed alert is cleared when monitoring stops rather than outliving
its condition; the menu bar no longer shows another network's speed test
when the current one has none recorded; the Networks tab counts *checks*
where it says "checks" (`check_count`, not every stored record — 28
against 32 on this machine) and its list membership now matches Home's;
Live's "Internet" number says it is a TCP connect time, not the ping the
dropdown shows under the same word; and the Wi-Fi location banner no
longer appears on a machine that has never had a Wi-Fi card.

### Fixed — an IPv6-only network no longer reads as no network at all

`V6-1` has covered broken IPv6 alongside working IPv4 for versions. The
mirror had no rule at all — and it was not a gap, it was a confidently
wrong critical.

netdiag's `GATEWAY` comes from `route -n get default`, which is IPv4.
So a network that is IPv6-only **by design** left it empty and the run
fell into `N1c` ("joined with no route out") or `N1` ("no network
connection at all"). Both critical, both exit 2, both false on a
network working exactly as intended and carrying the user's traffic
perfectly well. IPv6-only is normal on some mobile carriers,
universities and newer corporate deployments, and growing.

New `V6-3` heads that branch chain, which is the whole rule. It demands
IPv6 be *proven* rather than merely present — a global address is not
enough, since `V6-1` exists precisely because half-configured IPv6 is
common. A real TCP connection plus a working AAAA lookup is the
evidence; without both, an absent IPv4 gateway is a genuine outage and
`N1`/`N1c` go on saying so.

**`V6-1` is now suppressed on an IPv6-only network**, found by writing
the test rather than by reading the code: the two contradict each other
outright, and `V6-1` could still fire on ping loss alone, since
`IPV6_ONLY` already requires AAAA and TCP6 to be working. Filtered
ICMP6 is not a broken path when real traffic is getting through — the
same false alarm `ICMP-1` exists to prevent on the v4 side.

New `ipv6.only` and `ipv6.clat` in the JSON, the latter true when macOS
synthesised a 464XLAT address (`192.0.0.0/29`, RFC 7335) so IPv4-only
apps keep working.

**Not verified against a real IPv6-only network** — this machine is
IPv4-only (`scutil --nwi`: "No IPv6 states found"). The predicates are
pure and fixture-tested and the CLAT range is the RFC's, but end-to-end
behaviour on an actual NAT64 network is unconfirmed.

## [0.12.0] - 2026-08-27

### Fixed — a test that failed depending on what time it was run

`tests/test_summary.bats`'s "disconnects report the busiest single run,
never a sum" asserted that the whole report contained no `"15"` — the
sum it was guarding against. But the report also prints a `span:` line
carrying two ISO timestamps, so any run at a second, minute, hour or
day containing `15` failed against a perfectly correct implementation.
It went red in CI at `23:58:15` having passed locally minutes earlier.

Scoped to the disconnect line it actually means. Pre-existing since
`cb2142d` and unrelated to anything around it — which is the danger: a
time-dependent test that fires once in a while trains everyone to
assume the failure is the flake rather than reading it.

Two sibling assertions in the same file guard against `"999"` and were
already correct — they pass an explicit `24`-hour window precisely
because the default prints `last 999999h`, with a comment saying so.
The trap was known; this one case was missed.

### Added — one check for everything else in the path

`VPN-1` fires on the *default route*. So did netdiag's whole model of a
network: **it equated "carries my traffic" with "holds the default
route"**, and macOS stopped honouring that equation years ago. Split
tunnels, PAC proxies and NetworkExtension content filters each sit in
the datapath *without* taking the default route — so every measurement
in the report still read as a clean description of "the network" while a
different subset of it quietly stopped describing what the user's
traffic actually does.

The most expensive version of that: a corporate split-tunnel VPN
installs routes for the company's prefixes only, so netdiag reported a
perfectly healthy network while every work application was broken, and
said nothing about the one component that was failing.

New `lib/path.sh` — one check, not five features, because these are one
bug wearing several disguises. It enumerates actors and says which
measurements each undermines; it does not diagnose faults.

- **`VPN-2`** — non-default routes via `utun*`/`ipsec*`/`wg*`/`ppp*`.
  Keyed on *routes*, never on interfaces: this machine has `utun0`
  through `utun5` all UP and carrying nothing, which is why
  `lib/vpn.sh` already warned that "existence alone is meaningless".
- **`PX-1`** — a web proxy or PAC file on the service carrying the
  link. `networksetup -getwebproxy` was read nowhere before, so
  `tcp_reach`'s direct connections were testing a path real traffic
  never uses.
- **`FW-1`** — NetworkExtension content filters (Zscaler, Netskope,
  WARP, Little Snitch). Only the `network_extension` group counts; this
  machine has camera and driver extensions installed and neither is in
  the datapath.

All three are `info` and worded as "here is something else in the path",
never as an accusation — these are usually working exactly as their
owner intended, and a network tool crying wolf about corporate security
software is worse than silence. New `path_actors` block in the JSON.

**Two actors deliberately absent.** iCloud Private Relay and encrypted
DNS both belong here and neither ships, for the same reason: the
detection has never been observed in its *positive* state. Private
Relay was prototyped today and the mechanism works —
`PrivacyProxyServiceStatus` decodes out of
`com.apple.networkserviceproxy` without sudo — but only the "off" value
(`0`) has ever been seen, so the mapping is unverified and a rule firing
on a value nobody has observed is a rule nobody has tested. Recorded in
the design doc, along with the constraint that the same plist holds a
*location trail* (every network joined, by name) that netdiag must never
read.

### Fixed — a run that measured two networks no longer poisons a baseline

A full check takes ~60 s. Walk out of Wi-Fi range onto ethernet at
second 30 and the run blended two networks: a latency figure from one
link, a speed figure from another, and a single `network.id` stamped on
both. It then went into that network's history, where `BL-1` judged
every future run against a baseline describing a transition. Roaming
between two mesh APs did the same to `W1`/`W2` — one averaged RSSI
describing neither radio.

New `DQ-1` names it, and — the larger half — `lib/output.sh` now forces
`NO_BASELINE=1` and `HISTORY_APPEND=0` on such a run. Comparing a blend
against either network's history manufactures `BL-1` regressions out of
the switch itself; *storing* it poisons every future comparison.
Silently filing it under one of the two networks was what happened
before.

Detected with a cheap fingerprint (interface, gateway, SSID, BSSID)
taken at both ends of the run, ~15 ms, rather than a second `netid_run`
— which would mean re-running `iface`, `wifi` and `arp`, tens of
seconds, to answer a question four fast reads settle. An unreadable
fingerprint on either side is never a change: a warning that fires on
every run is a warning nobody reads.

### Fixed — an overnight sleep no longer reads as an overnight outage

`lib/monitor.sh` states that it "stays dumb about sleep" and leaves the
question to the GUI's `NSWorkspace` notifications. That is right for the
GUI and wrong for everyone else: `--monitor` is documented as a stream
for *any* program, so a laptop lid closed for eight hours emitted two
samples eight hours apart — both reporting a healthy link, nothing in
between — and a consumer reading that stream could not tell the silence
from a dead network.

New `gap_s` on each monitor sample: the seconds lost when the interval
between samples exceeded its scheduled cadence by the new
`THRESH_MON_GAP_FACTOR` (3), `null` otherwise. `null` rather than `0`,
because `0` would mean "no time passed" where this means "no
discontinuity". The monitor stays deliberately dumb about *why* it
stopped looking — sleep, `SIGSTOP`, a stalled probe — and reports only
that it did, and for how long.

## [0.11.0] - 2026-08-27

### Added — enough detail to diagnose the *next* Wi-Fi flapping episode

Closes the instrumentation gap left by an investigation that ended
"not reproducible". Three real episodes sit in this project's own
history — 112, 241 and 173 disassociations inside a single hour — and
none of them can be diagnosed after the fact. Not because the counting
was wrong (it was checked and is sound) but because nothing captured
what was happening while it happened, and macOS's log retention rolled
over long before anyone looked.

Three changes, none of which would have helped those three, all of
which will help the next one:

- **`WI-1`** fires when macOS withholds the SSID. The two `info` lines
  that used to say this are suppressed in a default run, so nobody saw
  them — and the *stored* consequence is what bites: every run on a
  nameless network is filed under `WiFi (SSID hidden by macOS)`, so
  runs on genuinely different networks merge into one history. All
  three episodes are filed that way, and it cannot even be confirmed
  they were on the same network.
- **`wifi.privileged`** records whether the sudo-only scrape ran.
  Without it, `rssi`/`noise`/`snr`/`channel`/`phy`/`tx_rate` coming
  back `null` is ambiguous between "measured and quiet" and "never
  measured" — and every radio field in those three stored spikes is
  `null`, which is why a weak-signal drop cannot be told apart from an
  interference drop or an AP-side problem.
- **`wifi_disconnects.events`** stores the condensed log lines behind
  the count, capped at the new `THRESH_WIFI_EVENTS_STORED` (50) and
  newest last. The report still prints five, because the 2 KB-per-line
  `airportd` dumps would drown out everything else; the record keeps
  more. Dropped entirely under `--redact` rather than scrubbed — they
  are raw log text that can carry a neighbouring BSSID or an SSID this
  run never recorded, so there is no secret to match against and no
  allow-list that makes arbitrary log text safe to publish.

`WI-1` fires on the author's own machine, so it is visible in the
re-captured `examples/sample-output.txt` — which is the point: the
condition that made three episodes undiagnosable is present right now
and was, until this release, invisible.

**`MET-1` no longer states a guess as a fact.** Its two detection
signals are of very different strength, and the first version of the
rule used one wording for both. On a home LAN that happens to use
`192.168.43.0/24` — the Android hotspot default, but also an ordinary
private range — it would have told the user "You're online through a
phone or tethered device", which is a confidently wrong claim about
their own network and exactly the failure this whole batch of work
exists to remove. New `LINK_METERED_CERTAIN` splits the two: on the
macOS service name the rule states the fact, and on the subnet
inference it says what it saw, why it skipped the test, and that
nothing is wrong if the guess was wrong. Both still skip the speed
test, because the cost of being wrong about the *skip* is small in
either direction. Surfaced as `interface.metered_certain`.

Also corrected in `docs/JSON-SCHEMA.md`: `speedtest` was documented as
`null` unless `--speed` was passed, which stopped being true in v0.6.0
when the speed test became a default. And in `CLAUDE.md`: the note
about `--redact` keeping the ISP name cited `TELEFONICA BRASIL S.A` as
what the sample shows, which has not been true since the author's ISP
changed.

### Changed — the speed test no longer spends your cellular data

**Behaviour change.** `--speed` runs by default, moves hundreds of
megabytes, and on a phone's hotspot that came out of the user's cellular
allowance — spent by a tool they ran to ask a question, without being
asked. The GUI made it sharper: its one automatic full check fires on
joining a new network, and joining a hotspot is exactly that event.

`speedtest_run` now skips on a metered link unless `--speed` was passed
explicitly, and says why rather than skipping silently. New `MET-1`
carries the reason to the Diagnosis section, where the user will
actually read it — the same principle as "a captive portal is a
diagnosis in a scan, not a log line".

`MET-1` fires whether or not the speed test was skipped, because every
*other* recommendation in the report changes on a tethered link: "reboot
your router" and "check the cable" are nonsense when the router is a
phone in someone's pocket.

Detection is honest about its limits. USB and Bluetooth tethering
announce themselves in the macOS service name and are exact. A phone's
*Wi-Fi* hotspot is an ordinary Wi-Fi network to every command-line tool
netdiag can reach — nothing in `scutil --nwi`, `ipconfig getsummary` or
`system_profiler` reports it as expensive, and `NWPathMonitor`'s
`expensive`/`constrained` flags are not exposed to any CLI — so that
case falls back to the documented default subnets (`172.20.10.0/28` for
iOS, `192.168.43.0/24` for Android). That is a heuristic: it misses a
reconfigured hotspot and would match a home network using the same
range. The asymmetry is deliberate — a false positive costs an
announced, overridable skip; a false negative costs real money.

New `interface.service` and `interface.metered` in the JSON, the latter
being why `speedtest` may be `null` in an otherwise complete run.

### Fixed — Tier 1: link facts netdiag was reporting wrongly

The first items from `docs/design/networks-we-cannot-yet-describe.md`.
Each is an existing rule firing on data that did not mean what the rule
thought, so each removes a *confident wrong answer* rather than adding a
check.

- **A self-assigned address is no longer a healthy link. [`DH-3`]**
  macOS assigns a `169.254.x.x` address when it asks a network for one
  and nothing answers — the OS reporting the *absence* of a lease. It
  arrives on the same `ifconfig` `inet` line as a real one, so
  `linkstate_parse_ifconfig_ip` returned it, `linkstate_run` set
  `LINK_UP=1` and stopped searching, and a total DHCP failure was
  recorded as a configured link. The case then fell through to `N1`,
  which told a user sitting on Wi-Fi at full signal that their Mac "has
  no network connection at all — nothing is joined": false, and a
  different fix from the real one. New `DH-3` names it — joined, no
  lease, placeholder address — and is a third state from both `N1`
  (no link) and `N1c` (real lease, no route). New
  `interface.self_assigned_ip` in the JSON, because `ip` populated
  alongside `link_up: false` otherwise reads as a contradiction.
- **A slow speed test over Wi-Fi is now attributed to the Wi-Fi.
  [`SP-1`]** The most common wrong conclusion a user draws from this
  report: "netdiag says 75 Mb/s, I pay for 500, my ISP is cheating me."
  When the Wi-Fi link negotiated 130 Mb/s, 75 is the *most* that link
  can carry. Both numbers were already being collected — `WIFI_TX` and
  `SPEEDTEST_DOWN_MBPS` — and nothing joined them; `lib/diagnosis.sh`
  did not read the speed result at all. `info` rather than `warn`,
  because nothing is broken: it reframes a number the user is about to
  misread. New `THRESH_WIFI_GOODPUT_CEILING_PCT`, set to 45 —
  deliberately below the 50–65% band real 802.11 goodput occupies,
  because the expensive mistake is a false positive that sends someone
  to buy a router they do not need. Needs sudo, since `WIFI_TX` is a
  privileged field; without it the rule stays silent rather than
  guessing.
- **A gigabit port running at 100 Mb/s is no longer invisible.
  [`ETH-1`, `ETH-2`]** Nothing in netdiag read `ifconfig media`, so a
  damaged pair in a cable — which drops a 1000BASE-T link to
  100BASE-TX — was a 10× cap visible nowhere. The speed test reported
  ~94 Mb/s and the user called their ISP about a gigabit plan being
  delivered correctly. `ETH-1` compares the negotiated rate against the
  port's advertised maximum, so it needs no threshold and stays quiet on
  an adapter that genuinely only does 100 Mb/s.
  `ETH-2` catches half duplex, but only on a port that advertises full
  duplex — a failed negotiation rather than an old adapter. Both come
  off `ifconfig -m`, whose output is a superset of the plain form, so
  `linkstate_run` gained the capability data without a second
  subprocess. New `interface.link_mbps`, `link_max_mbps` and `duplex`
  in the JSON, all null on Wi-Fi.
- **`G2` and `G3` stop blaming the router for a duplex mismatch.**
  Collisions on a half-duplex link produce heavy gateway loss, and
  `G2`'s headline advice was "reboot the router" — power-cycling a box
  that works. When `ETH-2` has fired, both rules now state the loss and
  point at the negotiation rather than offering a second, contradictory
  fix.
- **The service order's ranking now decides which unconfigured device
  is reported.** `linkstate_run` overwrote `LINK_DEVICE` on every active
  device, so when none held a lease the *last* one won. Invisible while
  the only way to reach the end of that loop was a machine with nothing
  configured at all; wrong the moment self-assigned addresses started
  arriving there. The walk now keeps the first such candidate and still
  prefers any later device holding a real lease over all of them.

### Docs — twenty networks netdiag cannot yet describe

New `docs/design/networks-we-cannot-yet-describe.md`. Nothing implemented;
it is a forward look at where the 38 rules in `--rules-catalog` answer
**confidently and wrongly**, which is worse than not answering. Every
"what netdiag does today" claim in it is verified against the code at
`31121ba` rather than assumed.

The five in Tier 1 are existing rules firing on data that does not mean
what the rule thinks:

- A `169.254.x.x` self-assigned address sets `LINK_UP=1`, because
  `linkstate_parse_ifconfig_ip` takes the first `inet` line whatever it
  is — so a total DHCP failure is recorded as a healthy, configured link.
  The one state `lib/linkstate.sh` exists to name, and it is folded into
  the healthy one.
- A worse interface can win the service order and nothing notices. The
  author's own Mac ranks two pairs of display glasses and a Thunderbolt
  bridge above Wi-Fi; `linkstate_run` reads the order only as a fallback
  and stops at the first active device.
- A gigabit port negotiated at 100 Mb/s is invisible — nothing reads
  `ifconfig media` — so a damaged cable pair reads as a slow ISP, and a
  duplex mismatch reads as `G2` "reboot your router".
- The Wi-Fi PHY rate is collected and the speed result is collected and
  no rule joins them, so a link-rate ceiling reads as a slow internet
  plan. Highest value per line in the document: the data is already in
  hand.
- Satellite, cellular and fixed-wireless are judged against terrestrial
  cutoffs. Deferred deliberately — a per-medium profile changes the
  `lib/thresholds.sh` contract rather than adding under it.

Tier 2 collects six entries that turn out to be one bug wearing different
clothes: **netdiag assumes the default route is the path its traffic
takes.** Split-tunnel VPNs, iCloud Private Relay, PAC proxies,
DoH/DoT resolvers and NetworkExtension content filters each break that
assumption and each silently invalidate a different subset of the report.
The document argues for one "what else is in the path" pass over five
unrelated rules.

One item is a trust question rather than a diagnostic one, and is
recommended first on those grounds: `--speed` runs by default, and on a
personal hotspot or iPhone USB link that spends the user's cellular
allowance without asking — including from the GUI's automatic
first-sighting scan, since joining a phone's hotspot is exactly that
event.

### Fixed — link state, captive portals, and a green dot over a red row

Four defects, all reachable from one screenshot of a Mac sitting on hotel
WiFi at full signal being told it had no network connection at all.

- **A missing default route no longer erases the interface.** `lib/iface.sh`
  derived both `INTERFACE` and `GATEWAY` from a single
  `route -n get default`, and `lib/wifi.sh`, `lib/dhcp.sh` and
  `lib/netid.sh` all gate on `INTERFACE` — so one absent route took the
  SSID, the signal, the lease and the network identity with it, and `N1`
  went on to state that the Mac "isn't joined to a WiFi network", a claim
  nothing in the run had checked and one the same report contradicted
  three lines higher. New `lib/linkstate.sh` answers association, address
  and DHCP router from `ifconfig` and `ipconfig getpacket`, none of which
  consults the routing table.
- **`N1` split into `N1` and `N1c`.** `N1` is now genuinely nothing joined.
  `N1c` is joined-and-addressed with no route out — it names the network,
  leads with the sign-in page because that is overwhelmingly the cause,
  and quotes the DHCP router as somewhere to point a browser. It claims no
  portal it has not detected: with no route the canary is unreachable, so
  there is nothing to detect and `N1c` says only what was observed.
- **The route is re-read once before it is called missing.** Six of twelve
  consecutive stored runs fired `N1` under network id `unknown` while runs
  two minutes either side were filed against a live gateway on the same
  network. A route drops for a moment during a DHCP renewal or a WiFi
  roam; a single unlucky read turned that into the most alarming verdict
  netdiag can produce plus a junk history entry. New
  `THRESH_ROUTE_RECHECK_DELAY_S`; `lib/netid.sh` also falls back to the
  DHCP-offered router so these runs stop filing under `unknown`.
- **`CP-1` fires in a scan.** It previously existed only in
  `lib/monitor.sh`; `lib/public.sh` set `CAPTIVE_PORTAL` and printed a warn
  line but never called `add_diag`, so a portal never reached
  `status.rules[]`, the exit code, or the GUI. `P1` spoke in its place —
  *"almost certainly an outage on your ISP's side, check their status page
  or call support"* — on networks whose fix was a browser. `CP-1` now
  suppresses `P1`/`P2` in the scanner and the monitor alike, and is
  critical when nothing is getting through, warn when traffic still flows.
  `docs/DIAGNOSIS-RULES.md` carried the argument for the old behaviour;
  that section has been corrected in place rather than quietly deleted.
- **Portals that answer 200 are detected.** `captive_portal_classify`
  classified on the HTTP status alone and both callers passed
  `curl -o /dev/null`, so a hotel splash page returning 200 with its login
  HTML — the common case — was reported as "No captive portal". The body
  is now compared against Apple's literal success page, the way Apple's
  own check does it, and 511 is recognised. A 200 with no body captured
  classifies `unknown` rather than `ok`: silence beats a guess.
- **"0 of 6 resolvers OK" no longer renders with a green dot.** `D1`
  required `public.ok == true`, so total resolver failure on a downed
  network fired no `dns`-category rule and `RunReportView`'s DNS row
  stayed green beside its own red value. New `D2` covers the total case.
  No Swift changed: per CLAUDE.md the GUI holds no diagnostic logic, so
  the missing piece was a rule, not a renderer.
- **New JSON fields** `interface.link_status`, `interface.link_up` and
  `interface.dhcp_router` (`docs/JSON-SCHEMA.md`). `dhcp_router` is kept
  under `--redact` like every other RFC1918 address, which also keeps
  `N1c`'s "try http://…" advice actionable in a shared report; the SSID
  `N1c` interpolates into its own prose is masked by the existing scrub.

### Fixed — 171 test assertions that could never fail

A failing `[[ ... ]]` does **not** abort a bats test on bats-core 1.14:
bats reports failures through the `ERR` trap, and bash does not run that
trap for conditional constructs. So any `[[ ]]` that was not the *last*
statement in a test body was silently a no-op — it evaluated, its result
was discarded, and the test passed regardless.

Caught when a newly written test asserting that `CP-1` fires passed
against an implementation that did not yet emit `CP-1` at all.

Every standalone `[[ ... ]]` assertion across the 18 `.bats` files — 171
of them — now carries `|| return 1`, which does abort. The ~10 that
already used `|| { echo …; return 1; }`, and the `fired()` / `not_fired()`
helper functions (a failing *function call* aborts correctly), were
already sound and are untouched. New assertions in `tests/test_parse.bats`
go through `assert_contains` / `assert_not_contains` helpers that print
expected-vs-actual on failure.

**All 583 tests still pass after the conversion**, so nothing was hiding
behind the silence — but the assertions are load-bearing from here.
Demonstrated with a paired mutation on a non-terminal assertion in
`tests/test_monitor.bats`: falsifying it reports `not ok` with the
`|| return 1` and `ok` without it, same line, same expression.

Watch for this when adding tests: `[ ]` aborts, `[[ ]]` does not.

### Added

- **`Depth.full` — the app's "run every check" depth — had zero call
  sites.** Grepping `gui/` for it found only its own two `case` arms in
  `NetdiagRunner.swift`; every scan the app could actually launch used
  `.quick` or the alert profile, and both skip the speed test
  (`lib/speedtest.sh:57`), bufferbloat (`lib/bufferbloat.sh:20`) **and**
  the MTU probe (`lib/mtu.sh:13` — a gap `--help` itself never disclosed
  until this branch's `--help` rewrite, below). Consequence: the Report
  card's "Under load", "Packet size (MTU)" and "Speed" rows read "not
  measured" on every check the app ever ran, rules B1/B2/M1/BL-1 could
  never fire, four Trends charts had no data to plot, and the dropdown's
  throughput cells carried a fallback chain for data the app never
  generated. `Depth.full` now has exactly two callers, both event-driven
  and **never scheduled**: an explicit "Full check" action on Home and in
  the dropdown, and the first join to a network, bounded once per network
  by the existing `seenNetworks` guard. A daily background full check was
  proposed and rejected — a daily speed test spends ~50–100 MB and
  saturates the link for ~60 s to fill a chart nobody asked for; monitoring
  is the always-on cheap thing, a full check is for a diagnosis moment.
  Guarded by a new `FullCheckPolicy` (`gui/.../Support/FullCheckPolicy.swift`),
  an allow-list over `ok`/`info`/`warn` so an empty or unrecognised
  severity declines too; a decline runs the lighter `.alertTriggered`
  depth instead of nothing. Also dropped the watcher plist's redundant
  `--no-bufferbloat` (`--quick` already skips it) and rewrote the Trends
  empty-state hints to name the new button rather than instruct opening a
  terminal. **Verified on this machine 2026-08-25:** the exact arguments
  `Depth.full` passes (`--json --no-gping`) produced `run_mode: full`,
  bufferbloat grade A (-5.6 ms), MTU 1500, and 15.7 Mbps down / 13.7 Mbps
  up — the three previously-blank rows, filled.
- **`netdiag --share[=ID|-]` prints one stored run as a pasteable,
  redacted report, and the app's "Copy report" button now uses it.** The
  app's only copy affordance, `ExpertPanel`'s `Button("Copy")`, copied a
  run's raw JSON **unredacted**: public IPv4 and IPv6 addresses, SSID,
  BSSID, gateway MAC and city all rode along, and `RunSnapshot.swift:502`
  had documented a "Copy shareable report" feature in a doc comment that
  did not exist. `--redact` could not be reused against a past run:
  `lib/output.sh:160-163` deliberately saves `REDACT`, forces it to `0`
  while building the record appended to history, then restores it — every
  stored run holds full detail regardless of how it was invoked — and
  `helpers/history.py:355` drops `--redact` runs from the store entirely,
  because a masked record's `network.id` is the literal
  `wifi:mac=[redacted]`, shared with every other redacted run on every
  other network. New `helpers/share.py` redacts at read time instead,
  mirroring `emit_json.py`'s `_REDACT_ENV` substring scrub field for
  field, with its exclusions intact: ISP and ASN kept (they name a
  provider, which is what makes the report worth reading), country kept
  (two letters can't be substring-replaced safely), RFC1918 addresses kept
  (identify nobody, and blanking them would gut the router rows).
  `--share` (bare) takes the newest stored run, `=ID` a specific one
  (ids come from `--history`), `=-` reads a run's JSON on stdin. An empty
  store exits 3, not 2 — 2 is reserved for a real diagnosis. Fixed a
  `pipefail` bug found while wiring the `--show` → `share.py` pipeline:
  without it, a bogus id fell through to a nonzero exit only by accident,
  and leaked the helper's own stderr alongside netdiag's own error
  message. The app's "Copy report" button now pipes the run's own bytes
  through `--share=-`, so the redaction and every word of the pasted text
  are the CLI's; `ExpertPanel`'s original button is relabelled "Copy raw
  JSON (unredacted)". `NetdiagRunner.execute` gained an optional stdin,
  written off-thread after the child starts — a report larger than the
  64 KB pipe buffer would otherwise deadlock against our own unread
  stdout. **Verified independently against a real stored record:** the
  run's public IP, city, local IP and gateway MAC are all present in the
  stored record and none reach the shared text; the ISP name survives;
  no ANSI.

### Fixed

- **The monitor could not measure an outage, so an outage looked healthy.**
  macOS `ping` waits ~10 s after its last packet before printing the
  statistics line, and that line *is* the measurement — it carries the
  transmitted/received counts `_mon_loss_fold` parses. Measured here, `ping
  -q -c 5 -i 0.2` against a black-holed address took 11.0 s. The monitor
  wraps its gateway probe in `with_timeout 6` and its internet probe in
  `with_timeout 8`, so on a dead path both were killed *before* the summary
  appeared. Loss and RTT came back empty; `loss_at_least` and `loss_below`
  both (correctly) refuse to fire on an unmeasured value, so no rule fired;
  `MON_SEVERITY` stayed `ok`. The menu bar showed a green check and "All
  good — watching" over a connection with no internet, with every instrument
  cell reading `—`. Every ping that parses a summary now passes `-W
  PING_REPLY_WAIT_MS` (2000 ms, a new constant in `lib/thresholds.sh`),
  which bounds the wait for each reply: the same probe now completes in
  2.0 s and reports `100.0% packet loss`. 2000 ms rather than 1000 because
  this tool has seen a real 1.6 s reply, and counting one of those as lost
  would trade a false "unmeasured" for a false "lossy".
- **`lib/bufferbloat.sh`'s loaded-latency probe was over its own budget for
  the same reason** — 45 packets at 0.2 s is 9 s of sending, plus the ~10 s
  tail, against `with_timeout 12`. A link that went dark mid-test produced
  no loaded reading at all. `lib/gateway.sh` and `lib/internet_ping.sh`
  cleared their 15 s wrappers by about one second and now have real margin.
- **`curl`'s `000` was being read as a reply.** `_mon_probe_web` uses `-w
  '%{http_code}'`, which prints `000` when the request never completed
  (DNS failure, refused connection, timeout). The non-204 branch treated
  that as "a canary answered, just not as expected" — a captive-portal
  verdict — and its non-empty value satisfied `status.measurement ==
  "measured"`, so the app's own "Checking connection…" card could never
  appear on the outage it was written for. `000` is now the absence of an
  answer; a redirect or a login page still reads as interception.
- **A green dot sat beside "not measured" on the dashboard.** The Report
  card set each row's health from whether a *rule* fired, and no rule fires
  about a check that never ran — so "Under load", "Packet size (MTU)" and
  "Clock" all showed the same green dot as a passing check, in a report
  whose headline was a critical. Unmeasured rows now render a neutral grey
  `minus.circle`. Only the all-clear is downgraded: a row that is unmeasured
  *because* something failed keeps its warning or critical symbol, since
  there the missing number is the finding.
- **Total packet loss was displayed as "not measured".** The Report card's
  formatter gave up on a `nil` RTT before it looked at the loss figure — but
  100% loss has no average RTT by definition, every packet that would have
  contributed one having been dropped. So the Router and Internet rows read
  "not measured" directly under a headline quoting "100.0% of the packets".
  They now read "100% loss, no reply", and the dropdown's Internet cell
  shows "no reply" in red rather than a neutral em dash. The dropdown's Loss
  cell no longer tints green unless loss is actually zero.
- **The full-check button asserted a verdict Swift has no business
  authoring, and undersold its own runtime.** Its tooltip claimed the
  connection was failing *at that instant* — a verdict authored in Swift,
  which `CLAUDE.md` reserves for the CLI — and it was false whenever
  `FullCheckPolicy` declined for want of a sample rather than for a
  critical reading. Separately, the button read "Full check · about a
  minute" while running, but a decline actually runs the lighter
  `.alertTriggered` depth (~30 s), a fact disclosed only in a hover
  tooltip nobody had reason to open mid-run. Label and tooltip are now
  state-aware and read straight from `FullCheckPolicy`, so Home and the
  dropdown cannot drift apart from each other or from what actually runs;
  the app's `--verify` harness now asserts the unsafe copy never claims a
  failure again.
- **`--summary` ignored network identity, blending every network it had
  ever seen into one distribution.** Every other surface in this tool is
  scoped per-network; `--summary` averaged, say, home and a café together
  into a distribution describing neither. It now emits one block per
  network, grouped by `helpers/history.py`'s own `group_key` — the same
  function `--history`/`--show` already use, so the two views can never
  disagree — and excludes `--redact` runs from the store for the same
  reason `history.py` already does.
- **`--summary` invented a disconnect count.** `wifi_disconnects.count`
  covers a rolling 1-hour window (`WIFI_DISCONNECT_WINDOW_HOURS=1`,
  `lib/globals.sh:42`) recomputed fresh on every run; summing that count
  across a 24-hour window counted the same overlapping disconnects once
  per run that observed them, and reported **173 disconnects** on this
  machine for a window that did not see 173 disconnects. `--summary` now
  reports the single busiest window instead of a sum, and says "no data"
  rather than a bare `0` when nothing was recorded.
- **`--summary` printed figures with no judgement attached** — the only
  user-facing surface in this tool that showed numbers without saying
  whether they were good. Each metric line now carries a `✓`/`⚠`/`×` glyph
  judged against `lib/thresholds.sh`, making `helpers/summary.py` a
  **fourth** file bound by the thresholds rule (`lib/diagnosis.sh`,
  `lib/monitor.sh`, `helpers/history.py` were already the other three) —
  the helper now refuses to start without the cutoffs rather than
  carrying a Python-side default. The glyph judges the **median**; a worse
  max is named on the same line rather than promoted to the glyph, so one
  bad minute in a month does not read as a broken network. An unmeasured
  metric takes no glyph, matching the Report card's grey `minus.circle`.
- **`--summary` truncated its own advice at 80 characters** — mid-sentence
  in every rule the CLI writes, so a reader got the numbers but not the
  fix. Advice now wraps instead of truncating. Also: `(1 samples)` now
  reads `(1 sample)`.
- **`--summary` listed one recurring fault once per wording.** The CLI
  interpolates its measurements into diagnosis prose, so the same fault
  reads differently every time it is seen — "40.0% to 8.8.8.8" and "20.0%
  to 8.8.8.8" are one problem twice — and `Counter` over the exact
  sentences listed them separately. The 80-character truncation above had
  hidden this; wrapping the prose in full made it unmissable, and on this
  machine one repeated fault filled sixteen lines and pushed the metric
  table off the screen. So the readability fix had, on its own, made the
  section less readable. Recurrence is now keyed on the rule id where the
  record carries one — that is exactly this concept, and it survives a
  rewording of the prose. Most of the store predates rule ids (2,058
  records on this machine have none), so the fallback blanks every number
  out of the sentence: the digits are precisely what differs between two
  sightings of one fault, and what remains is the fault. The newest
  phrasing is the one shown, because someone acting on it now wants the
  latest figures, not the first. On the live store this turned two
  near-duplicate entries into five distinct faults with honest counts,
  with the metric table back on screen.
- **`lib/netid.sh` and `helpers/history.py` disagreed about what one
  network is** — two defects in one nine-line block, the second hidden by
  the first. `lib/netid.sh:60` lowercased the gateway MAC with
  `${GW_MAC,,}`, a bash 4+ expansion; under macOS's system bash 3.2 that
  is a fatal runtime "bad substitution" which kills the surrounding
  subshell, so the parity test failed with "netid_group failed" rather
  than with a value mismatch — a crash wearing a disagreement's clothes.
  Uses `tr` now. With that fixed the real disagreement surfaced: the
  block ordered its preference MAC, then gateway IP, then SSID,
  contradicting both `group_key` (MAC, SSID, gateway) and this file's own
  header, which documents a gateway IP as the weakest key because
  "192.168.1.1 collides constantly". On Wi-Fi with a visible SSID but no
  gateway MAC — ARP not yet resolved, or a captive network — `netid_run`
  emitted `gw:192.168.1.1` while `group_key` derived `ssid:Cafe` from the
  very id `netid_run` had just written, so the live join this key exists
  to enable silently failed and split one network in two. The old
  fixtures never carried both an SSID and a gateway at once, so nothing
  caught it. `tests/test_history.bats` is green for the first time —
  it has carried this one failure on `main` throughout.
- **A network joined while another network's first check was running
  never got its own, ever.** The first-sighting path inserted into
  `seenNetworks` *before* calling `runScan`, and `launch()` silently
  no-ops when a scan is already in flight — so the second network was
  permanently marked seen with no scan behind it. Latent at ~10 s when
  first-join ran `--quick`; reachable in ordinary use at ~60 s now that
  it runs a full check, which is the only automatic source of that
  network's throughput, bufferbloat and MTU history. `launch` now
  reports whether it actually started, synchronously and before any
  `await`, and the network is marked seen only when it did — so a
  declined launch leaves it unseen and the next sighting retries.
- **`--share` could publish the network's name from a field it did not
  scrub.** Read-time redaction can only mask values the record carries,
  and the name is written in three places: a run whose `wifi.ssid` came
  back null still holds it in `network.label` and in the `ssid=`
  component of `network.id`, and the CLI interpolates that name into
  diagnosis prose. Probed directly, a record with `wifi.ssid` null and
  label `SecretHouse` published "Trouble on SecretHouse" verbatim. Both
  are now secret sources, with the hidden-SSID placeholder excluded so a
  generic phrase never becomes a secret. A second pass now also masks any
  address the path list cannot know about — `wan.load_balancing
  .distinct_ips` keeps its own copy of the public IP, caught today only
  because `public.ip` holds an identical string. That sweep is an
  allow-list, not `if addr.is_global`: Python reports `203.0.113.0/24` as
  `is_private`, so TEST-NET and several reserved blocks would have sailed
  through, and a redactor that keeps what it does not recognise is the
  wrong shape.

### Changed

- **`TCP-1` now suppresses `G1`, `G2` and `G3` instead of firing alongside
  them.** On any ICMP-filtering network — hotel, corporate, many ISPs — both
  fired, so the report carried "Try rebooting the router (unplug it for 30
  seconds…)" immediately above "The network is up; don't worry about the
  ping numbers above", let the critical one own the headline, and exited
  `2`. TCP reaching 1.1.1.1:443 means packets *are* crossing the gateway, so
  the gateway is forwarding and merely declining to answer pings itself;
  `THRESH_ICMP_FILTERED_LOSS_PCT` is already set well above `LOSS_CRIT_PCT`
  precisely so that inference is safe. No figure is lost — TCP-1's own text
  quotes the gateway loss. Changed in `lib/diagnosis.sh` and
  `lib/monitor.sh` in lockstep, because the invariant that matters is that
  the two engines name the same rules for the same link, not that G2 always
  fires; `status.icmp_filtered` and the alert engine's suppression are
  untouched, as they solve notification rather than what the report says.
  When TCP is *not* reaching anything, there is no evidence the gateway
  forwards at all, TCP-1 stays quiet, and G1/G2/G3 call the loss what it is.
- **The dropdown's "Last check" line no longer carries the scan's motive.**
  It rendered `coordinator.scanKind`, the `reason` string passed to
  `launch`, which for an alert-triggered scan is "checking <alert title>" —
  producing "Last check 36m ago · checking internet connection degraded"
  under a green all-clear, naming an alert that was already listed, with its
  own timestamp, in the activity list directly below. The stage card now
  states the present condition and the activity list holds the history.
- **`--help` was one 110-line wall.** Reorganized into five sections —
  Common / Sharing and output / Just one check / Modes / Advanced — with
  the everyday flags first instead of alphabetical-by-accident order.
  Kept as one `--help` rather than split into a `--help`/`--help-all`
  pair: seven test files assert flags appear in `--help`, two of them
  enforcing that it documents every flag in `CLAUDE.md`'s CLI surface and
  that every advertised capability maps to a real one — a split would
  relocate that contract rather than honour it. `--quick`'s description
  now admits it also skips the MTU probe, which it always did but `--help`
  never said; `--redact`'s notes that the ISP name is deliberately kept.
- **Test position: 502 tests before this branch, 524 after** — 22 added
  across the `--summary` fixes, `--share`, and the `FullCheckPolicy`
  follow-up, and still exactly one failure: the pre-existing
  `tests/test_history.bats:116` (tracker NET.2), which fails on `main` and
  is not fixed here.

## [0.10.0] - 2026-08-20

### Added

- **`--open=<tab>` launches the app with a dashboard tab already
  showing** (`home`, `live`, `activity`, `trends` or `networks`). The
  self-service verification hook: an automated check can screenshot any
  view without a human clicking the menu bar first. Used by the
  screenshot-based verification flow that validated the Networks tab
  redesign.
- **The monitor auto-starts a 2 s "investigation" burst the moment the
  CLI's verdict turns from ok/info to warn/critical — before an alert's
  dwell has elapsed and before any triggered scan lands.** The user's
  mental model is that the app starts pinging constantly and fast the
  instant something looks wrong, and this is what delivers it: the
  monitor restarts at the 2 s latency-test floor for 60 s, so gateway
  and internet ping arrive every 2 s rather than every 5 s while the
  problem is being confirmed. After the burst, sustained degraded (3 s)
  takes over for as long as severity stays warn/critical. Fires only on
  the genuine ok/info → warn/critical edge, not on every warn/critical
  sample, so a sustained outage gets one surge at onset and a steady 3 s
  after, not a restart every minute. Suppressed while a scan is running
  (a scan pauses the monitor and saturates the link; 2 s samples would
  measure the scan's own traffic) and while paused or stopped.
- **The app gained a `--verify` mode: a runnable test harness for the
  GUI logic that `swift test` cannot provide on this toolchain.** The
  Command Line Tools ship Swift Testing's `Testing.framework` but not
  the `xctest` host, so a test target compiles here but `swift test`
  exits 0 having run nothing — and a separate executable target cannot
  import `NetdiagGUI` because SwiftPM does not export an executable's
  symbols to importers. `--verify` runs inside the app process itself
  (full internal access, no public-izing), reachable as `swift run
  NetdiagGUI --verify` or via the bundled binary: it asserts every
  `StageResolver` severity → stage mapping and every precedence guard,
  offscreen-renders a stage-card stand-in per stage to PNG, prints
  PASS/FAIL per check and exits non-zero on any failure. Wired into
  `AppDelegate.applicationWillFinishLaunching` so it exits before the
  monitor starts or any UI appears. The `Package.swift` test target also
  gained the `-F` framework search path that lets `import Testing`
  resolve at compile time on the CLT.

- **The Networks tab is searchable, and ordered by recency.** A toolbar
  search field filters the list by the things a person actually
  recognises a network by — display name, raw label, SSID, gateway, ISP
  — with case- and diacritic-insensitive matching so "comcast" finds
  "Comcast" and "café" finds "Cafe" without typing either precisely.
  macOS hides the SSID without Location Services, so the SSID is only
  present when permission was granted at scan time; searching by the
  user-assigned rename still works without it. The list is also
  recency-ordered now (most-recently-seen first, falling back to
  run-count and then name for stable ties): you go to that tab to find
  the network you just left or the one you are on, not the one you have
  used the most over all time.

- **The Live charts snap a highlight to the point under the cursor.**
  Hovering (or dragging) anywhere along a panel's x-axis in the Live tab
  snaps a white highlight to the nearest measured point and floats its
  value and wall-clock time above it; moving off the chart clears it.
  The chart body was extracted into its own `LiveChart` so each panel
  owns its own selection state — one `@State` per panel rather than one
  shared across three charts that would cross-talk. The nearest-point
  scan is O(points) per move, which is fine because the window is
  bounded to one hour (at most a few hundred samples), so the linear
  scan is cheaper than maintaining an index would be.

- **The GUI reads the Wi-Fi network name from CoreWLAN, not the CLI.**
  TCC attributes `ipconfig getsummary` — the bundled CLI's SSID source —
  to `/usr/sbin/ipconfig` rather than this `.app`, so a Location Services
  grant to netdiag unredacts the GUI's own CoreWLAN `ssid()` call but
  leaves the CLI's reading empty or redacted. Without this, a user who
  had granted Location saw "Wi-Fi (SSID hidden by macOS)" in the
  dropdown even though the permission was live. The coordinator now
  reads the SSID via CoreWLAN once per monitor sample (never in a view
  body — it is a real syscall on an always-visible menu), adopts it as
  the current network's display name the moment it is available
  (overwriting only the ugly MAC-keyed `wifi:mac=…` placeholder, never a
  user rename or a real sudo-captured SSID), and `wifiDisplayName`
  prefers the live SSID over the CLI's redacted label. A user-assigned
  rename still wins over everything. One consequence: a network the
  user has granted Location for no longer sits in the Networks tab
  labelled `wifi:mac=…` forever — its real SSID is recorded as its
  custom name the first sample it is seen.
- **The Dock icon and Cmd-Tab slot appear only while a window is open.**
  The app ships as `LSUIElement` — no Dock icon, no switcher slot, which
  is right for an always-on menu-bar monitor. But a window opened on
  purpose should behave like a normal window while it is on screen: the
  activation policy flips to `.regular` the moment the first real
  `Window` scene (dashboard, settings, onboarding) appears and back to
  `.accessory` the instant the last one closes, so the Dock icon
  vanishes again when you are done but the menu-bar dot stays. Driven by
  `onAppear`/`onDisappear` on each window's root view rather than
  `NSWindow` notifications, which fire unreliably for SwiftUI `Window`
  scenes and left the Dock icon stuck or the switcher slot missing.
  Opening a window also activates the app so it arrives in front rather
  than behind whatever was frontmost, and so the switcher picks up a
  policy that just changed to `.regular` at runtime.

- **`netdiag --signal-scale`** — one JSON object with the four Wi-Fi
  signal bands this install's thresholds define: Excellent / Good / Fair
  / Weak, each a dBm floor, a tone, and a one-sentence explanation. Exists
  because a raw RSSI number ("-62 dBm") means nothing to almost anyone —
  a consumer now has the CLI's own word to show instead, with the dBm
  kept as a secondary detail rather than dropped. Boundaries are
  `lib/thresholds.sh`'s `THRESH_WIFI_RSSI_EXCELLENT_DBM` (new, -55),
  `THRESH_WIFI_RSSI_G1_DBM` (-70, already backing rule G1) and
  `THRESH_WIFI_RSSI_WEAK_DBM` (-75, already backing rule W1) — reused
  rather than duplicated, and read through the environment the way
  `helpers/history.py`'s `--show` reads `THRESH_COMPARE_*`. New
  `helpers/signal_scale.py`; `tests/test_signal_scale.bats` covers shape,
  band ordering, boundaries moving with the thresholds, and refusal to
  run without them. (GUI) A new `SignalScaleStore` fetches and caches it
  exactly the way `RulesCatalogStore` does; `DropdownView`'s Wi-Fi
  instrument cell and a Wi-Fi row restored to `HomeView` (see below) both
  render the CLI's label as the value and the dBm as the unit, tinted by
  the band's tone — never a Swift-authored word or a dBm comparison in
  Swift.
- **`--rules-catalog` gains a `metrics` glossary (schema 1 → 2).** A
  sibling array to `rules`: one entry per jargon term the report card
  shows (`router`, `internet`, `dns`, `wifi_signal`, `bufferbloat`,
  `mtu`, `speed`, `clock`, `packet_loss`, `latency`, `jitter`), each a
  `key`/`label`/1–2 sentence `help` explaining the term to someone who's
  never heard it — same qualitative-only discipline as `blurb`, no
  embedded numeric threshold. (GUI) `RunReportView`'s report card is
  restructured into columns — label (with a `questionmark.circle`
  `HelpHint` fed by this glossary), this run's value, the network's
  median, and a short verdict chip (`Typical`/`Better`/`Worse`/`Best`/
  `Worst`, straight from the comparison's own `verdict` token, full CLI
  sentence on hover) — instead of one long CLI sentence sitting inline on
  every row.
- **`HomeView` regains a Wi-Fi row (network name + signal).** Investigated
  where "the dashboard used to have the Wi-Fi name and signal" actually
  lived: never on `HomeView`/its tabbed-window predecessor at any commit
  — only the pre-redesign single-panel `DropdownView` (commit `9aebf71`
  and earlier) had a combined `wifiGlanceInfo` row, and that panel split
  into today's separate main window and menu-bar dropdown well before
  this branch. Not a regression, not a permission-only gate — the row
  simply never existed on Home. Restored it: name from a new
  `NetdiagCoordinator.wifiDisplayName` (the exact logic `DropdownView`'s
  `cleanNetworkName` had, moved to the coordinator so both views share
  one answer instead of two that could drift), signal from the same
  word-plus-dBm treatment as the dropdown, with the identical CoreWLAN
  fallback when the monitor's RSSI is null and Location Services is
  authorized. When it isn't authorized, the existing restriction banner
  is unchanged — no blank row underneath it.
- **`--monitor` schema 2: samples describe their own changes.** When a
  tracked field differs from the previous sample — public IP, country,
  ISP, VPN state/name, Wi-Fi network or AP, interface, or a diagnosis
  rule firing/clearing — the emitted line carries a `changes` array
  (`{id, field, from, to, summary}`) with the phrasing authored by the
  CLI, so every consumer tells the same story. Null means "not
  measured" and never counts as a change; the key is absent when
  nothing changed; rule summaries use the rules catalog's plain-English
  titles ("Router dropping packets"), not bare IDs. Gate on
  `--capabilities` `schemas.monitor >= 2`.
- **The menu-bar dropdown was rebuilt around monitoring** (GUI): an
  adaptive stage (healthy / alert / testing / paused / version-skew)
  over a fixed 4×2 instrument grid, a labeled internet-ping heartbeat
  strip with min/avg/max, and a change timeline fed by a new persistent
  event log (monitor changes + fired alerts, coalescing repeats).
  Location shows only the country flag — hover reveals the public IP,
  click copies it. One primary action remains ("Check My Connection");
  the dashboard's Activity section is now a real event list.
- **Releases are published from this file.** New
  `.github/workflows/release.yml` turns a pushed `v*` tag into a GitHub
  Release whose notes are the matching section below, extracted by a new
  `helpers/changelog_section.py`. Before it, publishing a Release was a
  step a human had to remember, and the memory failed for three months:
  eleven tags were pushed and two became Releases, so the repo's front
  page advertised v0.2.1 from May as "Latest" while `install.sh` was
  fetching v0.9.1. The workflow refuses a tag whose version disagrees with
  `bin/netdiag`'s `NETDIAG_VERSION`, or that has no section here — the two
  drifts this repo has actually suffered — and can be re-run by hand
  against an existing tag to repair its notes. `CONTRIBUTING.md` gains the
  eight-step release checklist it enforces.
- **`tests/test_changelog.bats`** — 11 structural guards on this file,
  because every defect below was invisible until someone went looking and
  none of them broke a build: a duplicate heading, a version documented
  with no tag, a heading with no link reference, a section truncated
  mid-sentence, and a version string in `bin/netdiag` with nothing here
  describing it.

### Changed

- **Counts pluralize properly.** "175 event(s)", "2.034 runs across 6
  network(s)", "1 check(s)" — the parenthesised shorthand read as
  programmer furniture everywhere it appeared (Activity, Trends, the
  Networks merge sheet, the run list). All of it now writes "175
  events", "1 check", "2 runs were skipped", singular and plural both
  grammatical.
- **The Networks list shows each network's last-seen time instead of the
  "inferred" badge.** "Inferred" says how the grouping was computed,
  which a person scanning their networks has no use for; "3h ago" says
  how stale the row is, which is the thing you actually scan the list
  for. The full date is on hover. The detail pane keeps the badge, where
  there is room for its tooltip to explain it.

- **The Networks tab was redesigned into a two-column master-detail
  layout.** The previous design was a `NavigationStack` of network cards
  — each card carried its stats inline and a "Browse Checks" link that
  pushed a second screen for the run list, which pushed a third for a
  single run. Three screens deep to read one check. The tab is now a
  list of network names on the left (clickable, searchable, arrow-key
  cycleable — just the name and a green dot for the connected one, no
  stats on the row) and everything about the selected network on the
  right: the name with rename/merge/unmerge controls, the stats row
  (checks, problems, median RTT, date range), and the checks list
  itself — inline, no navigation push. Clicking a check swaps the right
  pane to its detail with a back button; still one screen, the list
  column never moves. Opens with the current network selected by
  default. A "Problems only" checkbox replaces the segmented picker that
  lived on the pushed screen.
- **Network names now prefer the SSID and strip the ISP "via" suffix.**
  `HistoryStore.displayName` was returning the CLI's raw label, which is
  the ISP name + " via " + gateway when no SSID was captured — so the
  Networks tab titled every network "SPACEX-STARLINK via 192.168.50.1"
  rather than anything a person recognises. It now prefers a recorded
  SSID (available when Location was granted at scan time), then a
  cleaned label with the " via <gateway>" suffix stripped, so
  "SPACEX-STARLINK via 192.168.50.1" reads "SPACEX-STARLINK". The full
  label stays in the document and is still searched by.
- **The dropdown's stage card now reflects the CLI's verdict the moment a
  rule fires, not 15–25 s later when the alert's dwell elapses.** Until
  now the card read "All good — watching" for the entire dwell window of
  whichever alert would eventually fire, even though the menu-bar dot
  had already turned amber/red and the change timeline below the card
  already showed the drop — a green card over a red timeline that read
  as a bug, and the opposite of "very reactive the moment it starts
  detecting packet loss or bad Wi-Fi". The stage mapping was extracted
  into a pure `StageResolver.resolve(_:)` and given a new `.watching`
  state: `warn` severity turns the card amber with "Watching — something
  needs attention", `critical` turns it red with "Detecting a network
  problem", both carrying the CLI's own blurb for the worst firing rule
  (the same source `headline` already uses) and a tertiary line
  explaining why no alert has fired yet ("Confirming before notifying
  you…"). An already-active alert still wins over `.watching`, so once
  the dwell elapses the card carries the alert's prose as before. The
  `info` severity (VPN on, ICMP filtered) still reads healthy — it is
  not a fault. Precedence (scan > user-pause > skewed > alert > watching
  > healthy) is preserved and now unit-checked.
- **The live probe interval is shown in the heartbeat strip, and it
  updates the moment the monitor's cadence does.** Reads the sample's
  own `status.cadence_s`, so it reads "every 5s" while healthy, "every
  3s" once degraded engages, and "every 2s · test" during a latency-test
  burst — changing the instant the monitor's cadence changes rather than
  from a settings snapshot. A user watching the card turn red now sees
  the probe rate ramp up at the same time, the evidence that the app is
  investigating.
- **Default cadence lowered: fast 10 s → 5 s, degraded 5 s → 3 s.** An
  always-on monitor's healthy probe was too slow to read as "watching",
  and the degraded tier sat at the same 5 s the latency test uses —
  leaving no ramp between healthy and a full burst. The fast tier now
  probes every 5 s by default, degraded every 3 s, and the 2 s burst
  (below) is the floor for active investigation. User-tunable still;
  existing installs keep whatever they have saved.
- **The heartbeat strip dropped its redundant "internet ping · live"
  label.** The strip's shape is the headline; the label repeated what
  the strip already shows, and a min/avg/max pinned to the right read
  as a caption to nothing. The numbers now sit directly under the
  strip's left edge; only "monitoring off" remains as a label, for when
  there is no shape to read.
- **The dropdown's link-path bar, glance panel, quick-action grid, and
  contextual remedy row were retired**; their facts moved into the
  instrument grid and the alert stage. The footer regained Open
  Dashboard and Pause/Resume Monitoring after user testing.

### Fixed

- **The Trends charts' sample count carried the metric's unit** —
  "Gateway RTT · 2027 samples (ms)" read as though "ms" counted samples.
  The unit now sits on the metric's name ("Gateway RTT (ms) · 2027
  samples"), where it belongs. The two Trends charts also disagreed on
  which side their y-axis lives on (metric chart leading, incidents
  chart trailing) — both lead now.
- **A Wi-Fi name adopted from CoreWLAN showed on Home but not in the
  Networks tab.** The app renames the current network under the id the
  monitor reports, but the monitor's `network.id` is the *record* format
  (`wifi:mac=AA:BB:…`) while `--history` groups networks under
  canonicalized keys (`mac:aa:bb:…`) — so the rename landed on a key the
  Networks tab never renders, and the tab kept titling the network with
  the ISP name while Home showed the real SSID. The join is fixed at the
  source: `lib/netid.sh`'s `netid_run` now derives `NETWORK_GROUP` — the
  canonical group key, by the same MAC > gateway IP > SSID precedence
  `helpers/history.py` groups records with — and the monitor emits it as
  `network.group_id` on every sample (nullable; an older CLI omits it
  and consumers fall back to `id`). The app joins history on
  `historyJoinID` (`group_id`, falling back to `id`) everywhere a live
  sample meets stored history: the SSID adoption, the rename lookup the
  dropdown reads, the speed-test lookup, the current-network highlight
  and default selection in the Networks tab, and the seen-networks
  first-sighting trigger. A one-time migration rewrites renames and
  seen-network keys recorded under the old `wifi:mac=` spelling to the
  group key. A new bats invariant runs `netid_run` and `history.py` over
  the same five id shapes and fails the build if the two derivations
  ever drift apart — the copy in bash exists so the monitor does not
  spawn python per sample, and this test is what keeps it a copy.
- **The Networks tab did 3 full merge+sort passes on every redraw.** The
  body evaluated `mergedNetworks` (merge + sort by run-count) for the
  emptiness check, then `visibleNetworks` → `mergedNetworksByRecency`,
  which called `mergedNetworks` (merge + sort by run-count *again*) and
  re-sorted by recency — three O(networks) merge passes and two redundant
  sorts per render, over ~2,000 runs on a real store. The merge is now
  factored into `mergedNetworksUnsorted` (O(networks), no sort); both
  `mergedNetworks` and `mergedNetworksByRecency` sort from that shared
  base. The emptiness check now reads `document.networks.isEmpty` (no
  merge at all) instead of `mergedNetworks.isEmpty`, so a render with no
  search pays one merge + one sort, not three.
- **The Networks tab flashed "No networks recorded yet" during the
  initial load.** The `.task` that calls `store.load()` ran after the
  first body, so the view rendered the empty-state before the history
  arrived. `store.isLoading` existed but was never read. The tab now
  shows a spinner and "Loading networks…" while `isLoading` is true and
  the document is still empty, falling through to the real empty-state
  only once the load finishes.
- **The merge sheet listed networks in a different order than the tab.**
  The sheet used `mergedNetworks` (run-count order) while the tab used
  `mergedNetworksByRecency` (recency order), so a network near the top
  of the tab was in a different position in the sheet. Both now use
  recency order.
- **The search "no match" message showed the raw untrimmed query.**
  Typing "  comcast  " printed `No networks match   comcast  ` with the
  whitespace intact. The query is now trimmed and quoted.
- **A real internet outage read as a green dot for up to a minute.**
  fast tier pings the internet every cycle, but the TCP and public probes
  that distinguish a real outage (L1, critical) from an ICMP-filtering
  hotel network (ICMP-1, info) run on the 60 s medium and 300 s slow tiers
  and are carried over stale between refreshes. So for up to a minute into
  an outage TCP and public still read "ok" from before the drop,
  `_mon_rules` concludes ICMP-1, severity stays info, the menu-bar dot
  stays green, and no connection-lost alert fires — a manual scan was the
  only thing that forced fresh probes, which is why alerts appeared only
  after "Check My Connection" was pressed. `monitor_run` now forces a
  fresh TCP and public probe the moment the fast tier sees critical
  internet loss with a quiet gateway, so `_mon_rules` decides L1 vs
  ICMP-1 on fresh data within one cycle and degraded engages immediately.
  Gated on the tier not having already run that cycle, so a cycle that
  hit its own timers pays nothing extra, and during a sustained outage
  the forced path fires only on cycles the scheduled tiers skipped. A
  `test_monitor.bats` case guards the structural fix: the condition
  exists, keys on the shared threshold variables (not inline numbers),
  and gates the forced re-probe on the tier not having already run.
- **The paused-monitor test no longer fails in CI on a slow runner.** It
  slept a fixed 4 s, sent `SIGUSR1`, slept 3 s more and read the stream's
  last line — so on a loaded runner it read an empty file and died with a
  JSON decode error, leaving a red `bats` badge on a public README for
  three days. It now polls for the pause marker with the same `wait_until`
  helper the three tests directly above it already use, and whose comment
  documents this exact failure. The neighbouring SIGHUP test got the same
  treatment for its pre-pause wait: pausing a monitor that had not probed
  yet would have passed while asserting nothing.
- **This file had a second `## [Unreleased]` heading**, buried between
  `[0.5.2]` and `[0.5.1]`, holding notes — the one-line installer,
  `docs/JSON-SCHEMA.md`, `CONTRIBUTING.md`, CI smoke tests, the removal of
  `netdiag-prompt.md` — that had actually shipped in 0.6.0. They have been
  merged into `[0.6.0]`, where the commits that made them live. Its
  trailing "Known" note about `VPN-1` never firing went with them: 0.6.0
  is the release that fixed it.
- **`[0.9.1]`'s heading was written over the last line of the entry above
  it**, which ended mid-sentence at "and a real `--json --quick` run is".
  Restored from `3458283~1`.
- **`[0.9.1]` was missing half of what it shipped.** `--version`,
  `--capabilities`, `--rules-catalog`, `run_id` and `metric_stats` were
  all committed before `3458283` and are therefore inside the `v0.9.1`
  tag, but sat under `[Unreleased]` because that release was tagged
  without rolling the section over. Moved into `[0.9.1]`, verified by
  `git merge-base --is-ancestor` against every entry rather than by
  reading dates. Left where they were, the next release would have
  claimed them as its own.
- **Four documented versions had no tag at all** — 0.1.0, 0.4.1, 0.5.0
  and 0.9.1 — so their entries described something a reader could not
  check out, and `install.sh` fetched a v0.9.1 that `git` had never heard
  of. All four are now annotated tags on their release commits, dated to
  match. Every heading also gained the Keep a Changelog link reference it
  was missing, so each version links to its own diff.

## [0.9.1] - 2026-08-15

Adds GitHub auto-update checks to the GUI, new layperson-tailored
diagnostics for DNS and IPv6, router gateway admin quick access, and speed
test retention — plus the four CLI surfaces a GUI needs before it can
trust the binary it is talking to: `--version`, `--capabilities`,
`--rules-catalog`, and `run_id`/`metric_stats` in the JSON.

Those CLI entries were documented under `[Unreleased]` until well after
this release shipped, because 0.9.1 was tagged without rolling the section
over. They are recorded here, where the commits actually are: every one of
them is contained in `v0.9.1`. `.github/workflows/release.yml` now refuses
a tag whose notes are still sitting under `[Unreleased]`, so the same
omission fails the build rather than surviving into the docs.

### Added

- **GitHub Auto-Update Capability**: Daily automated background update checks against `godigi/netdiag` releases and in-app updating/relaunching from Settings.
- **`D3` Diagnostic**: Slow DNS resolver latency warning with actionable recommendation for Cloudflare (1.1.1.1) / Google (8.8.8.8).
- **`D4` Diagnostic**: DNS NXDOMAIN hijacking and ISP search redirection detection.
- **`V6-2` Diagnostic**: Dead IPv6 DNS resolver fallback delay warning.
- **`double-nat` Alert**: Plain-English alert and recommendation for chained home routers (Double NAT).
- **Router Gateway Admin Access**: Clickable router gateway IP in dropdown to instantly open the router admin page.
- **Speed Test Retention**: Retains speed test metrics permanently in memory and dropdown view across scans.

- **`netdiag --version`** — prints `netdiag VERSION` and exits 0.
- **`netdiag --capabilities`** — a JSON handshake describing this
  install: per-mode schema numbers, a `features` list, and which
  optional dependencies (`jq`, `mtr`, `gping`, `speedtest`/`speedtest-cli`)
  are actually on `PATH`. Lets a GUI detect what its CLI supports before
  it relies on a feature, instead of parsing `--version`'s semver and
  guessing.
- **`netdiag --rules-catalog`** — one JSON object cataloguing every rule
  the diagnosis engine and the monitor can emit: `title`, `category`,
  descriptive `severity`, `scope` (`scan` / `monitor` / `both`), a
  plain-English `blurb`, and a `doc` anchor into
  `docs/DIAGNOSIS-RULES.md`. The GUI holds no diagnostic logic, so the
  plain-English layer next to a rule-ID chip has to come from the CLI —
  this is that source. `tests/test_rules_catalog.bats` diffs the catalog
  against every `add_diag`/`_mon_add_rule` call site so the two can't
  drift apart silently.
  - `--capabilities`'s `schemas` now also reports `rules_catalog`, the one
    divergence from its own "never the odd one out" docstring — every
    other output that embeds a `"schema"` field was already listed.
- **`--json` gains `run_id`** — the same `"<timestamp>.<8 hex>"` id
  `netdiag --history`/`--show` will later derive for this exact run,
  computed at run time so a GUI can deep-link to "the check that just
  ran" from an alert without waiting for the next `--history` poll.
  `lib/output.sh` computes it by importing `helpers/history.py`'s own
  `canonical()`/`run_id()` rather than reimplementing the hash, from the
  precise record about to be appended — so the two can never disagree —
  and the record written to `baseline.jsonl` is unchanged: the build that
  gets stored never carries a `run_id` key at all, not even `null`,
  because a key holding a run's id can't also sit inside the bytes that
  id is hashed from. `null` when nothing was appended this run
  (`--no-baseline`, `--mtu-only`, `--wifi-only`) and, for a different
  reason, under `--redact`: the record really is stored — the private,
  unredacted build always is — but the id is a pointer back into that
  private copy, and the "shareable" rendition shouldn't carry a working
  key into data it otherwise took pains to mask.
- **`--history` gains `metric_stats`** on every network: `{median, p10,
  p90}` for each of the 13 charted metrics, over the exact population
  `metric_samples` already counts. Reuses `--show`'s own
  `quantile()`/median arithmetic rather than a second implementation, and
  carries no `value`, `direction` or `verdict` — facts about the network,
  not a judgement of any one run, which stays `--show`'s job. Below
  `THRESH_COMPARE_MIN_SAMPLES` the whole per-metric block is `null` rather
  than a partial object, mirroring `--show`'s `insufficient_data`; a plain
  `netdiag --history` now needs `THRESH_COMPARE_MIN_SAMPLES`/
  `THRESH_COMPARE_TAIL_PCTL` in the environment for this reason, the same
  way `--show` always has.

### Changed

- **jq is no longer required for the speed test.** The ~10 `jq -r` calls
  that parsed Ookla's and `speedtest-cli`'s final result JSON are now one
  call to `helpers/speedtest_result.py`, a stdlib-only parser that reads
  the result object on stdin and writes `down_mbps`/`up_mbps`/
  `latency_ms`/`jitter_ms`/`server` as one tab-separated line — same
  deny-by-default discipline the fd-3 progress translation already used
  for the same reason: an Ookla result carries `interface.internalIp`
  (a dual-stack Mac's public IPv6 address), `externalIp`, `macAddr` and a
  `result.url`, none of which may reach stdout. `speedtest_will_run()`
  and `speedtest_run()` no longer gate on `command -v jq` at all, so a
  machine with only bash 5 and python3 now gets a real speed test instead
  of a "brew install jq" hint. `lib/headline.sh`'s Report card drops the
  matching hint row for the same reason. `mtr`'s sudo-only per-hop view
  and Tailscale's VPN name are the only things jq still touches; both are
  optional enhancers, not defaults, and are unchanged.
  - New `tests/test_speedtest_parse.bats` (17 cases) drives the helper
    against fixtures for both flavors — a hand-checked bandwidth
    conversion (60875000 bytes/s → 487.0 Mbps), absent-field and
    malformed-input handling, and a privacy test asserting the identifying
    Ookla fields never reach stdout — plus two structural checks that
    neither speed-test function's source still mentions jq.
  - CI gained a broken-jq smoke test: `jq` is shadowed by a failing stub
    earlier in `PATH` than either Homebrew prefix — jq is present and
    resolves, it just fails — and a real `--json --quick` run is
    asserted to exit anything but 3 and to parse with `python3`.

## [0.9.0] - 2026-08-12

Makes a check watchable while it runs. A full check takes ~55 s and
showed a spinner for all of them; the monitor held an hour of samples
nothing drew; and there was no way to ask one question without waiting
for all 28 checks.

### Added

- **`netdiag --progress`** — a JSON event stream on **fd 3**: a `plan`
  naming the phases a mode will attempt, then `start`/`done`/`skip` per
  phase, then a closing `run` event. Emitted from `run_timed` and
  `launch_parallel`, so all 28 checks report and so does every check
  added later.
  - Not stdout, which must stay exactly one object, and not stderr:
    `launch_parallel` captures each parallel check's stderr into a
    per-check file that nothing reads until the check finishes — which is
    when progress stops being useful. fd 3 survives that redirect and was
    unused across the whole tree.
  - A plan, not a percentage. `--json` produces nothing until the end, so
    there is no quantity a percentage could be a percentage *of*.
  - Every event is clamped well under `PIPE_BUF`, because parallel
    subshells share fd 3 and only sub-`PIPE_BUF` pipe writes are atomic.
    Clamping happens *before* escaping — a cut landing between a
    backslash and the character it escapes stops the line being JSON.
- **Live speed-test progress**, newly possible: Ookla's `--format=jsonl`
  streams, where the `speedtest-cli` shim it replaced emitted nothing
  until the end. 201 events in a real run.
- **`netdiag --speed-only`** — one measurement without the other 27
  checks, recorded to history.
- **`run_mode`** on every record: `full`, `quick`, `speed-only`,
  `mtu-only`, `wifi-only`. A `--quick` run and a full check were
  previously indistinguishable in history, which overstated what a
  network's run count actually measured. `helpers/history.py` gains
  `check_count` beside `run_count`; partial modes contribute their
  metrics but not to severity or incident counts.
- **App: a Live tab** — gateway RTT, internet RTT and router loss over
  the last hour, drawn from samples the monitor was already keeping.
- **App: scan progress replaces the spinner**, and on-demand speed and
  latency tests in the dropdown.

### Fixed

- **Cancelling a scan reported "netdiag returned something unreadable".**
  Terminating the child yields a signal status and empty stdout, which
  the runner classified as corrupt output rather than as cancellation.
- **The elapsed-seconds counter froze during a scan** — it recomputed
  only on observation, and the monitor that drove observation is paused
  for the duration of every scan.
- **The expert panel's sparklines drew straight lines across monitor
  pauses**, claiming measurements that were never taken.

### Notes

- Ookla's `testStart` line carries `interface.internalIp` — the
  machine's public IPv6 address. The translation to fd 3 extracts four
  fields by name and rebuilds the object; it never passes through and
  never filters known-bad keys. A fixture asserts the leak, and a real
  217-event run was scanned for every identifying field in that line.
- The declared plan is kept in sync with the code by a bats guard that
  plants a phase into a copy of `bin/netdiag` and proves it catches it.

## [0.8.0] - 2026-08-11

Makes the run history readable. `~/net-diag/baseline.jsonl` already held the
complete JSON of every check ever run — 1,986 finished reports, each with
its own diagnosis prose — and the app could open exactly one of them: the
most recent. Now you can open any of them, and see how it compares to what
is normal for that network.

### Added

- **`netdiag --show=<id>`** — one stored run in full, plus a `comparison`
  block scoring each of its metrics against every other run on the same
  network: median, p10/p90, percentile, and a verdict. ~0.14 s against a
  1,986-record store.
- **Stable run ids** on `--history` output: the timestamp, a dot, and eight
  hex characters of the record's content hash. `ts` alone cannot address a
  run — `helpers/history.py` has always deduped on *(timestamp, content)*
  precisely because two runs can land in the same second.
- **`THRESH_COMPARE_MIN_SAMPLES` and `THRESH_COMPARE_TAIL_PCTL`** in
  `lib/thresholds.sh`. One symmetric tail rather than a "worse" and a
  "better" percentile: a directional pair reads correctly for latency and
  inverts for throughput, where the *low* percentile is the bad one.
- **App: browse every check on a network** — Networks → Browse checks → a
  run, showing the same report card as the Status tab plus the comparison.

### Fixed

- The menu-bar health dot rendered grey in every state. `MenuBarExtra` hands
  its label to an `NSStatusItem`, which template-renders SF Symbols and
  discards `foregroundStyle` — so the one glyph carrying the app's whole
  status said nothing. Now rasterised with an explicit palette colour.
- Stored records are decoded leniently. Swift's synthesized `Decodable`
  throws on a missing key rather than using the default beside the property,
  and only **60 of 1,986** stored records carry `network` or `timings` — the
  rest predate those fields. A strict decode opened 3% of the history and
  called the remainder corrupt.

### Notes

- `helpers/history.py` is now the third file `tests/test_thresholds.bats`
  guards against inline numeric cutoffs, alongside `lib/diagnosis.sh` and
  `lib/monitor.sh`. It judges now, so it lives under the same rule.
- Percentile ranks average ties. Counting them as "at or below" puts a
  0 %-loss run — the usual case — at the 100th percentile of a
  lower-is-better metric and calls a flawless check *worse than usual*.

## [0.7.0] - 2026-08-11

Adds a native macOS menu-bar app, and the two CLI surfaces it is built on.
The app is a **client, not a second brain**: it holds no thresholds and
writes no diagnosis prose. Everything it says comes from the CLI.

### Added

- **`netdiag --monitor`** — a long-lived process emitting one compact JSON
  object per line on stdout, flushed per sample, until stopped. The
  machine-readable sibling of `--watch`: where `--watch` re-runs `--quick`
  and prints prose for a person, `--monitor` streams for a program, writes
  no log and no history record, and probes on three cadence tiers instead
  of one — fast (gateway ping, VPN, link) 10 s, medium (DNS, TCP/443,
  RSSI) 60 s, slow (public IP, ISP, country, captive portal) 300 s plus
  immediately on a network change. Sample shape documented separately in
  `docs/JSON-SCHEMA.md`; intervals overridable with
  `--monitor-{fast,degraded,medium,slow}-interval`.
  - Each sample carries `status.rules`: the `DIAGNOSIS-RULES.md` IDs that
    would fire, evaluated in bash against `lib/thresholds.sh`. For any
    given network state the monitor and a full run name the **same** rule
    IDs, asserted by bats across eleven conditions. Consumers render the
    list; they never re-derive it.
  - The gateway probe sends **10** packets, not the 3 a liveness check
    suggests. This is quantisation, not accuracy: at 3 packets the only
    reportable losses are 0/33/67/100 %, so one dropped packet reads as
    33 % — past the 20 % critical floor. At 10 the quantum is 10 %, so one
    drop lands in G3's warn band and it takes two to go critical, matching
    the shape of the scanner's 20-packet probe.
  - Samples are emitted through a Python helper rather than bash `printf`.
    An SSID may legally contain a quote, a backslash or a newline, and a
    JSON-escaping bug in a stream parsed forever is a far worse trade than
    ~50 ms of interpreter startup per cycle.
- **`netdiag --history[=N]`** — the whole run store as one normalized,
  network-grouped object. 5.4 MB of full snapshots becomes 467 KB.
  - Grouping is **not** exact-string matching on `network.id`, because
    that does not work on real data: of 1,972 records here, 1,926 predate
    `lib/netid.sh` and carry no id at all, all 46 that do are
    `wifi:mac=…` because macOS has redacted the SSID throughout v0.5.x,
    and every legacy record's `wifi.ssid` is the literal `<redacted>`.
    Groups key on the `mac=` component, backfill idless records through
    `netid.sh`'s own precedence (marked `synthesized`), and bridge weak
    groups into MAC groups only when gateway **and** ISP agree. Genuine
    ambiguity is left for the app's manual merge — a wrong merge silently
    corrupts a chart, a missing one is visible and fixable.
  - Every metric reports its sample count, because sparse series are the
    normal case: `gateway_rtt_ms` has 1,959 samples here and `wifi.rssi`
    has 1. A chart that omits the count presents one reading as a trend.
- **`lib/thresholds.sh`** — every numeric cutoff a rule fires on, moved out
  of inline literals. There are now two things that judge a network, and
  if they drift the app shows a green dot over a red report. A test fails
  the build on an inline cutoff in either file. It also makes W1's −75 dBm
  and G1's −70 dBm visibly distinct rather than four lines apart.
- **`public.country_iso`** in both `--json` and `--monitor`. `country` is
  the full name ("Brazil"); rendering a flag or picking a locale needs the
  ISO-3166 alpha-2, and deriving it would mean shipping a country table in
  every consumer.
- **`gui/` — netdiag.app.** SwiftUI menu-bar client, SwiftPM, macOS 14+,
  builds with Command Line Tools and no Xcode. Continuous monitoring, a
  twelve-alert engine with dwell/cooldown/auto-resolve, Swift Charts over
  the full history, per-network rename and merge, and four disclosure
  layers from a menu-bar dot to a raw-JSON viewer. `make -C gui run` is
  the dev loop; `make -C gui identity` creates the stable signing identity
  that keeps TCC grants alive across rebuilds.

### Fixed

- **`--redact` no longer corrupts the history store.** `output_run`
  appended the emitted JSON to `baseline.jsonl` *after* redaction, so
  every `--redact` run wrote a record whose `network.id` was the literal
  string `wifi:mac=[redacted]`. That id is the join key
  `helpers/baseline.py` scopes history by, so such a record can never
  match a real one: it is dead weight that also burns a slot under the
  retention cap. Eleven exist in the author's history, two written by
  v0.5.2. The comparison input, the history append and the archive now
  read an unredacted build; only the `--json` copy that actually leaves
  the machine is masked.
- **Retention no longer deletes the history it exists to keep.**
  `prune_history` ran `tail -n` over the file and discarded the head. At
  the launchd watcher's 96 runs/day the 2000-line cap is about three
  weeks, and the lines it dropped were always the oldest — the only ones a
  multi-month chart is made of. The head now rolls into
  `baseline-archive.jsonl`, appended *before* the truncate so a crash
  between the two duplicates records rather than losing them.
  `--history` reads both and dedupes; `baseline.py` still reads only the
  live file, so per-run cost stays bounded.

### Notes

- The monitor is paused with **`SIGUSR1`** and resumed with `SIGUSR2`,
  handled in-process. `SIGSTOP` from the parent — the obvious mechanism,
  and what the plan specified — is actively unsafe here: POSIX delivers
  `SIGHUP`+`SIGCONT` to a process group that becomes newly orphaned while
  any member is stopped, and a stopped monitor still has live children
  (the 2 s gateway ping, `with_timeout`'s killer subshells). Measured
  under the GUI, the monitor died 2.1 s into every pause — exactly one
  ping probe — and the app then restarted it *during the scan the pause
  existed to protect*. It never reproduced from a terminal, because a
  controlling terminal keeps the group non-orphaned, which is precisely
  how it would have shipped.
- **`--monitor` exits when the process that started it goes away.** Found
  the same way: `SIGKILL` the app and the monitor was still probing 30 s
  later, re-parented to launchd with nobody reading it. Relying on `EPIPE`
  from a closed stdout is not enough, because a pipe fd survives in ways
  the child cannot audit, so the parent is now checked each cycle with
  `kill -0` — a builtin, and the only thing that works, since bash
  captures `$PPID` once at startup and still reports a dead pid after
  re-parenting. An unbounded network probe with no reader is the single
  most likely reason an always-on tool gets uninstalled, and it is
  invisible: nothing in the UI can show a process the app has forgotten.

## [0.6.1] - 2026-08-11

### Fixed

- **`--quick` is back inside its 8 s budget: 10.6 s → 3.8 s.** A single
  `traceroute6` in `lib/ipv6.sh` accounted for 7.4 s of that 10.6 — 70% of
  the wall clock of the mode whose entire purpose is a fast "is it up?"
  answer. It now only runs outside `--quick`. What it produces,
  `IPV6_TRACE_HOPS`, feeds **no diagnosis rule**: it reaches the JSON and
  one `info` line that default compact output doesn't print. `--quick`
  leaves it empty, which renders as JSON `null` — "not measured", never a
  fabricated `0`. Full runs are unaffected and still report the hop count.
  - `parallel_batch` under `--quick` drops from 7.9 s to 1.1 s. The batch
    is bounded by its slowest member, and `ipv6_run` was that member by a
    factor of twelve; the other three surviving checks total 0.6 s.
- **`traceroute6` is now bounded by `with_timeout` in every mode**, not
  just skipped in the fast one. It was the only probe in the module with
  no wall-clock bound — `ping6`, `dig` and `nc` are all capped — and at
  `-m 12` hops × `-w 2` s it is a 24 s worst case on a path that
  black-holes IPv6. An unbounded probe that can silently dominate a run is
  the same shape as the `ping -t` bug fixed in 0.6.0. A test now asserts
  every probe in the module carries a bound.

## [0.6.0] - 2026-08-11

netdiag could measure internet-side packet loss but could not diagnose it.
`INET_LOSS` had been recorded, written to JSON, and used to colour a
Report-card row since v0.4.0 — and no rule ever read it. Because
`ok()`/`warn()`/`bad()` are pure printers and only `add_diag` moves
`MAX_SEVERITY`, a connection dropping 40% of its packets printed a red
"Latency" row directly above the words "Nothing obviously wrong — your
network looks healthy" and exited 0.

That is the exact failure users describe as "the internet is down":
everything technically works, nothing finishes. `P1`/`P2` could not cover
it, because they require the public reach check to have *failed*, and
under heavy-but-partial loss `curl` still succeeds — TCP simply
retransmits its way through.

### Added

- **`L1` — severe internet-side packet loss is now a critical.** Fires
  when both public targets exceed 20% loss while the gateway is clean,
  pointing past the user's own equipment to the line, modem, or ISP.
- **`L2` — moderate internet-side loss (10–19%) is a warning.**
- **`G3` — gateway loss of 10–19% is a warning.** `G1`/`G2` start at 20%,
  and nothing covered the band beneath them, so 15% loss to the user's own
  router also exited 0.
- **`ICMP-1` — total loss to both targets while TCP and curl work** is
  reported as upstream ping filtering, not an outage, and suppresses
  `L1`/`L2`. Real 100% loss would have taken curl with it.
- **A second, independent loss target (8.8.8.8).** `L1` escalates to
  critical only when both it and 1.1.1.1 agree; one lossy target and one
  clean one is far more likely to be that anycast operator's ICMP policy
  than a fault on the line. JSON gains `internet_latency.target_alt`,
  `.rtt_avg_ms_alt`, and `.loss_pct_alt`.
- **A "Packet loss" row on the Report card**, showing both targets.
- **`VPN-1` now actually fires.** `docs/DIAGNOSIS-RULES.md` and the README
  had both promised the rule since v0.1.0 while `lib/vpn.sh` only printed
  a section line — no `add_diag` call existed anywhere, so an active VPN
  never reached the Diagnosis section. It is `info` severity, so it cannot
  change the exit code; the point is to stop users blaming their router
  for the tunnel's latency.
- **A one-line install.** `curl -fsSL .../install.sh | bash` now works.
  `install.sh` previously symlinked `$REPO_ROOT/bin/netdiag`, so it only
  ran inside an existing clone and could not be piped from curl at all.
  It now detects that it has no checkout to point at, fetches one into
  `~/.local/share/netdiag`, and `git pull`s it on re-run. Run from inside
  a clone it uses that clone and never touches the network. Adds
  `--uninstall`, and creates the `--prefix` directory instead of failing
  with a bare `ln: No such file or directory`.
- **`docs/JSON-SCHEMA.md`** documenting every top-level key of `--json`
  as actually emitted, the `null` (didn't run) vs `[]` (ran, found
  nothing) convention, and the `dhcp.dns_servers` string-not-array wart.
- **`CONTRIBUTING.md`.**
- **CI smoke tests** — a real `netdiag --json` run whose exit status and
  JSON shape are checked, and an install/uninstall round-trip.

### Changed

- **The speed test runs by default.** "Is my internet slow?" is the
  question most runs are opened to settle, and answering it with "not
  tested (run with `--speed`)" made the default report useless for it.
  `--no-speed` opts out; `--quick` skips it; an explicit `--speed` still
  forces it under `--quick`.
  - This makes a default run substantially slower — measured at ~95 s on
    this machine, of which the speed test alone is ~58 s. Use `--no-speed`
    (~35 s) when the run needs to be quick. `CLAUDE.md`'s stated budget has
    been updated to match rather than left as an aspiration.
- **The speed test now runs last, after the Report card and the diagnoses
  have already printed.** It is the most expensive phase by a wide margin,
  and nothing in the diagnosis stage reads its result — only the JSON
  emitter does, and that still runs afterwards, so `--json` and the log
  are unchanged. Previously the user watched a spinner for a minute before
  seeing anything at all, including when the answer was "your router is
  dropping packets" and they could have acted on it immediately. The
  Report card's Speed row says "measuring now — result prints below" while
  it is pending. The test still cannot be parallelised: it saturates the
  link deliberately and would corrupt every latency, loss, and bufferbloat
  number it overlapped, so last is the only safe place for it.
- **Loss probes send 20 packets instead of 8**, putting the reportable
  quantum at 5% so the new thresholds land on a whole number of dropped
  packets. At 8 packets one drop was 12.5% and no threshold below that
  was expressible at all.
- **`internet_ping_run` no longer runs in the parallel batch.** Measuring
  loss while DNS, TCP, NTP, the WiFi scan and two WAN probes compete for
  the same interface measures the tool, not the network. It now runs
  serially on a quiet link, before the bufferbloat probe saturates it.
- **Loss thresholds are shared constants** (`LOSS_WARN_PCT`,
  `LOSS_CRIT_PCT`) used by both the rules and the Report card, so a
  coloured row always has a matching diagnosis beneath it. The Router row
  previously went yellow at 1% while the lowest gateway rule fired at 20%.

### Fixed

- **`ping -t` was corrupting every loss measurement.** On macOS, `-t` is a
  deadline for the *whole run*, not a per-packet TTL — which is what
  `-c 8 -t 2` looks like it means. `ping -c 20 -i 0.2 -t 2` transmitted
  **10** packets, silently discarding half the probe; `ping -c 20 -i 0.1
  -t 2` reported a permanent **5.0% loss** because the final reply landed
  after the deadline. Removing the flag gives 20/20 and 0.0% on both
  targets in every trial. Both loss probes now bound themselves with
  `with_timeout`, which cannot corrupt the measurement, and a test greps
  for the flag's return.
- **The speed test never ran on machines with only `speedtest-cli`.** The
  Python package installs a `speedtest` shim alongside `speedtest-cli`, and
  the code took `command -v speedtest` to mean Ookla's CLI, handing it
  `--format=json --accept-license --accept-gdpr`, which it rejects. The
  fallback sat in an `elif` on that same test, so it was unreachable:
  those machines reported "test ran but returned no result" every time.
  Detection now reads the `--version` banner instead of trusting the
  filename. Latent while the test was opt-in; a guaranteed failure on
  every run once it wasn't.
- **`add_diag` reported failure when adding a second diagnosis of the same
  severity.** Its `case` arms are `[ … ] && assign`, so the guard
  evaluating false became the function's exit status. Harmless under
  `bin/netdiag`'s `set -u`, but any `set -e` caller aborted mid-rule-set
  and silently truncated the diagnosis list.
- **`P1`/`P2` required the gateway to show *exactly* zero loss.** An
  outage measured alongside, say, 8% gateway loss matched neither them nor
  `G1`/`G2`, so a total loss of internet produced no diagnosis at all. The
  guard is now "the router is not the problem" rather than "the router is
  flawless", and distinguishes a clean gateway from an unmeasured one.
- **`.github/workflows/shellcheck.yml`** no longer carries a stale
  `nimbalyst-local` entry in `ignore_paths`, left over from another
  project.
- **README no longer documents output the tool doesn't produce.** The
  sample-output block showed a `── Diagnosis ──` section and wording
  retired in v0.4.0; it now quotes the real Report card. The Roadmap
  still listed the v0.3.0 module refactor as upcoming work. The rule
  list was missing `N1`, `N1b`, `DI-2`, `WAN-1b`, `NAT-1b` and `BL-1`,
  and listed `UP-1` without noting it is deliberately never emitted.
- **`examples/sample-output.{txt,json}`** regenerated from real
  `--redact` runs; the previous pair predated the current output format.

### Removed

- **`netdiag-prompt.md`**, the original build spec. Its JSON schema moved
  to `docs/JSON-SCHEMA.md` (rewritten against what the emitter actually
  produces — the spec's copy had drifted, e.g. `ping6_loss_pct` vs the
  real `ping_loss_pct`, and predated the `wan`, `hosts_file`, `timings`
  and `network` keys). Its acceptance criteria moved into `CLAUDE.md`.
  Still in git history.

## [0.5.2] - 2026-08-11

Fixes found by running netdiag against a live dual-stack network. All three
share a shape: a measurement silently failed, and the failure was rendered
as a confident statement about the user's network instead of as missing
data. Two of them told the user something untrue about their own setup.

### Fixed

- **The progress line no longer flickers between two captions.**
  `_progress_spinner_pid` holds exactly one pid, so starting a spinner
  while one was already running overwrote the only handle on the old one.
  It was never killed and kept repainting its own label every 100 ms, so
  the terminal alternated between "Public reachability" and the live
  section at 10 Hz for the rest of the run. `hdr` stopped the previous
  spinner, but the two direct `progress_spin_start` callers in
  `bin/netdiag` did not. `progress_spin_start` is now idempotent.
- **A finished run no longer strands a spinner on your terminal.** Because
  nothing tracked the orphan, it outlived the orchestrator and went on
  writing over the shell prompt; three such processes were found still
  running from earlier sessions. `progress_spin_stop` now also runs from
  the `EXIT` trap, so Ctrl-C and early aborts clean up too.
- **DH-2 no longer accuses you of a DNS override you never made.** On any
  network with IPv6 router adverts, macOS puts the router's link-local at
  `nameserver[0]` and the DHCP-handed IPv4 server at `nameserver[1]`. The
  check compared only `nameserver[0]`, and compared it against DHCPv4
  option 6, which cannot carry IPv6 addresses — so it reported "somebody
  manually overrode it" while the router's own DNS was in use the whole
  time. It now compares the full resolver list, ignores link-local entries
  (which are router-advertised and cannot be set by hand), and matches
  whole addresses: `grep -F` also meant a system resolver of
  `192.168.15.1` "matched" a DHCP list of `192.168.15.10`, hiding a real
  override. Same fix in the `DNS` section warning.
- **IPv6 is no longer reported as broken on every machine that has it.**
  macOS `ping6`'s `-W` is a boolean in the `[-DdfHmnNoqrRtvwW]` cluster —
  it selects the old 03-draft node-information format, it is not a
  timeout. `-W 2000` made `ping6` read `2000` as the hostname, so it
  exited with "nodename nor servname provided" before sending a packet;
  `2>/dev/null` hid the message and the empty result was defaulted to
  100% loss. Every IPv6-capable run therefore raised V6-1 and a warning
  Report row, with the self-contradicting evidence "loss 100%, AAAA OK,
  TCP6 OK". `with_timeout` now supplies the bound, and an unparseable
  result is recorded as unknown rather than as total loss.

### Added

- `tests/test_regressions.bats` — 19 guards covering all three bugs,
  including the spinner-lifecycle invariant, whole-address override
  matching, and a `ping6` flag check that runs against loopback so it
  needs no network.

## [0.5.1] - 2026-08-11

Fixes found by running every CLI mode on a live network. Three of the four
share a root cause: focused runs skip most modules, and the consumers
could not tell an untouched global default from a real measurement.

### Fixed

- **`--wifi-only` no longer reports a false critical and exits 2.** On a
  perfectly healthy connection it printed "Your Mac has a router but
  nothing on the public internet responded" and returned exit 2. Rule N1b
  keyed off `PUBLIC_OK`, but `--wifi-only` never runs `public_run`, so the
  `PUBLIC_OK=0` default from `lib/globals.sh` read as a measured failure.
  The rule now also requires `PUBLIC_CHECKED=1`. Since exit 2 is the
  machine-readable "something is critically wrong" contract, this misfired
  on every scripted `--wifi-only` caller.
- **N1b names the flag you actually passed.** Its text hardcoded
  "without --mtu-only" even when the active focus was `--wifi-only`.
- **`--mtu-only` no longer calls a WiFi link "wired".** The Report card
  treated `IS_WIFI != 1` as wired, but `--mtu-only` never runs `wifi_run`,
  so the flag never left its `0` default. The medium is now omitted when
  it was not measured. `--json` was already correct (`interface.type`).
- **`--redact` no longer leaks the gateway MAC.** `IPV6_GATEWAY` was left
  intact in both the human output and `.ipv6.gateway`, but a `fe80::`
  address is EUI-64-derived from the router's MAC — so a redacted report
  still published the same `GW_MAC` masked one field over. Added to the
  redaction set in `lib/common.sh` and `helpers/emit_json.py`.
- **shellcheck passes again.** `_netdiag_on_exit` carries a
  `disable=SC2317` for its trap-only dispatch; shellcheck 0.11.0 reports
  that case as SC2329 instead, so `ludeeus/action-shellcheck@master`
  (which tracks latest) failed on every push. Both codes are now listed.

### Known

- A full run measured 36 s against the spec's 30 s budget and `--quick`
  8.9 s against 8 s, on a link with ~76 ms RTT to the internet. How much
  is script overhead versus link latency is not yet separated — needs a
  re-measure on a low-latency connection before it is treated as a
  regression.

## [0.5.0] - 2026-08-07

Second correctness pass, plus the instrumentation needed to check the
spec's runtime budget. Clears the remaining known bugs from the v0.4.1
review.

### Fixed

- **Baseline history is now scoped per network.** `baseline.jsonl` was one
  flat stream across every network the machine had ever been on, so a
  laptop moving between home, office and a café tripped "gateway RTT ×4
  spike", "ISP changed", "WiFi channel changed" and "path MTU changed" on
  essentially every location change — each an `add_diag warn` that bumped
  the exit code to 1. Runs are now compared only against prior runs on the
  same network, identified by gateway MAC → SSID → gateway IP (see
  `lib/netid.sh`). Filtering happens *before* the last-N window, so a batch
  of runs elsewhere can't push a network's own history out of range.
  Pre-0.5.0 records have no identity and are skipped rather than pooled in.
- **`~/net-diag/` is bounded.** Nothing pruned it before: the launchd
  watcher adds 96 log files and 96 JSONL records a day, forever, and both
  Python helpers parsed the entire JSONL on every run. Now capped at the
  newest 200 logs and 2000 history records, overridable via
  `NETDIAG_KEEP_LOGS` / `NETDIAG_KEEP_HISTORY` (`0` disables).
- **Traceroute hop numbers are traceroute's own again.** The parser
  counted replies, so every hop after a `* * *` timeout was renumbered and
  the JSON disagreed with what the user sees running traceroute by hand.
  Worse, closing the gap made two private hops separated by a timeout look
  adjacent, which could fake a double-NAT. Non-responding hops now keep
  their slot and surface as `ip: null, responded: false`.
- **The PMTU probe retries.** One probe per size meant a single dropped
  packet at 1472 reported a clamped MTU — and rule M1 escalates a sub-1400
  result to *critical*. Now three packets per size (`ping` exits 0 on any
  reply), which is also faster in the worst case than the old single-probe
  walk down the whole ladder.

### Added

- **`--redact`** masks public IP, SSID, BSSID, IPv6 address, gateway MAC
  and city on stdout and in `--json`, so a report can be pasted into a
  forum or ticket. ASN and ISP are kept (they name a provider, not a
  person); RFC1918 addresses are kept (blanking them would gut the NAT and
  ARP sections). Masking is substring-based, so a value is caught even
  where a diagnosis sentence interpolated it. The on-disk log keeps full
  detail — it's local, and only what you share gets masked. Implies
  compact output: section bodies stream out before every value that needs
  masking has been discovered, and a partially redacted transcript is
  worse than none because it looks safe.
- **Timing instrumentation.** The spec's "≤ 30 s full, ≤ 8 s `--quick`"
  was asserted but never measured. Every phase is now wrapped in
  `run_timed`; the JSON gains a `timings` object (`total_s`, `budget_s`,
  `over_budget`, per-phase breakdown) and `--expert` prints a Timing
  section.
- **Rule IDs on every diagnosis.** `add_diag` now takes the rule ID (`W1`,
  `NAT-1`, `BL-1`, …) matching a heading in `docs/DIAGNOSIS-RULES.md`. It
  rides into the JSON as `diagnosis[].rule` so output is greppable and
  groupable instead of string-matched against prose that gets rewritten
  for readability. `--expert` prefixes each diagnosis with `[RULE]`;
  default output stays prose-only.
- `network` (`id`, `label`) and `interface.gateway_mac` in the JSON;
  `baseline.network_id` and `baseline.skipped_other_networks`.
- **39 tests, including the first coverage of `helpers/*.py`** —
  `emit_json.py` is the widest interface in the project and had none, so a
  renamed global silently produced `null` and nothing noticed. Covers the
  JSON's top-level shape, rule-ID parsing (with the pre-0.5 fallback and a
  summary containing `|`), hop gaps, the NAT split, timings, redaction,
  and every branch of the baseline network scoping.

### Changed

- JSON shape (additive except as noted): `diagnosis[]` entries gain
  `rule`; hop entries gain `responded` and report `ip: null` instead of an
  empty string for a non-responding hop; new `network` and `timings`
  objects.
- `_print_diagnosis_paragraph` takes a rule ID as its second argument.

## [0.4.1] - 2026-08-07

Correctness pass. No new checks — this fixes cases where netdiag reported
something confidently wrong, and closes three gaps against the spec in
`netdiag-prompt.md`.

### Fixed

- **A Mac with no network reported "healthy" and exited 0.** Every
  diagnosis rule guards on a measurement that only exists once there's a
  link (`[ -n "$GW_LOSS" ]` and friends), so with WiFi off *nothing* fired
  and the run ended with "Nothing obviously wrong — your network looks
  healthy". New rule **N1** fires on an empty default route, states the
  obvious, and makes the exit code 2. See `docs/DIAGNOSIS-RULES.md`.
- **`sntp` drift was parsed positionally.** `awk '{print $1}'` assumed the
  offset led the result line, but ntp 4.2.8 — what macOS ships — prefixes
  it with a timestamp. On that format netdiag reported a clock "off by
  2026-08-07 seconds" (the date, compared as a *string*, silently passed
  the `> 1` threshold). The field is now located by the `+/-` token, and
  validated numeric before use.
- **Double-NAT contradicted itself on ISP transit.** Carriers routinely
  run 10/8 between the CPE and their edge. The chain walker counted those
  hops, so the Report card showed a yellow "double-NAT detected" directly
  above a diagnosis explaining it wasn't a problem. The home/ISP split now
  happens in `wan_double_nat_run`, before the card is built:
  `WAN_DOUBLE_NAT` means *home-side* double-NAT, and ISP transit gets a
  neutral row.
- **Usage errors exited 2**, colliding with "≥ 1 critical diagnosis". An
  unknown flag, a second positional TARGET, or a bare `--log` now exit 3.
  An `EXIT` trap also remaps unplanned aborts (a `set -u` violation exits
  1 or 127 depending on the failure) to 3, so exit 1 always means
  "warnings only" and never "the script broke".
- **`--quick` ran the baseline diff**, contrary to acceptance criterion 3.
  It cost two `python3` starts plus a full parse of `baseline.jsonl` — the
  most expensive thing left in a quick run. The comparison is now skipped;
  the snapshot is still appended, so the `--quick`-driven launchd watcher
  keeps building history.
- The Report card's DNS row and rule **D1** both keyed off `DNS_OK`, which
  defaults to 0 — a run that skipped DNS reported lookups as failing when
  none were attempted. Both now require evidence the check ran.
- `traceroute` output was piped `| log_pipe | sed`, so the log got
  un-indented text and, in compact mode, `sed` ran on empty input. The
  indent now precedes the log stage.
- Non-numeric `wdutil` scrapes no longer reach `$((rssi - noise))` (a
  syntax error) or the `[ -ge ]` ladder ("integer expression expected").
- `install.sh --prefix` with no argument aborted on `$2` unbound under
  `set -u` instead of printing a usable message.

### Added

- **`--mtu-only`** and **`--wifi-only`**, listed in the documented CLI
  surface since v0.1 but never implemented — `netdiag --mtu-only` hit the
  unknown-flag path. Each runs one section plus its prerequisites, then
  the Report card and diagnoses over what it produced. The card filters to
  the focused section, so a partial run can't report on checks it skipped.
  Both suppress the baseline diff: a partial run isn't comparable to a
  full one, and recording it would poison the history.
- `wan.double_nat` in the JSON gains `home_chain`, `home_count`,
  `isp_transit_chain`, and `isp_transit_count`.
- `is_numeric` in `lib/common.sh` — the guard to use before feeding a
  scraped value to `[ -lt ]`, `$(( ))`, or an awk comparison.
- 24 tests: the `sntp` formats (both), `is_numeric`, the home/ISP chain
  split, the N1 floor case, and the exit-code contract.

### Changed

- shellcheck is clean at default severity again. The 11 pre-existing
  `SC2317` findings (trap handlers and the parallel-subshell function
  overrides, all reached by indirect dispatch) now carry justified
  disables, so the CI job reflects real problems.

## [0.4.0] - 2026-06-01

UX-focused release. The default report dropped from 130 lines of dense
section bodies to a ~30-line "Report card + What we found" — scannable
in a second, plain-English diagnoses underneath. `gping` is no longer
the default at-end action. `--quick` now actually meets its 8-second
spec budget (was 17 s). A live progress spinner replaces the previous
silent wait. New always-on latency / jitter / hosts-file / VPN /
internet-ping rows give the user more at-a-glance signal.

### Added

- **Compact "Report" card** by default — one column-aligned row per
  metric category (Network, Router, Internet, Latency, DNS, IPv6,
  Speed, Bufferbloat, Packet size, NAT topology, Router config, WiFi
  channel, Hosts file, VPN, Clock). Severity-sorted so warnings are at
  the top, healthy items grouped under them, neutral/skipped at the
  bottom. Dim labels keep the value column the visual anchor.
- **`What we found`** section replaces `Diagnosis`. Each diagnosis is
  rendered as a wrapped paragraph (70-col `fmt`) with a blank line
  between entries — readable instead of a wall of text.
- **`--expert` flag** restores the v0.3 verbose section-by-section
  output for power users. Default mode hides those bodies; expert
  mode shows everything plus the Report card + diagnoses.
- **`--gping` flag** + interactive prompt. gping no longer launches by
  default. Pass `--gping` to opt in, or answer the post-report
  `Launch live ping monitor? [y/N]` (5-second default-no timeout).
  The prompt is suppressed under `--quiet`, `--json`, `--watch`,
  `--watch-child`, or non-TTY stdin/stdout.
- **Progress spinner on stderr** during every section. The orchestrator
  was previously silent for 25-40 s in default mode; now each section's
  name animates while it runs (`⠋ Bufferbloat (loaded vs idle latency)…`).
  Stays out of stdout so JSON / piped consumers aren't affected.
- **Always-on internet latency probe** (`lib/internet_ping.sh`). 8-packet
  burst to 1.1.1.1, captures avg RTT + stddev (jitter) + loss. Report
  row: `Latency · 1.1.1.1 · 14 ms · ±7.2 ms jitter`. New JSON object:
  `internet_latency.{target,rtt_avg_ms,rtt_jitter_ms,loss_pct}`.
- **Gateway jitter.** `lib/gateway.sh` parses ping's stddev too. Report
  row gains `± X ms jitter`; JSON `gateway.rtt_jitter_ms` added.
- **`/etc/hosts` sanity check** (`lib/hosts.sh`). Counts non-default
  entries and flags any that redirect well-known consumer domains
  (facebook / google / netflix / amazon / apple / microsoft / github /
  …) to 127.0.0.1 / 0.0.0.0 / ::1 — usually an ad-blocker or
  parental-control tool, occasionally malware. New JSON object:
  `hosts_file.{custom_count,suspicious_redirects}`.
- **VPN row is now always shown.** Previously only when active.
  Defaults to `· VPN · not active`; when active, points the user at
  the Internet row for the exit-country lookup.
- **`tell()` helper** in `lib/common.sh` for "always visible" lines
  (the `netdiag` banner, "Report saved to" footer) that survive the
  new section-body gating.

### Changed

- **`--quick` now meets its 8-second budget** (was 17.6 s). Under
  `--quick`: NTP probe, internet ping, and default traceroute are
  skipped, and the gateway ping is cut from 10 to 5 packets. Side
  effect: NAT-1 (double-NAT) doesn't fire under `--quick` because it
  depends on TRACE_LINES — run without `--quick` for the NAT topology
  check.
- **`--quiet` semantics tightened.** Prints only the header + `What
  we found`. Drop the Report card too so the diagnoses are pipe-clean
  for mail / tickets.
- **Diagnosis text rewritten in plain English** across every rule
  (`lib/diagnosis.sh`, `lib/wan.sh`, `lib/output.sh` baseline-regression).
  Pattern: visible symptom first, plain cause, concrete action, with
  technical term parenthetical for power users. E.g. "Bufferbloat at
  gateway (grade D, +230 ms under load) — router lacks SQM/fq_codel.
  VOIP/Zoom will glitch under load." →
  "Your router chokes under load — whenever someone's downloading or
  uploading, Zoom / FaceTime / WhatsApp calls will glitch and games
  will lag badly (extra +230 ms delay, bufferbloat grade D). Fix:
  enable \"Smart Queue Management\" or \"QoS\" in your router's
  admin page, or replace the router with one that supports it."
- **Section ordering tweaked** to L2 → L3 → app: WiFi → Gateway →
  ARP → DHCP → Public, instead of the prior DHCP-before-Gateway order.
- **Bufferbloat / Speed / Packet size / Latency rows show "skipped"**
  under `--quick` so the Report card stays the same shape across
  modes (used to silently omit those rows).
- **NTP soft-warning tier.** Clock drift between 1 s and 30 s now
  warns instead of being silently ignored; previously only the > 30 s
  band fired any diagnosis.

### Fixed

- **mktemp template bug.** `mktemp ".../netdiag-out.XXXXXX.json"`
  doesn't substitute the X's on macOS because the suffix isn't at the
  end — the literal-named file was being created once, then every
  subsequent run failed with "File exists" and emitted no JSON.
  Dropped the `.json` suffix.
- **gping crash on non-tty stdout.** gping renders a TUI and dies
  with "Device not configured (os error 6)" when piped to `tee` or
  redirected to a file. `gping_run` now also requires `[ -t 1 ]`.
- **Long IP-pair wraps cleanly in diagnoses.** The
  `(192.168.50.1 → 192.168.1.254)` notation now breaks at the spaces
  around `→` rather than spilling past the 70-col cap (sanitization
  regex fix).
- **Hosts row no longer marooned at the end** of the Report card.
  Severity-sort places it among the other healthy items.

## [0.3.0] - 2026-05-30

The "architecture + NAT/WAN topology" release. `bin/netdiag` was a single
1238-line bash file in v0.2.x; this release splits it into 23 modules
under `lib/`, adds a parallel-launch helper so independent checks run
concurrently, introduces a `with_timeout` wrapper to keep any one probe
from blocking the whole run, and ships a new NAT / WAN topology section
covering dual-WAN, double-NAT, and UPnP/NAT-PMP status.

### Added

- **Modular layout (lib/\*.sh).** Each section is its own module with a
  documented "Reads / Writes / Entry" header. `bin/netdiag` is now a
  ~230-line orchestrator. `lib/common.sh` holds shared printing,
  diagnosis accumulator, timeout wrapper, and parallel-launch helpers;
  `lib/globals.sh` centralises every cross-module variable.
- **Parallel batch.** DNS, IPv6, TCP reach, NTP, WiFi neighborhood,
  WiFi disconnect history, dual-WAN probe, and UPnP probe now run as
  background jobs collected via a fan-in helper. Per-section stdout is
  buffered so output order stays canonical even though execution is
  concurrent. On this Starlink link the parallel batch is bound by
  `system_profiler SPAirPortDataType` (~15 s); the previously-sequential
  work that used to fill that window is now overlapped.
- **`with_timeout SECS cmd…` helper.** macOS has no `timeout(1)`; this
  is a small shell wrapper that kills the wrapped command after SECS
  and returns 124 on timeout (matches GNU `timeout`). Applied to DNS
  `dig`, TCP `nc`, `traceroute`, `mtr`, and `sntp`.
- **NAT / WAN topology section** (`lib/wan.sh`, ~215 LOC):
  - **WAN-1 / WAN-1b — dual-WAN / load-balancing probe.** Three
    parallel `curl -s https://ifconfig.co/json` requests; flags if
    they return more than one distinct ASN or more than one public IP
    within the same ASN. Surfaces "outbound is being load-balanced
    across N ISPs" as a `warn` (or single-ASN multi-IP as `info` —
    likely CGNAT round-robin).
  - **NAT-1 — double-NAT detection.** Walks the traceroute output and
    counts consecutive RFC1918 hops before the first CGNAT or public
    address. > 1 → `warn` with the chain printed. Pure parse; no extra
    network call.
  - **UP-1 — UPnP / NAT-PMP status.** Prefers Homebrew `miniupnpc`
    (`upnpc -s`); falls back to a raw SSDP M-SEARCH via `nc -u`, then a
    NAT-PMP probe to gateway:5351. Reports `enabled` / `disabled` /
    `unknown`; `info` severity (disabled is the safer default but
    games / Plex / Steam often need it).
  - **JSON schema additions** — new top-level `wan` object with
    `load_balancing.{distinct_asns,distinct_ips,active}`,
    `double_nat.{detected,rfc1918_chain}`, and
    `upnp.{state,device,url,tested_via}`. Additive only; v0.2.x
    consumers see the same other keys.
- **Bats fixtures + parser unit tests** (`tests/test_parse.bats`).
  24 tests covering `grade_bufferbloat` thresholds, traceroute
  parser (`*` skip + banner skip + renumbering), mtr first-lossy-hop
  detection, ARP duplicate detection (with synthetic `arp_dup.txt`),
  DHCP lease-end date math, PMTU computation, and the new double-NAT
  RFC1918 chain walker. Fixtures captured from this Mac
  (`tests/fixtures/{wdutil_info,ipconfig_getsummary,traceroute,arp_an,
  system_profiler}.txt`) are sanitized — MACs, SSIDs, BSSIDs replaced
  with synthetic values.
- **`tests/integration_sudo.sh`** — interactive one-shot that asks for
  sudo once, then exercises the mtr-under-sudo branch end-to-end
  (`bats` can't drive sudo so this lives outside the suite).

### Fixed

- **`traceroute -n` parser dropped hop 1.** The awk skipped NR=1
  expecting a banner, but macOS writes the "traceroute to ..." banner
  to stderr and netdiag was redirecting stderr — so NR=1 was actually
  hop 1. Now matches on `$1 == "traceroute"` so it skips the banner
  only when it's actually present. This v0.2.x bug was latent because
  no v0.2 rule walked the trace data; the new NAT-1 rule surfaced it.
- **`with_timeout` orphaned `sleep` could pin command substitution.**
  The killer subshell's `sleep` inherited stdout, so `$(with_timeout
  ...)` would block for the full timeout even after the wrapped
  command had completed. Killer subshell output now goes to /dev/null.

### Changed

- **JSON `version` is now `"0.3.0"`** (was `"0.2.0"` — the
  `emit_json.py` default).

## [0.2.1] - 2026-05-30

Bugfix release driven by a 13-test pass of v0.2.0 on a real Starlink link.
Surfaced spec violations (exit codes, JSON schema), broken budgets (full
run > 30 s, `--quick` > 8 s under `--quiet`, `--quick TARGET` > 24 s), and
a noisy WiFi-disconnect counter. All fixed; no new features.

### Fixed

- **Exit codes per spec (`0`/`1`/`2`/`3`).** Each diagnosis is now tagged
  `info` / `warn` / `critical` via a new `add_diag` helper that updates
  a `MAX_SEVERITY` global. The script `exit "$MAX_SEVERITY"` at the end.
  Previously every run exited 0 regardless.
- **JSON output now matches `netdiag-prompt.md`'s schema** — top-level
  keys in the spec's order, full `traceroute.{target,hops[]}`,
  `per_hop[]`, `mtr.{target,duration_s,hops[],first_lossy_hop}`,
  `baseline.{compared_runs,regressions[]}`, and
  `most_likely_root_cause` fields. Non-spec extras (`arp_gw_incomplete`,
  `target`, `target_ping`, target traceroute) moved under `netdiag_extras`.
- **WiFi disconnect count over-counted ~3×** because the regex caught
  `disassoc=` substrings inside airportd dictionary dumps. Tightened to
  `disassociated|deauthenticated|link[[:space:]]+down|disconnect[[:space:]]+reason|reassociating`.
- **30 s budget**: full run (parallelised per-hop fallback loop) dropped
  from 32.6 s to ~27.6 s on this Starlink link.
- **8 s `--quick` budget**: `--quick` now also gates WiFi disconnect
  history and the optional `TARGET` traceroute. `--quick` → 7.3 s;
  `--quick TARGET` → 5.5 s (was 24.4 s).
- **Diagnosis ordering** is now severity-descending (critical → warn →
  info), preserving insertion order within each tier. The first emitted
  line is surfaced as `most_likely_root_cause` in the JSON.
- **`--watch` UX**: SIGINT/SIGTERM trap prints "stopped after N
  iteration(s)" and points at the baseline file. Child invocations get
  a new internal `--watch-child` flag that suppresses the per-iteration
  "Report saved to" line.
- **Diagnosis text rendering** now matches the severity: critical fires
  red `✗`, warn fires yellow `⚠`, info fires gray `·` (was always red).
- **PMTU rule split** into critical (< 1400) vs warn (< 1500), reflecting
  the real severity gradient.

## [0.2.0] - 2026-05-30

The full 14-enhancement build out from `netdiag-prompt.md`, plus JSON
output, the continuous-monitoring trio (--watch / --summary /
--install-watcher), and a baseline-regression detector.

### Added — diagnostic checks

- **Bufferbloat** (feature 1): 10 s / 100 MB curl from
  `speed.cloudflare.com` saturates the link while
  ping samples to the gateway and `1.1.1.1` produce a Waveform/DSLReports
  A–F grade per side. Diagnoses B1 (router SQM) and B2 (ISP CPE) split
  the blame.
- **PMTU black-hole probe** (feature 2): walks DF-set ping payloads
  downward to find the largest that gets through; flags effective MTU
  < 1500 (rule M1).
- **mtr continuous loss** (feature 3): `mtr -j -c 60 -i 0.2` parsed via
  `jq` to identify the first hop with > 2 % loss (rule MT1). Falls back
  to the original per-hop loop when mtr / jq / sudo isn't available.
- **IPv6 parity** (feature 4): global v6, gateway, ping6, AAAA,
  traceroute6 hop count, TCP/443 to `ipv6.google.com`. Rule V6-1 fires
  on v6-broken-while-v4-works (Happy Eyeballs masks it).
- **VPN detection** (feature 5): `scutil --nc list`, `tailscale status`,
  default-route via utun*/wg*. Surfaced at top via rule VPN-1.
- **TCP reach panel** (feature 6): parallel `nc -G 3 -z` to a 5-host
  panel + TARGET:443; rule TCP-1 flags "ICMP filtered, TCP fine."
- **WiFi neighbourhood** (feature 7): `system_profiler
  SPAirPortDataType -detailLevel full` channel utilisation. Rule WS-1
  fires when > 3 neighbours share the current channel.
- **WiFi disconnect history** (feature 8): `log show --predicate
  'subsystem CONTAINS[c] "wifi" OR "airport"' --last 1h`; rule WD-1
  on > 3 disconnects in window.
- **Speed test** (feature 9): opt-in `--speed`. Tries Ookla `speedtest`
  first, falls back to open-source `speedtest-cli`. Both go through `jq`.
- **NTP drift** (feature 10): `sntp -t 3 time.apple.com`; rule NT-1 at
  |drift| > 30 s (TLS handshakes start failing).
- **Baseline diff** (feature 11): every run appends to
  `~/net-diag/baseline.jsonl`; current snapshot compared against the
  median of the last 10. Regressions tagged spike / drop / drift /
  change and surfaced as additional diagnoses.
- **Custom TARGET** (feature 12): `netdiag github.com` adds the host to
  DNS, TCP-reach, traceroute, and a dedicated ping.
- **Duplicate-IP / ARP** (feature 13): rule DI-1 on duplicates or
  `(incomplete)` gateway entry.
- **DHCP lease detail** (feature 14): server, lease window, time
  remaining, DHCP-handed DNS. Rules DH-1 (lease expires within 1 h)
  and DH-2 (DHCP DNS ≠ system resolver).

### Added — output and operation

- `--json` emits one schema-conformant JSON object on stdout
  (helpers/emit_json.py). Suppresses human output unless `--log PATH`
  is also passed.
- `--quiet` shows only the Diagnosis section + final report line.
- `--log PATH` overrides the default `~/net-diag/<timestamp>.log`.
- `--baseline` / `--no-baseline` control the comparison + history append.
- `--watch[=SEC]` runs every SEC seconds in the foreground.
- `--summary[=HOURS]` aggregates `baseline.jsonl` into a human report
  (helpers/summary.py).
- `--install-watcher` / `--uninstall-watcher` drop a launchd plist that
  runs netdiag every 15 min in the background.
- `--no-bufferbloat` opts out of the bandwidth-heavy probe on metered
  links.

### Added — packaging

- Requires bash 5 (Homebrew). `bin/netdiag` re-execs under
  `/opt/homebrew/bin/bash` or `/usr/local/bin/bash`, fails clean with
  install hint if neither is present. `install.sh` learns
  `brew install bash` when missing.
- Two Python helpers: `helpers/emit_json.py`, `helpers/baseline.py`,
  `helpers/summary.py`. Stock /usr/bin/python3 on macOS 14+; no extra
  packages.
- `docs/ARCHITECTURE.md` records the bash/Python split.
- `docs/DIAGNOSIS-RULES.md` documents every rule with rationale.
- `examples/sample-output.{txt,json}` captured from a live Starlink run
  (SSID/BSSID/public IP redacted).

### Changed

- Help block moved off the fragile `sed -n '2,10p'` extraction to a
  heredoc that survives future inserts above.
- Argument parser is strict about unknown `--*` flags (silently
  accepting was masking typos).

## [0.1.0] - 2026-05-30

Initial repo skeleton — the 297-line starter script wrapped in proper
repo structure, MIT licence, and GitHub Actions CI for `shellcheck`
(Ubuntu) and `bats-core` (macOS).

<!-- Every heading above resolves to a tag below. Keep them in step: a
     version with no tag has no diff a reader can follow, which is how
     0.1.0, 0.4.1, 0.5.0 and 0.9.1 ended up documented but unreachable. -->

[Unreleased]: https://github.com/godigi/netdiag/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/godigi/netdiag/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/godigi/netdiag/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/godigi/netdiag/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/godigi/netdiag/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/godigi/netdiag/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/godigi/netdiag/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/godigi/netdiag/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/godigi/netdiag/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/godigi/netdiag/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/godigi/netdiag/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/godigi/netdiag/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/godigi/netdiag/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/godigi/netdiag/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/godigi/netdiag/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/godigi/netdiag/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/godigi/netdiag/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/godigi/netdiag/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/godigi/netdiag/releases/tag/v0.1.0
