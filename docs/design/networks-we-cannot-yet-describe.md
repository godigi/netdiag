# Networks we cannot yet describe — design

**Date:** 2026-08-27
**Status:** proposed, nothing implemented
**Target version:** v0.11.0 onwards
**Scope:** A forward look, not a spec. Twenty network situations netdiag
currently answers wrongly, vaguely, or not at all — each with what it
says today, how macOS would let us detect it, and what rule it becomes.

---

## Why this document exists

The 38 rules in `--rules-catalog` cover the network netdiag was written
against: one Mac, one Wi-Fi radio or one cable, one router, one ISP, one
default route. Almost every rule assumes that shape.

The failures worth planning for are the ones where that assumption
quietly breaks and netdiag still answers **confidently**. A tool that
says "I don't know" is annoying; a tool that says "your ISP is slow"
when the real fault is a 100 Mb/s-negotiated Ethernet port has actively
sent the user to argue with the wrong company. Everything in Tier 1
below is that failure mode.

Each entry states what netdiag does **today** — verified against the
code at commit `31121ba`, not assumed — before proposing anything.

---

## Tier 1 — netdiag gives a confidently wrong answer

These are the ones to do first. They are not missing features; they are
existing rules firing on data that does not mean what the rule thinks.

### 1.1 A self-assigned address reads as a healthy link

**Today.** `linkstate_parse_ifconfig_ip` (`lib/linkstate.sh:42`) takes
the first `inet` address off `ifconfig`, whatever it is. A
`169.254.x.x` self-assigned address therefore sets `LINK_IP`, and
`linkstate_run` sets `LINK_UP=1` and returns — the loop stops looking.

So when DHCP fails and macOS falls back to a link-local address, netdiag
reports a link that is up and configured. The user sees "Wi-Fi
connected" and a pile of downstream failures with no cause named,
because the actual cause — *no DHCP server answered* — was recorded as
success.

This is the exact failure the link-state work was built to stop: the
whole point of `lib/linkstate.sh` is that "associated but unconfigured"
is a distinct state worth naming. Link-local is a third state and it is
currently folded into the healthy one.

**Detect.** `LINK_IP` starting `169.254.` — and, on IPv6, `fe80::` with
no global address. macOS also says so directly:
`ipconfig getsummary <dev>` reports the address source.

**Rule.** `DH-3` (critical, `dhcp`): "Your Mac asked this network for an
address and nothing answered, so it made one up. Nothing will work until
the router's DHCP server does." Distinct from `N1c` (joined, addressed,
no route — a captive portal) and from `DI-1` (no ARP at all).

**Cost.** Small. One predicate in `linkstate_run`, one rule, one field.

### 1.2 A worse interface wins the service order

**Today.** `linkstate_run` reads `networksetup -listnetworkserviceorder`
only as a *fallback*, when there is no default route (`lib/linkstate.sh:95`).
It takes the first active device and never compares it against the rest.
Nothing anywhere asks "is a better interface also up?"

This machine is a live example. Its service order is:

```
(1) XREAL One Pro          en5
(2) XREAL One Pro 2        en6
(3) Thunderbolt Bridge     bridge0
...                        Wi-Fi, iPhone USB
```

A pair of display glasses and a Thunderbolt bridge outrank the Wi-Fi
radio that is actually carrying the traffic. Docks, VM adapters
(VMware, Parallels, UTM), VPN clients and iPhone USB all insert
themselves near the top and stay there. When one of them is *active but
useless* — a bridge with a link and no DHCP, a dock whose upstream cable
is out — macOS keeps routing to it and the user gets a Mac that is "on
Wi-Fi" and cannot reach anything.

**Detect.** Walk the whole service order rather than stopping at the
first hit. Flag when the winning device is not the highest-ranked
device that holds a real (non-link-local) address, or when a
lower-ranked device has a working route and the winner does not.

**Rule.** `IF-1` (warn, `topology`): "Your Mac is sending traffic over
*X* even though *Y* is connected and higher priority. Reorder the
services in System Settings → Network → ⋯ → Set Service Order."

**Cost.** Medium. `linkstate_run` currently returns on the first good
device by design (for speed); this needs a second, cheap pass that only
runs when something already looks wrong.

### 1.3 A gigabit port negotiated at 100 Mb/s

**Today.** Nothing in `lib/` reads `ifconfig media` or
`networksetup -getmedia`. Verified: `grep -rn "getmedia\|baseT" lib/`
returns nothing.

A damaged pair in an Ethernet cable, or a cheap dock, drops a 1000BASE-T
link to 100BASE-TX — a 10× cap that is invisible everywhere except this
one line of `ifconfig`. The speed test then reports ~94 Mb/s and the
user calls their ISP about a gigabit plan that is being delivered
correctly.

Half-duplex is the same family and worse: a duplex mismatch produces
collisions and heavy loss that `G2`/`G3` will report as "router dropping
packets", pointing the user at the wrong box entirely.

**Detect.** `ifconfig <dev>` → `media: autoselect (100baseTX
<full-duplex>)`. The negotiated rate and duplex are both in that string.
Cross-check against the port's advertised capability with
`networksetup -listvalidmedia <service>`.

**Rule.** `ETH-1` (warn, `lan`): negotiated below the port's capability.
`ETH-2` (critical, `lan`): half duplex. Both should also *suppress*
`G2`/`G3`'s "reboot your router" advice, which is wrong here.

**Cost.** Small, and it is pure parsing — testable from fixtures with no
live network, like every other parser in `lib/linkstate.sh`.

### 1.4 The Wi-Fi link is the cap, not the ISP

**Today.** `lib/diagnosis.sh` never reads the speed result at all
(`grep -n "SPEED_DOWN" lib/diagnosis.sh` → nothing). Speed reaches the
user as a number and feeds `BL-1`'s baseline comparison, but no rule
attributes a slow number to a cause.

Meanwhile `lib/wifi_common.sh` already collects `tx_rate` and `phy` —
under sudo. So on a privileged run netdiag holds both halves of the
answer and joins neither: a 130 Mb/s PHY rate and a 95 Mb/s download is
a wireless cap, full stop, and no amount of ISP troubleshooting will
move it.

**Detect.** Data already collected. The rule is arithmetic: download
within ~70–80% of `tx_rate` (real 802.11 goodput is roughly half to
two-thirds of the PHY rate, so the exact fraction wants calibrating
against stored runs before it is fixed as a threshold).

**Rule.** `SP-1` (info, `speed`): "Your download is at the ceiling this
wireless link can carry — the limit is the Wi-Fi connection between your
Mac and the router, not your internet plan. Move closer, use 5 GHz, or
plug in."

**Cost.** Small, and it is the highest value-per-line item in this
document: one join over data already in hand, answering the single most
common wrong conclusion users draw.

### 1.5 Satellite, cellular and fixed-wireless judged as fibre

**Today.** `lib/thresholds.sh` has one set of cutoffs for every network.
Starlink's ~40 ms baseline with periodic obstruction dropouts, LTE/5G
FWA's variable latency, and any tethered cellular link are all
*healthy* behaviour for their medium and all trip terrestrial
thresholds. `WAN-1b` already recognises CGNAT and says "common on
cellular", so netdiag half-knows — it just does not act on it.

**Detect.** ASN and ISP name are already collected (`lib/public.sh`).
Starlink (AS14593), the major mobile carriers, and known FWA ranges are
identifiable. Weaker but medium-independent signals: an iPhone USB or
personal-hotspot service carrying the default route (1.12 below); a
first-hop RTT distribution with satellite's characteristic floor.

**Rule.** Not a rule — a **threshold profile**. This is the design
question in the document, and it collides with the project's hardest
constraint: cutoffs live in `lib/thresholds.sh` and nowhere else, and
four consumers must agree on them (`tests/test_thresholds.bats` enforces
it). A per-medium profile means `lib/thresholds.sh` exports a *set* and
something selects between sets — which is a change to the contract, not
an addition under it. Worth designing deliberately rather than reaching
for.

**Cost.** Large. Recommend deferring until 1.1–1.4 are done, but
recording the constraint now, because every threshold added before then
makes the eventual switch wider.

---

## Tier 2 — whole classes of network netdiag cannot see

Each of these makes a *measurement* meaningless rather than a rule
wrong. The unifying gap: netdiag equates "carries my traffic" with
"holds the default route", and macOS stopped honouring that equation
years ago.

### 2.1 Split-tunnel and per-app VPNs

`VPN-1` fires on the default route (`lib/vpn.sh`). A corporate
split-tunnel VPN deliberately does *not* take it: it installs routes for
the company's prefixes only. netdiag reports a perfectly healthy network
while every work application is broken, and says nothing about the one
component that is failing.

**Detect.** `netstat -rn` for non-default routes pointing at a `utun`;
`scutil --nc list` for configured services and their state.

**Rule.** `VPN-2` (info→warn): a tunnel is up and carrying *some*
destinations. Say which prefixes, and say plainly that this report does
not describe them.

### 2.2 iCloud Private Relay

Per-app, Safari-and-Mail only, no default route, no `utun` of its own.
Every measurement netdiag takes with `curl` bypasses it — so netdiag
reports the real ISP and real latency while the user's browser is going
through a completely different path and *feels* slow.

**Detect — prototyped 2026-08-27, mechanism proven, mapping is not.**
`NSPServiceStatusManagerInfo` under `com.apple.networkserviceproxy` is a
binary plist containing an `NSKeyedArchiver` graph. It decodes cleanly:

```python
inner = plistlib.loads(plistlib.loads(raw)["NSPServiceStatusManagerInfo"])
objs  = inner["$objects"]
root  = objs[inner["$top"]["ServiceStatus"].data]
root["PrivacyProxyServiceStatus"]      # → 0 on this machine
```

So the state is readable without sudo. What is *not* established is the
value mapping: this machine reads `0`, and Private Relay is off here, so
only "off" has been observed. Nobody has seen what "on" reads as.

**Therefore still no rule.** A rule that fires on a value never
observed is a rule that has never been tested, and the whole point of
this document is not shipping confident guesses. This is finishable in
about ten minutes by anyone with iCloud+ and Private Relay enabled:
read that key with it on, and with it off, and record both.

**A hard constraint when it is finished.** The same plist holds
`PrivacyProxyNetworkStatuses` — a *history* of every network the Mac
has joined, by name. That is a location trail: this developer's copy
names specific hotels and cafés. netdiag must read the scalar
`PrivacyProxyServiceStatus` and nothing else from this file. Reading
the network names, storing them, or emitting them would put a travel
history into `~/net-diag/baseline.jsonl` and into any shared report.

**Rule (when the mapping is known).** `PR-1` (info): browser traffic
takes a different path than everything measured here.

### 2.3 Encrypted DNS (DoH/DoT) via configuration profile

`D1`, `D3` and `D4` all measure the resolvers in `scutil --dns`. When a
configuration profile or a browser sets DNS-over-HTTPS, those resolvers
carry no traffic. netdiag then reports a sluggish or hijacked resolver
that the user is not using, or — worse — a *clean* one while the actual
DoH resolver is the thing failing.

**Detect.** `scutil --dns` reports DoH/DoT resolvers explicitly on
macOS 11+; profiles are listed by `profiles show -type configuration`
(no sudo needed for the user scope).

**Rule.** `D5` (info): name the encrypted resolver, and mark `D1`/`D3`/
`D4` as measuring a path that may not be in use.

### 2.4 Web proxy / PAC file

`networksetup -getwebproxy` and `-getautoproxyurl` are not read anywhere
(`grep -rn "getwebproxy" lib/` → nothing). On a managed Mac a PAC file
decides which destinations go direct and which go through a proxy, so
`tcp_reach`'s direct connections test a path real traffic never uses.

**Detect.** Both commands, per service. Cheap, no privileges.

**Rule.** `PX-1` (info→warn when the proxy is unreachable).

### 2.5 Third-party network filters

Zscaler, Netskope, Cloudflare WARP, Little Snitch and LuLu install
NetworkExtension content filters that sit in the datapath. When one
misbehaves it *is* the fault, and netdiag will attribute its symptoms to
the router or the ISP.

**Detect.** `systemextensionsctl list` names them and their state
(verified working without sudo on this machine — it lists camera and
driver extensions here, and would list `network_extension` ones the
same way).

**Rule.** `FW-1` (info, promoted to warn when traffic is failing): name
the filter and say it can cause exactly these symptoms. Worth being
careful with the wording — this must read as "here is something else in
the path", not as an accusation.

### 2.6 Tethering and metered links — and the money problem

`--speed` runs **by default**. On a personal hotspot or an iPhone USB
connection that spends the user's cellular allowance, potentially
hundreds of megabytes, without asking. That is not a diagnostic gap; it
is netdiag doing something the user would not have authorised.

The GUI makes it sharper: a first-sighting full check fires
automatically on joining a new network (`NetdiagCoordinator.swift:298`),
and joining a phone's hotspot is exactly that event.

**Detect.** The service name carrying the default route
(`iPhone USB`, `… Hotspot`) and the CGNAT/carrier ASN signals from 1.5.

**Rule + behaviour change.** `MTR-1` (info) names the metered link, and
— the important half — the speed test **skips by default** on it,
needing an explicit `--speed` to run. Same suppression in the GUI's
automatic first-sighting scan.

This one should probably jump the queue on grounds of user trust rather
than diagnostic value.

### 2.7 IPv6-only networks with NAT64/DNS64

Nothing in `lib/` or `helpers/` mentions NAT64, DNS64, CLAT or `64:ff9b`
(verified by grep). On an IPv6-only network — some mobile carriers,
some enterprise and university networks, a growing share of new
deployments — there is no IPv4 by design, and macOS's CLAT synthesises
it. netdiag's IPv4-centric checks would report a broken IPv4 stack that
is working exactly as intended.

`V6-1` covers the inverse (broken v6, working v4). This is the mirror
and it does not exist.

**Detect.** A global IPv6 address and no IPv4 default route; a DNS64
prefix visible in synthesised `AAAA` answers for a v4-only name.

**Rule.** `V6-3` (info): "This network is IPv6-only and your Mac is
translating — that is normal here, not a fault."

---

## Tier 3 — the measurement itself is unsound

Data-quality problems. They do not produce a wrong verdict so much as a
verdict about a network that never existed.

### 3.1 The network changed mid-run

A full check takes ~60 s. Walk out of Wi-Fi range onto Ethernet at
second 30 and the run blends two networks, then stamps the result with
one `network.id` and files it in one network's history — where it
becomes part of a baseline that `BL-1` will later judge against.

This is the same family as **NET.3**, which was fixed on the GUI side
(`0b24112`) by not marking a network seen until its scan actually
starts. The CLI half is unaddressed.

**Detect.** Capture the network identity at the start *and* the end of a
run; compare. `lib/netid.sh` already computes it.

**Handle.** Mark the record `partial` — `helpers/history.py` already has
the concept and already excludes partial runs from severity voting — and
say so in the report.

### 3.2 The Mac slept mid-monitor

`lib/monitor.sh:38` states the monitor "stays dumb about sleep and
battery" and leaves it to the GUI's `NSWorkspace` notifications. So a
lid closed for eight hours leaves a `--monitor` stream with an
eight-hour gap between consecutive samples. Anything reading that stream
without the GUI's context — `--monitor` piped to a script, which is its
documented purpose — sees an eight-hour outage.

**Detect.** Wall-clock delta between samples far exceeding the cadence.
Purely arithmetic, no new data source, and it belongs in the CLI so the
JSON is honest on its own.

**Handle.** Emit an explicit `gap` reason on the first sample after one,
rather than leaving the consumer to infer an outage.

### 3.3 A roam mid-run

`MON_PREV_BSSID` exists in `lib/monitor.sh:177`, so the monitor tracks
BSSID changes. A *scan* does not: roaming between two mesh APs during a
60 s check averages two radios' signal into one meaningless RSSI, and
`W1`/`W2` then judge a number that describes neither AP.

**Handle.** Same as 3.1 — compare BSSID at both ends, caveat rather than
report.

### 3.4 A second DHCP server

`DI-2`'s blurb *mentions* a rogue DHCP server as a possible cause of a
duplicate IP, but nothing detects one. Two servers answering is the more
common root cause (a second router left in router mode, a misconfigured
VM bridge) and produces intermittent, address-dependent breakage that
looks like nothing else in the catalog.

**Detect.** `ipconfig getpacket <dev>` gives the answering server's
identifier. Two runs disagreeing on it, or a lease whose server
identifier is not the gateway, is the tell — and netdiag stores every
run, so the history can answer this without a new probe.

### 3.5 The gateway's MAC changed

`lib/netid.sh` already stores `GW_MAC` and history already groups by it.
So netdiag can already see that the same SSID and subnet now has a
different gateway MAC — which is a router replacement, a failover to a
backup unit, or ARP spoofing. It has the data and draws no conclusion
from it.

**Rule.** `SEC-1` (info): state the change as a fact with both MACs and
the date. Deliberately *not* an accusation of attack — the benign
explanations are far more common, and a security scare from a network
tool is worse than silence.

---

## Tier 4 — Wi-Fi specifics

### 4.1 Stuck on 2.4 GHz

`lib/wifi_scan.sh` already records `WIFI_SCAN_CURRENT_BAND` and scans
the neighbourhood. Nothing checks whether the *same SSID* is also
present on 5 or 6 GHz with a usable signal. Band-steering failures are
common, invisible, and cost the user most of their throughput.

**Rule.** `WS-2` (warn): "You are on the slow 2.4 GHz band and this same
network has a strong 5 GHz radio available."

### 4.2 DFS radar channel-switch outage

On 5 GHz DFS channels a radar detection forces the AP off-channel for up
to 60 seconds. To the user it is a total outage with no cause; to
netdiag it is currently unexplained loss. `log show` carries the channel
switch announcement, and `lib/wifi_disconnect.sh` already greps that log
for a related pattern set.

**Rule.** `WD-2` (info): name the cause of an outage that would
otherwise be a mystery. Low frequency, very high explanatory value.

### 4.3 Private Wi-Fi Address churn

macOS randomises the client MAC per SSID by default and rotates it.
Networks with MAC allowlists, captive portals keyed to MAC, or strict
DHCP reservations then drop the user repeatedly — which surfaces as
`WD-1` flapping with no wireless cause, since signal and SNR are fine.

**Detect.** `networksetup -getMACAddress`-style comparison against the
Wi-Fi hardware MAC; the rotation itself is visible across stored runs.

### 4.4 The SSID macOS will not name — and NET.4

All three flapping episodes in **NET.4** are recorded against
`WiFi (SSID hidden by macOS)`, because macOS withholds the SSID from
unprivileged processes without Location Services. So three real
incidents cannot even be confirmed to be on the same network.

That investigation closed with "not reproducible — the logs are gone".
The lesson is not a fix, it is **instrumentation**: the data needed to
diagnose the next episode has to be captured while it happens, and
today nothing captures it.

**Handle.**

1. An `info` diagnosis when the SSID is unavailable, saying plainly that
   granting Location Services would let netdiag name networks — this is
   a data-completeness fact the user can act on, and it is the cheapest
   item here.
2. When `WD-1` fires, capture the untruncated disconnect lines into the
   stored record instead of the five the report shows.
3. RSSI, noise, SNR and channel are null in all three stored spikes
   because they need sudo. The GUI's investigation burst should note in
   the record that these were unavailable, so a future analysis knows
   the difference between "quiet" and "not measured".

---

## Recommended order

Everything above is a candidate; this is the argued shortlist.

1. **2.6 metered-link speed-test suppression** — trust, not diagnosis.
   netdiag currently spends the user's money without asking.
2. **1.1 self-assigned address** — smallest fix, removes a confidently
   wrong "healthy" verdict, sits directly in code just rewritten.
3. **1.4 Wi-Fi rate vs speed** — best value per line; the data is
   already collected and the wrong conclusion it prevents is the most
   common one users draw.
4. **1.3 Ethernet negotiation** — pure fixture-testable parsing, catches
   a 10× fault nothing else can see.
5. **4.4 / NET.4 instrumentation** — cheap, and it is the difference
   between diagnosing the next flapping episode and writing another
   "not reproducible" ticket.
6. **1.2 service order** — real and demonstrable on the author's own
   machine, but needs care not to slow the fast path.

Deferred deliberately: **1.5 threshold profiles**, because it changes
the `lib/thresholds.sh` contract rather than adding under it, and that
decision deserves its own document.

---

## The one structural idea

Six separate entries above (2.1–2.5, and 1.2) are the same bug wearing
different clothes: **netdiag assumes the default route is the path its
traffic takes.** Split tunnels, Private Relay, PAC proxies, content
filters and per-app VPNs all break that assumption, and each one
silently invalidates a different subset of the report.

Rather than five unrelated rules, the better shape is probably one
"what else is in the path" pass — a single check that enumerates the
proxies, tunnels, filters and resolvers macOS has installed, emits them
as facts, and lets individual rules declare which of their measurements
those facts undermine. That is a bigger design than any single rule here
and it is the thing most worth thinking about before writing any of
them.
