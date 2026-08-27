# Link State and Captive Portal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop netdiag claiming "no network at all" on a Mac that is joined to WiFi with full signal, and make a captive portal a first-class diagnosis in a scan rather than a monitor-only footnote.

**Architecture:** A new `lib/linkstate.sh` discovers the active interface, its link status, its address and its DHCP-offered router *without* consulting the default route, which is today the single source of truth for "do we have a network". `lib/iface.sh` consumes it, so `INTERFACE` survives a missing route and every downstream module (WiFi, DHCP, netid) keeps working. `N1` then splits into two rules — genuinely nothing joined (`N1`) versus joined-but-no-route (`N1c`, worded portal-first) — and `CP-1` gains a scan-mode call site with a body-aware canary probe. A new `D2` makes total resolver failure fire a rule so the GUI's DNS row turns red without a line of diagnostic logic moving into Swift.

**Tech Stack:** bash 5 / zsh-compatible shell, bats-core, Python 3 helpers, SwiftUI (read-only for this plan — no Swift changes are required).

---

## Background: the four defects

Evidence gathered 2026-08-27 from the user's screenshots and `~/net-diag/baseline.jsonl`:

1. **`lib/iface.sh:9-10` derives both `INTERFACE` and `GATEWAY` from one `route -n get default`.** `lib/wifi.sh:22` and `lib/dhcp.sh:10` gate on `$INTERFACE`, so a missing route erases WiFi, DHCP and network identity too. `lib/diagnosis.sh:26` then asserts the Mac "isn't joined to a WiFi network" — a claim netdiag never checked. Six of the last twelve stored runs are `N1` under `network_id: "unknown"`, including `2026-08-27T19:22:22Z`, while runs at 19:18 and 19:20 were filed against gateway `192.168.60.1` and that route is live now. The route flickers; netdiag reports total disconnection and pollutes per-network history.

2. **`CP-1` has no scan call site.** It exists only at `lib/monitor.sh:686`. `lib/public.sh:46` prints a warn *line* but never calls `add_diag`, so it never reaches `status.rules[]`, the GUI, or the exit code. `docs/DIAGNOSIS-RULES.md:565-577` argues a scan does not need it "because P1/P2 fire anyway" — and stored run `2026-08-26T22:53:05Z` shows the result: P1, *"almost certainly an outage on your ISP's side — check their status page or call support"*, on a network whose fix was a browser.

3. **The canary probe only detects redirects.** `captive_portal_classify` (`lib/common.sh:420-426`) maps 3xx→portal, 2xx→ok, everything else→unknown, and both callers pass `curl -o /dev/null` so the body is never read. Apple's own check compares the body to a literal success page. A portal answering 200 with its login HTML — very common, as is 511 — currently reports "No captive portal."

4. **`0 of 6 resolvers OK` renders with a green dot.** `RunReportView.swift:258` colors the row from rules; `D1` requires `PUBLIC_OK=1` (`lib/diagnosis.sh:127`), so with no internet nothing fires. Fixed in `lib/`, not Swift — CLAUDE.md forbids diagnostic logic in the GUI.

Facts confirmed on the machine, all free and all independent of the default route:

```
ifconfig en0            → status: active
ipconfig getsummary en0 → LinkStatusActive : TRUE
ipconfig getpacket en0  → router (ip_mult): {192.168.60.1}
networksetup -listnetworkserviceorder → ordered device list
```

---

## File Structure

**Create:**
- `lib/linkstate.sh` — link facts independent of the default route. Pure parsers plus one discovery function. Sourced by `bin/netdiag` before `lib/iface.sh`; safe to source standalone (depends on nothing).
- `tests/test_linkstate.bats` — parser unit tests over fixtures.
- `tests/fixtures/ifconfig_en0_active.txt`
- `tests/fixtures/ifconfig_en0_inactive.txt`
- `tests/fixtures/ipconfig_getpacket.txt`
- `tests/fixtures/networksetup_serviceorder.txt`
- `tests/fixtures/captive_apple_success.txt`
- `tests/fixtures/captive_apple_portal.txt`

**Modify:**
- `lib/globals.sh` — new `LINK_*` and `DHCP_ROUTER` globals
- `lib/thresholds.sh` — `THRESH_ROUTE_RECHECK_DELAY_S`
- `lib/iface.sh` — consume link state, re-check the route once before declaring it gone
- `lib/netid.sh` — fall back to `DHCP_ROUTER` so routeless runs stop filing as "unknown"
- `lib/common.sh:420-426` — body-aware `captive_portal_classify`
- `lib/public.sh:37-49` — capture the canary body; pass it to the classifier
- `lib/monitor.sh:548-556` — same
- `lib/diagnosis.sh` — `N1`/`N1c` split, `CP-1` scan call sites, `D2`, P1/P2 portal suppression
- `helpers/emit_json.py:342-348` — emit link state
- `helpers/rules_catalog.py` — `N1` blurb correction, new `N1c`, new `D2`, `CP-1` scope/severity
- `docs/DIAGNOSIS-RULES.md` — `N1` rewrite, `N1c`, `D2`, `CP-1` rationale correction
- `docs/JSON-SCHEMA.md` — `interface.link_*` fields
- `tests/test_monitor.bats:240` — drop the CP-1 exclusion
- `CHANGELOG.md`
- `examples/sample-output.{txt,json}` — regenerate

---

### Task 1: `lib/linkstate.sh` — link facts without the default route

**Files:**
- Create: `lib/linkstate.sh`
- Create: `tests/test_linkstate.bats`
- Create: `tests/fixtures/ifconfig_en0_active.txt`, `tests/fixtures/ifconfig_en0_inactive.txt`, `tests/fixtures/ipconfig_getpacket.txt`, `tests/fixtures/networksetup_serviceorder.txt`

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/ifconfig_en0_active.txt`:

```
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	options=6460<TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
	ether 5a:7e:c3:04:c9:da
	inet6 fe80::1cbb:9a1f:2c4d:88e1%en0 prefixlen 64 secured scopeid 0xc
	inet 10.125.129.35 netmask 0xfffffe00 broadcast 10.125.129.255
	nd6 options=201<PERFORMNUD,DAD>
	media: autoselect
	status: active
```

`tests/fixtures/ifconfig_en0_inactive.txt`:

```
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	options=6460<TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
	ether 5a:7e:c3:04:c9:da
	nd6 options=201<PERFORMNUD,DAD>
	media: none
	status: inactive
```

`tests/fixtures/ipconfig_getpacket.txt`:

```
op = BOOTREPLY
htype = 1
flags = 0x0
hlen = 6
hops = 0
xid = 0x807ce711
secs = 0
ciaddr = 0.0.0.0
yiaddr = 10.125.129.35
siaddr = 10.125.128.1
giaddr = 0.0.0.0
chaddr = 5a:7e:c3:4:c9:da
sname = 
file = 
options:
Options count is 9
dhcp_message_type (uint8): ACK 0x5
server_identifier (ip): 10.125.128.1
lease_time (uint32): 0x15180
renewal_t1_time_value (uint32): 0xa8c0
rebinding_t2_time_value (uint32): 0x12750
subnet_mask (ip): 255.255.254.0
domain_name_server (ip_mult): {10.125.128.1, 10.125.128.2}
router (ip_mult): {10.125.128.1}
end (none): 
```

`tests/fixtures/networksetup_serviceorder.txt`:

```
An asterisk (*) denotes that a network service is disabled.
(1) XREAL One Pro
(Hardware Port: XREAL One Pro, Device: en5)

(2) Thunderbolt Bridge
(Hardware Port: Thunderbolt Bridge, Device: bridge0)

(3) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)

(4) iPhone USB
(Hardware Port: iPhone USB, Device: en4)

```

- [ ] **Step 2: Write the failing test**

Create `tests/test_linkstate.bats`:

```bash
#!/usr/bin/env bats
#
# Unit tests for lib/linkstate.sh — the parsers that answer "is this Mac
# actually joined to something?" without asking for the default route.
#
# These exist because the whole N1 defect was a missing distinction: a
# machine with WiFi switched off and a machine sitting on a hotel network
# that has not handed out a route produced byte-identical netdiag state.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  # shellcheck source=../lib/linkstate.sh
  . "$REPO/lib/linkstate.sh"
}

@test "linkstate: ifconfig 'status: active' parses as active" {
  run linkstate_parse_ifconfig_status "$(cat "$FIX/ifconfig_en0_active.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "active" ]
}

@test "linkstate: ifconfig 'status: inactive' parses as inactive" {
  run linkstate_parse_ifconfig_status "$(cat "$FIX/ifconfig_en0_inactive.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "inactive" ]
}

@test "linkstate: a device with no status line parses as empty, not active" {
  run linkstate_parse_ifconfig_status "lo0: flags=8049<UP,LOOPBACK> mtu 16384"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "linkstate: the IPv4 address comes from the inet line, not inet6" {
  run linkstate_parse_ifconfig_ip "$(cat "$FIX/ifconfig_en0_active.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "10.125.129.35" ]
}

@test "linkstate: no inet line yields an empty address" {
  run linkstate_parse_ifconfig_ip "$(cat "$FIX/ifconfig_en0_inactive.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "linkstate: the DHCP router option parses out of getpacket" {
  run linkstate_parse_dhcp_router "$(cat "$FIX/ipconfig_getpacket.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "10.125.128.1" ]
}

@test "linkstate: only the first router is taken when several are offered" {
  run linkstate_parse_dhcp_router 'router (ip_mult): {10.0.0.1, 10.0.0.2}'
  [ "$status" -eq 0 ]
  [ "$output" = "10.0.0.1" ]
}

@test "linkstate: a lease with no router option yields empty" {
  run linkstate_parse_dhcp_router 'subnet_mask (ip): 255.255.255.0'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "linkstate: service order yields devices in order, deduped" {
  run linkstate_parse_service_devices "$(cat "$FIX/networksetup_serviceorder.txt")"
  [ "$status" -eq 0 ]
  [ "$output" = "en5
bridge0
en0
en4" ]
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bats tests/test_linkstate.bats`
Expected: every test FAILs — `lib/linkstate.sh` does not exist, so `setup` errors with "No such file or directory".

- [ ] **Step 4: Write `lib/linkstate.sh`**

```bash
# shellcheck shell=bash
# lib/linkstate.sh — what the Mac is actually joined to, answered without
# asking for the default route.
#
# Why this file exists: lib/iface.sh derived both INTERFACE and GATEWAY
# from one `route -n get default`, and lib/wifi.sh, lib/dhcp.sh and
# lib/netid.sh all gate on INTERFACE. A missing default route therefore
# erased the SSID, the signal strength, the lease and the network identity
# along with the route — and N1 went on to tell the user their Mac "isn't
# joined to a WiFi network", a claim nothing in the run had checked. On a
# hotel network with a sign-in page, and on any network where the route
# flickers, that sentence is simply false.
#
# macOS will tell you the truth for free, three different ways, none of
# which involves the routing table:
#
#   ifconfig <dev>            → "status: active" once the link is up
#   ipconfig getifaddr <dev>  → the leased IPv4 address
#   ipconfig getpacket <dev>  → the DHCP ACK, including the router option
#
# "Joined but with no route" is a real and distinct network state, and it
# is the one a captive portal produces. Naming it is the whole point.
#
# Every parser takes its input as $1 rather than re-running the
# subprocess, so the callers keep control of caching and the tests can
# feed fixtures. Depends on nothing; safe to source standalone.
#
# Writes (via linkstate_run): LINK_DEVICE, LINK_STATUS, LINK_IP,
#                             LINK_DHCP_ROUTER, LINK_UP
# Entry: linkstate_run

# "active" / "inactive" / "" from `ifconfig <dev>` output ($1).
# Empty rather than "inactive" when there is no status line at all: a
# device that never reports one (lo0, utun*) is not the same as one that
# reports itself down, and the caller must be able to tell them apart.
linkstate_parse_ifconfig_status() {
  printf '%s\n' "$1" | awk '/^[[:space:]]*status:/{print $2; exit}'
}

# The IPv4 address from `ifconfig <dev>` output ($1), or empty.
# Anchored on "inet" as a whole word so the inet6 line can never match.
linkstate_parse_ifconfig_ip() {
  printf '%s\n' "$1" | awk '$1=="inet"{print $2; exit}'
}

# The first router the DHCP server offered, from `ipconfig getpacket <dev>`
# output ($1), or empty.
#
# The option is printed as `router (ip_mult): {10.0.0.1, 10.0.0.2}`. Only
# the first is taken: netdiag has exactly one notion of "the router", and
# a second one would have to be surfaced as a separate fact rather than
# silently substituted for the first.
linkstate_parse_dhcp_router() {
  printf '%s\n' "$1" | awk -F'[{}]' '
    /^[[:space:]]*router[[:space:]]*\(/ {
      split($2, a, ",")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[1])
      print a[1]
      exit
    }'
}

# Every device named in `networksetup -listnetworkserviceorder` output
# ($1), in service order, one per line. Order matters: it is macOS's own
# preference ranking, so the first active device in this list is the best
# available answer to "which interface is this Mac using" when there is no
# default route to ask.
linkstate_parse_service_devices() {
  printf '%s\n' "$1" | awk '
    match($0, /Device: [^)]+/) {
      d = substr($0, RSTART + 8, RLENGTH - 8)
      if (!(d in seen)) { seen[d] = 1; print d }
    }'
}

# Discover the link. $1 = optional device to check first (the default
# route's interface, when there is one) — checked before the service
# order so the fast path costs one ifconfig and nothing else.
#
# Sets LINK_DEVICE / LINK_STATUS / LINK_IP / LINK_DHCP_ROUTER / LINK_UP.
# LINK_UP is 1 only when a device is BOTH active AND holds an address:
# an active radio with no lease is associated but unconfigured, which is
# a fault worth naming, not a working link.
#
# Writes globals read by lib/iface.sh, lib/diagnosis.sh and emit_json.py.
# shellcheck disable=SC2034
linkstate_run() {
  local preferred="${1:-}" devices dev out
  LINK_DEVICE=""; LINK_STATUS=""; LINK_IP=""; LINK_DHCP_ROUTER=""; LINK_UP=0

  devices="$preferred"
  # The service order is only read when the preferred device did not
  # settle it, because networksetup costs ~100 ms and the overwhelming
  # majority of runs have a default route.
  if [ -z "$preferred" ]; then
    devices="$(linkstate_parse_service_devices \
      "$(networksetup -listnetworkserviceorder 2>/dev/null || true)")"
  fi

  for dev in $devices; do
    out="$(ifconfig "$dev" 2>/dev/null || true)"
    [ -n "$out" ] || continue
    local status ip
    status="$(linkstate_parse_ifconfig_status "$out")"
    [ "$status" = "active" ] || continue
    ip="$(linkstate_parse_ifconfig_ip "$out")"
    LINK_DEVICE="$dev"
    LINK_STATUS="$status"
    LINK_IP="$ip"
    LINK_DHCP_ROUTER="$(linkstate_parse_dhcp_router \
      "$(ipconfig getpacket "$dev" 2>/dev/null || true)")"
    # An active device with an address ends the search. An active device
    # without one is remembered — it is still the best candidate we have,
    # and "associated but no address" is exactly the DHCP failure the
    # N1c rule needs to be able to describe — but the loop keeps looking
    # in case a later service is fully configured.
    if [ -n "$ip" ]; then
      LINK_UP=1
      return 0
    fi
  done
  return 0
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/test_linkstate.bats`
Expected: 9 tests, all PASS.

- [ ] **Step 6: Run shellcheck**

Run: `shellcheck -x lib/linkstate.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add lib/linkstate.sh tests/test_linkstate.bats tests/fixtures/ifconfig_en0_active.txt tests/fixtures/ifconfig_en0_inactive.txt tests/fixtures/ipconfig_getpacket.txt tests/fixtures/networksetup_serviceorder.txt
git commit -m "feat(linkstate): discover the link without the default route

macOS reports association, address and DHCP router independently of the
routing table. netdiag asked only the routing table, so a missing route
erased the SSID and the lease too."
```

---

### Task 2: Wire link state into `iface_run`, with a re-check before declaring the route gone

**Files:**
- Modify: `lib/globals.sh:15-19`
- Modify: `lib/thresholds.sh` (append a new section)
- Modify: `lib/iface.sh:7-27`
- Test: `tests/test_linkstate.bats` (append)

- [ ] **Step 1: Add the globals**

In `lib/globals.sh`, replace lines 15-19:

```bash
# Interface / gateway (set by lib/iface.sh)
INTERFACE=""
LOCAL_IP=""
GATEWAY=""
GW_COUNT=0
```

with:

```bash
# Interface / gateway (set by lib/iface.sh)
INTERFACE=""
LOCAL_IP=""
GATEWAY=""
GW_COUNT=0

# Link state (lib/linkstate.sh, consumed by lib/iface.sh) — deliberately
# separate from GATEWAY above, which means one specific thing: "the
# gateway of the default route". These say whether the Mac is joined to
# anything at all, which is a different question and the one N1 was
# answering wrong. See lib/linkstate.sh's header.
LINK_DEVICE=""           # active device, found without the routing table
LINK_STATUS=""           # ifconfig's own word: active | inactive | ""
LINK_IP=""               # IPv4 address on LINK_DEVICE
LINK_DHCP_ROUTER=""      # router the DHCP server offered, route or no route
LINK_UP=0                # 1 = active device holding an address
```

- [ ] **Step 2: Add the threshold**

Append to `lib/thresholds.sh`:

```bash
# ── Default-route re-check [N1, N1c] ─────────────────────────────────────
# How long to wait before re-reading the routing table when the first read
# came back with no default route.
#
# Why this exists: six of twelve consecutive stored runs on this developer's
# machine fired N1 — "no network connection at all" — and were filed under
# network_id "unknown", while runs two minutes either side of them were
# filed against a live gateway on the same network. The route flickers
# during a DHCP renewal, a WiFi roam, or macOS re-evaluating a service, and
# a single unlucky read turned that into the most alarming verdict netdiag
# can produce plus a junk entry in the per-network history.
#
# One second: long enough to outlast a transition, short enough that the
# --quick budget survives it. Paid only on the failing path, which is rare
# by construction — a network with a route never reaches the re-read.
THRESH_ROUTE_RECHECK_DELAY_S=1
```

- [ ] **Step 3: Write the failing test**

Append to `tests/test_linkstate.bats`:

```bash
# ── iface_run: the route is one input, not the only one ──────────────────

iface_setup() {
  JSON_MODE=0 QUIET=0 QUICK=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/iface.sh
  . "$REPO/lib/iface.sh"
}

@test "iface: a joined link with no default route keeps INTERFACE and reports LINK_UP" {
  iface_setup
  # No default route, but en0 is active and holds a lease.
  route() { return 1; }
  netstat() { return 1; }
  ifconfig() { cat "$FIX/ifconfig_en0_active.txt"; }
  ipconfig() {
    case "$1" in
      getpacket) cat "$FIX/ipconfig_getpacket.txt" ;;
      getifaddr) printf '10.125.129.35\n' ;;
    esac
  }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }
  export -f route netstat ifconfig ipconfig networksetup

  iface_run >/dev/null
  [ "$GATEWAY" = "" ]
  [ "$LINK_UP" -eq 1 ]
  [ "$INTERFACE" = "en0" ]
  [ "$LOCAL_IP" = "10.125.129.35" ]
  [ "$LINK_DHCP_ROUTER" = "10.125.128.1" ]
}

@test "iface: nothing joined leaves LINK_UP at zero" {
  iface_setup
  route() { return 1; }
  netstat() { return 1; }
  ifconfig() { cat "$FIX/ifconfig_en0_inactive.txt"; }
  ipconfig() { return 1; }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }
  export -f route netstat ifconfig ipconfig networksetup

  iface_run >/dev/null
  [ "$LINK_UP" -eq 0 ]
  [ "$INTERFACE" = "" ]
  [ "$LINK_DHCP_ROUTER" = "" ]
}

@test "iface: the route is re-read once before it is called missing" {
  iface_setup
  # First read returns nothing, second returns a real route — the flicker
  # this re-check exists for.
  ROUTE_CALLS_FILE="$BATS_TEST_TMPDIR/route_calls"
  printf '0' > "$ROUTE_CALLS_FILE"
  route() {
    local n
    n="$(cat "$ROUTE_CALLS_FILE")"
    printf '%s' "$((n + 1))" > "$ROUTE_CALLS_FILE"
    [ "$n" -eq 0 ] && return 0
    printf 'gateway: 10.125.128.1\ninterface: en0\n'
  }
  netstat() { return 1; }
  ifconfig() { cat "$FIX/ifconfig_en0_active.txt"; }
  ipconfig() {
    case "$1" in
      getpacket) cat "$FIX/ipconfig_getpacket.txt" ;;
      getifaddr) printf '10.125.129.35\n' ;;
    esac
  }
  networksetup() { cat "$FIX/networksetup_serviceorder.txt"; }
  export -f route netstat ifconfig ipconfig networksetup THRESH_ROUTE_RECHECK_DELAY_S=0

  THRESH_ROUTE_RECHECK_DELAY_S=0 iface_run >/dev/null
  [ "$GATEWAY" = "10.125.128.1" ]
  [ "$(cat "$ROUTE_CALLS_FILE")" -ge 2 ]
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bats tests/test_linkstate.bats`
Expected: the three new tests FAIL — `iface_run` sets no `LINK_*` variables and reads the route exactly once.

- [ ] **Step 5: Rewrite `lib/iface.sh`**

Replace the whole file:

```bash
# shellcheck shell=bash
# lib/iface.sh — local interface, IP, default gateway.
#
# The default route is ONE input here, not the definition of "connected".
# It used to be both: INTERFACE and GATEWAY were two awk passes over one
# `route -n get default`, and lib/wifi.sh, lib/dhcp.sh and lib/netid.sh all
# gate on INTERFACE — so a Mac sitting on a hotel network with a strong
# signal and a valid lease, but no route yet, reported no interface, no
# SSID, no lease and no network identity, and N1 told the user their WiFi
# was off. lib/linkstate.sh answers the association question separately;
# this file merges the two views.
#
# Reads:  THRESH_ROUTE_RECHECK_DELAY_S
# Writes: INTERFACE, LOCAL_IP, GATEWAY, GW_COUNT,
#         LINK_DEVICE, LINK_STATUS, LINK_IP, LINK_DHCP_ROUTER, LINK_UP
# Entry:  iface_run

# shellcheck source=lib/linkstate.sh
. "$(dirname "${BASH_SOURCE[0]}")/linkstate.sh"

# Writes LINK_* via linkstate_run — read in diagnosis.sh / netid.sh /
# emit_json.py, none of which shellcheck can follow from here.
# shellcheck disable=SC2034
iface_run() {
  hdr "Local network"

  local route_out
  route_out="$(route -n get default 2>/dev/null || true)"
  INTERFACE="$(printf '%s\n' "$route_out" | awk '/interface:/{print $2; exit}')"
  GATEWAY="$(printf '%s\n' "$route_out" | awk '/gateway:/{print $2; exit}')"

  # A missing default route is the single most alarming thing netdiag can
  # observe, and it is also the one most likely to be a transient: DHCP
  # renewals, WiFi roams and macOS re-evaluating a network service all
  # drop it for a moment. Read it once more before believing it. See
  # THRESH_ROUTE_RECHECK_DELAY_S for the evidence this is not theoretical.
  if [ -z "$GATEWAY" ]; then
    sleep "$THRESH_ROUTE_RECHECK_DELAY_S"
    route_out="$(route -n get default 2>/dev/null || true)"
    INTERFACE="$(printf '%s\n' "$route_out" | awk '/interface:/{print $2; exit}')"
    GATEWAY="$(printf '%s\n' "$route_out" | awk '/gateway:/{print $2; exit}')"
  fi

  # Association, address and DHCP router — none of which needs a route.
  # Seeded with the route's own interface when there is one, so the common
  # case costs a single ifconfig.
  linkstate_run "$INTERFACE"

  # With no route, the link's own device is the interface. Everything
  # downstream (WiFi, DHCP, netid) keys off INTERFACE, and on a portal
  # network those checks have real answers to give.
  [ -z "$INTERFACE" ] && INTERFACE="$LINK_DEVICE"

  LOCAL_IP=""
  if [ -n "$INTERFACE" ]; then
    LOCAL_IP="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null)"
  fi
  [ -z "$LOCAL_IP" ] && LOCAL_IP="$LINK_IP"

  if [ -n "$INTERFACE" ] && [ -n "$GATEWAY" ]; then
    ok "Interface: $INTERFACE   IP: ${LOCAL_IP:-?}   Gateway: $GATEWAY"
  elif [ "$LINK_UP" -eq 1 ]; then
    # Joined and addressed, but nothing to route through. Stated as the
    # fact it is; N1c in lib/diagnosis.sh does the interpreting.
    warn "Interface: $INTERFACE   IP: ${LOCAL_IP:-?}   no default route — the network has not given this Mac a way out."
    [ -n "$LINK_DHCP_ROUTER" ] && info "Router offered by DHCP: $LINK_DHCP_ROUTER"
  elif [ -n "$LINK_DEVICE" ]; then
    bad "Interface: $LINK_DEVICE is up but has no address — joined to nothing, or DHCP never answered."
  else
    bad "No active network interface — nothing is joined."
  fi

  # Additional gateways (multi-homed?)
  GW_COUNT="$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2}' | sort -u | wc -l | tr -d ' ')"
  if [ "${GW_COUNT:-0}" -gt 1 ]; then
    warn "Multiple default gateways detected:"
    netstat -rn -f inet | awk '$1=="default"{print "      "$2"  ("$NF")"}' | log_pipe
  fi
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats tests/test_linkstate.bats`
Expected: 12 tests, all PASS.

- [ ] **Step 7: Fall back to the DHCP router in `netid_run`**

In `lib/netid.sh`, replace:

```bash
  # Only fall back to the gateway IP when nothing stronger identified the
  # network — on its own it's a near-guaranteed collision across sites.
  if [ -z "$parts" ] && [ -n "$GATEWAY" ]; then
    parts="gw=$GATEWAY"
  fi
```

with:

```bash
  # Only fall back to the gateway IP when nothing stronger identified the
  # network — on its own it's a near-guaranteed collision across sites.
  #
  # LINK_DHCP_ROUTER is the second fallback rather than a peer of GATEWAY
  # because it names the same box by a weaker route: the DHCP server said
  # so, rather than the kernel having installed a route to it. It exists
  # here because without it every routeless run filed itself under the
  # synthetic "unknown" network — six of twelve consecutive runs on this
  # developer's machine — which put "no network at all" verdicts into a
  # history bucket shared by every other routeless run on every other
  # network, and kept them out of the bucket for the network actually
  # being diagnosed.
  if [ -z "$parts" ]; then
    if [ -n "$GATEWAY" ]; then
      parts="gw=$GATEWAY"
    elif [ -n "$LINK_DHCP_ROUTER" ]; then
      parts="gw=$LINK_DHCP_ROUTER"
    fi
  fi
```

Also extend the file header's `Reads:` line from:

```bash
# Reads:  IS_WIFI, WIFI_SSID, GW_MAC, GATEWAY, INTERFACE
```

to:

```bash
# Reads:  IS_WIFI, WIFI_SSID, GW_MAC, GATEWAY, LINK_DHCP_ROUTER, INTERFACE
```

- [ ] **Step 8: Verify the existing suite still passes**

Run: `bats tests/test_parse.bats tests/test_history.bats tests/test_monitor.bats`
Expected: all PASS except the one known pre-existing failure (NET.2 in `tests/test_regressions.bats`, which is not in this list). If `test_history.bats` fails on netid/group_key parity, the `group_key()` side in `helpers/history.py` needs the same `gw=` fallback — it already keys on the `gw=` prefix, so no change should be needed; confirm by reading the failure.

- [ ] **Step 9: Run shellcheck**

Run: `shellcheck -x bin/netdiag lib/*.sh`
Expected: no output, exit 0.

- [ ] **Step 10: Commit**

```bash
git add lib/globals.sh lib/thresholds.sh lib/iface.sh lib/netid.sh tests/test_linkstate.bats
git commit -m "fix: a missing default route no longer erases the interface

iface_run now merges the routing table with lib/linkstate.sh's view, and
re-reads the route once before calling it gone. Routeless runs keep their
SSID, lease and network identity instead of filing under 'unknown'."
```

---

### Task 3: Split N1 — "nothing joined" versus "joined, no route"

**Files:**
- Modify: `lib/diagnosis.sh:20-36`
- Modify: `helpers/rules_catalog.py` (N1 blurb, new N1c)
- Modify: `docs/DIAGNOSIS-RULES.md:35-48`
- Test: `tests/test_parse.bats` (append after the existing N1 block)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_parse.bats`, immediately after the `"diagnosis: a present GATEWAY does not trip N1"` test:

```bash
@test "diagnosis: joined with no route is N1c, and does not claim WiFi is off" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=1 IS_WIFI=1 WIFI_SSID="Mercure" WIFI_RSSI=-44
  LINK_DHCP_ROUTER="10.125.128.1"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "N1c" ]
  [ "$MAX_SEVERITY" -eq 2 ]
  [[ "${DIAG[0]}" == *"Mercure"* ]]
  [[ "${DIAG[0]}" == *"10.125.128.1"* ]]
  [[ "${DIAG[0]}" != *"isn't joined to a WiFi network"* ]]
}

@test "diagnosis: joined with no route on ethernet names no SSID" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=1 IS_WIFI=0 LINK_DHCP_ROUTER="192.168.1.1"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "N1c" ]
  [[ "${DIAG[0]}" == *"192.168.1.1"* ]]
}

@test "diagnosis: nothing joined is still N1, not N1c" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  [ "${DIAG_RULE[0]}" = "N1" ]
  [ "$MAX_SEVERITY" -eq 2 ]
}

@test "diagnosis: N1c and N1 are mutually exclusive" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="" LINK_UP=1 IS_WIFI=1 WIFI_SSID="Mercure"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local joined=" ${DIAG_RULE[*]} "
  [[ "$joined" != *" N1 "* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_parse.bats -f "N1c"`
Expected: FAIL — `DIAG_RULE[0]` is `N1`, no rule `N1c` exists.

- [ ] **Step 3: Rewrite the N1 block in `lib/diagnosis.sh`**

Replace lines 20-36 (the `# N1 — no usable network at all` block through its closing `fi`) with:

```bash
  # N1 / N1c — no usable network. Every rule below keys off a measurement
  # that only exists once there IS a link, so without this the most basic
  # failure mode (WiFi off, cable unplugged) fired zero rules and the run
  # ended with "Nothing obviously wrong — your network looks healthy" and
  # exit 0, on a machine with no network whatsoever.
  #
  # The split exists because those two sentences describe opposite
  # situations and N1 used to say the first one in both. "No default
  # route" was read as "nothing is connected", so a Mac sitting on a hotel
  # network at -44 dBm with a valid DHCP lease was told it "isn't joined
  # to a WiFi network and has no working ethernet link" — while the same
  # report, three lines higher, printed the SSID and the signal strength.
  # LINK_UP (lib/linkstate.sh) is what tells them apart.
  #
  # N1c leads with the sign-in page rather than listing causes evenly,
  # because among networks that hand out an address and withhold a route
  # the portal is far and away the most common, and it is the only cause
  # with an action the user can take right now. The other causes follow in
  # the same sentence — the rule states what was observed, then what to
  # try, and never claims a portal was detected. CP-1 below is the rule
  # that gets to make that claim, and only when the probe confirms it.
  if [ -z "$GATEWAY" ] && [ "${LINK_UP:-0}" -eq 1 ]; then
    local _where _router_hint
    if [ "${IS_WIFI:-0}" -eq 1 ] && [ -n "${WIFI_SSID:-}" ] && [ "$WIFI_SSID" != "<redacted>" ]; then
      _where="You're connected to the WiFi network \"$WIFI_SSID\""
    elif [ "${IS_WIFI:-0}" -eq 1 ]; then
      _where="You're connected to WiFi"
    else
      _where="Your ethernet cable is connected"
    fi
    _router_hint="ask the network's owner"
    [ -n "${LINK_DHCP_ROUTER:-}" ] && _router_hint="try http://${LINK_DHCP_ROUTER} in a browser"
    add_diag critical N1c "$_where and it gave your Mac an address, but no way out to the internet. Networks in hotels, airports, cafés and offices usually do this until you open a browser and pass their sign-in or terms page — so start there: $_router_hint. If there's no sign-in page, the network handed out an address without a working route, and only its owner can fix that."
  elif [ -z "$GATEWAY" ]; then
    add_diag critical N1 "Your Mac has no network connection at all — nothing is joined and no cable is carrying a link. Turn WiFi on and pick a network, or check that the ethernet cable is seated at both ends. Nothing else can be diagnosed until this is fixed."
  elif [ "${PUBLIC_CHECKED:-0}" -eq 1 ] && [ "$PUBLIC_OK" -eq 0 ] && [ -z "$GW_LOSS" ]; then
    # Reachable only from a focused run (--mtu-only), where the gateway
    # section is skipped so P1/P2 below can't evaluate. PUBLIC_CHECKED
    # gates it because --wifi-only never runs public_run at all, and the
    # untouched PUBLIC_OK=0 default made this critical fire — exit 2 — on
    # a network whose internet was fine.
    local _rerun="Re-run plain \`netdiag\`"
    [ -n "${FOCUS:-}" ] && _rerun="$_rerun (without --${FOCUS}-only)"
    add_diag critical N1b "Your Mac has a router but nothing on the public internet responded. $_rerun for a full picture — it will tell you whether the problem is your router, your ISP, or DNS."
  fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test_parse.bats`
Expected: all PASS, including the pre-existing `"diagnosis: empty GATEWAY yields a critical and MAX_SEVERITY 2"` — that test sets only `GATEWAY=""`, so `LINK_UP` defaults to 0 from `globals.sh` and it takes the `N1` branch. Its assertion is `[[ "$output" == *"no network connection at all"* ]]`, which the new N1 text still contains.

- [ ] **Step 5: Add `N1c` to the rules catalog**

In `helpers/rules_catalog.py`, replace the `N1` entry's blurb (it currently claims the Mac "isn't joined to a WiFi network", which is now `N1`'s narrow case and must stop being stated as the meaning of a missing route):

```python
    {
        "id": "N1",
        "title": "No network connection at all",
        "category": "router",
        "severity": "critical",
        "scope": "both",
        "blurb": (
            "Nothing is joined: no WiFi network is associated and no "
            "ethernet cable is carrying a link. Nothing else can be "
            "diagnosed until basic connectivity exists. Turn WiFi on and "
            "pick a network, or check that the ethernet cable is seated "
            "at both ends."
        ),
        "doc": "DIAGNOSIS-RULES.md#n1--no-network-at-all",
    },
```

and insert immediately after the `N1b` entry:

```python
    {
        "id": "N1c",
        "title": "Joined to a network with no route out",
        "category": "router",
        "severity": "critical",
        "scope": "scan",
        "blurb": (
            "Your Mac is associated and holds an address from this "
            "network, but the network has given it no route to the "
            "internet. Hotel, airport, café and office WiFi usually "
            "withhold one until you open a browser and pass a sign-in or "
            "terms page. Failing that, the network handed out an address "
            "without a working route, which only its owner can fix."
        ),
        "doc": "DIAGNOSIS-RULES.md#n1c--joined-with-no-route-out",
    },
```

- [ ] **Step 6: Document both rules**

In `docs/DIAGNOSIS-RULES.md`, replace the whole `### N1 — No network at all` section (lines 35-48, ending just before `### W1 — Weak WiFi signal`) with:

```markdown
### N1 — No network at all

**Fires when:** `GATEWAY` is empty **and** `LINK_UP` is 0 — no default
route, and no active interface holding an address.

**Severity:** critical.

Every other rule keys off a measurement that only exists once there is a
link — gateway loss, public reachability, DNS answers. Before this rule
existed, a Mac with WiFi switched off produced *zero* diagnoses and
exited 0 with "Nothing obviously wrong — your network looks healthy",
because each rule's guard (`[ -n "$GW_LOSS" ]` and friends)
short-circuited on the missing data. N1 is the floor: it fires first,
states the obvious, and makes the exit code 2.

**The `LINK_UP` condition is load-bearing and was added after the fact.**
N1 originally fired on the missing route alone and told the user their Mac
"isn't joined to a WiFi network and has no working ethernet link" — a
claim nothing in the run had checked, and one the same report contradicted
three lines higher by printing the SSID and the signal strength. See N1c.

A second, narrower branch covers focused runs: `--mtu-only` skips the
gateway section, so `PUBLIC_OK=0` with an empty `GW_LOSS` can't reach P1
or P2. That branch (N1b) points the user at a full run rather than
guessing.

### N1c — Joined with no route out

**Fires when:** `GATEWAY` is empty **and** `LINK_UP` is 1 — an active
interface holding an address, with no default route.

**Severity:** critical. The network is unusable, which is what critical
means; the fact that the fix may be thirty seconds in a browser doesn't
make the current state any less broken.

**Evidence:** the SSID (or "ethernet"), and `LINK_DHCP_ROUTER` when the
DHCP server offered one.

**Recommendation:** open a browser and pass the network's sign-in page,
starting at `http://<LINK_DHCP_ROUTER>`.

**Rationale.** "Address but no route" is a real and distinct network
state, and the overwhelmingly most common cause of it is a captive portal
that hasn't been passed. N1c leads with that rather than enumerating
causes evenly, because it is also the only cause the user can act on
without finding the network's owner.

**N1c never claims a portal was detected.** It cannot: with no default
route the canary at `captive.apple.com` is unreachable, so there is
nothing to detect. It says what was observed — joined, addressed, no
route — and then says what to try. CP-1 is the rule that gets to assert a
portal, and only when the probe confirms one.

**Why the DHCP router is quoted rather than the (absent) gateway.**
`ipconfig getpacket` carries the router option whether or not the kernel
installed a route to it, so on exactly the networks where N1c fires there
is still a concrete address to point a browser at. `lib/linkstate.sh`
parses it; `lib/netid.sh` also uses it as a last-resort identity so these
runs stop filing under the synthetic "unknown" network.
```

- [ ] **Step 7: Verify the catalog tests pass**

Run: `bats tests/test_rules_catalog.bats`
Expected: all PASS. The scope-derivation test now sees `N1c` at an `add_diag` site only, matching `"scope": "scan"`; the blurb test sees no digits with units in the new text.

- [ ] **Step 8: Verify monitor parity still holds**

Run: `bats tests/test_monitor.bats`
Expected: all PASS. The `"parity: no default route is N1 on both"` test sets `GATEWAY=""` without `LINK_UP`, which defaults to 0, so the scanner still produces `N1` and matches the monitor. Add a clarifying comment to that test so the coupling is not accidental:

```bash
@test "parity: no default route is N1 on both" {
  # LINK_UP is deliberately left at its zero default: this is the
  # "nothing joined" case. The joined-but-routeless case is N1c, which is
  # scan-only — the monitor has no lib/linkstate.sh view — and so is
  # outside MONITOR_VOCABULARY by design.
  reset_state; MON_LINK_UP=0 GATEWAY=""
  local m; m="$(monitor_rules)"; reset_state; MON_LINK_UP=0 GATEWAY=""
  [ "$m" = "$(scanner_rules)" ]
  [ "$m" = "N1 " ]
}
```

- [ ] **Step 9: Run shellcheck**

Run: `shellcheck -x bin/netdiag lib/*.sh`
Expected: no output, exit 0.

- [ ] **Step 10: Commit**

```bash
git add lib/diagnosis.sh helpers/rules_catalog.py docs/DIAGNOSIS-RULES.md tests/test_parse.bats tests/test_monitor.bats
git commit -m "fix: stop telling users on hotel WiFi that their WiFi is off

N1 split into N1 (nothing joined) and N1c (joined, addressed, no route
out). N1c leads with the sign-in page and quotes the DHCP router, and
claims no portal it hasn't detected."
```

---

### Task 4: Make the captive-portal probe read the body

**Files:**
- Modify: `lib/common.sh:420-426`
- Modify: `lib/public.sh:36-49`
- Modify: `lib/monitor.sh:548-556`
- Create: `tests/fixtures/captive_apple_success.txt`, `tests/fixtures/captive_apple_portal.txt`
- Test: `tests/test_helpers.bats` (append)

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/captive_apple_success.txt` — the exact body Apple's canary returns on a clean network:

```
<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>
```

`tests/fixtures/captive_apple_portal.txt` — a portal answering 200 with its own page instead:

```
<!DOCTYPE html>
<html><head><title>Mercure Guest WiFi</title></head>
<body><h1>Welcome</h1><form action="/login" method="post">
<input name="room"><input name="surname"><button>Connect</button>
</form></body></html>
```

- [ ] **Step 2: Write the failing test**

Append to `tests/test_helpers.bats`:

```bash
# ── captive_portal_classify: status alone is not enough ──────────────────
# The probe used to pass `curl -o /dev/null` and classify on the HTTP
# status only: 3xx portal, 2xx ok. Apple's own captive check compares the
# BODY against a literal success page, because a portal that answers 200
# with its login HTML is both extremely common and, on status alone,
# indistinguishable from a clean network. netdiag reported "No captive
# portal" on exactly those networks.

@test "captive: a redirect is a portal regardless of body" {
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  [ "$(captive_portal_classify 302 '')" = "portal" ]
  [ "$(captive_portal_classify 307 'anything')" = "portal" ]
}

@test "captive: 511 Network Authentication Required is a portal" {
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  [ "$(captive_portal_classify 511 '')" = "portal" ]
}

@test "captive: 200 with Apple's success page is clean" {
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  [ "$(captive_portal_classify 200 "$(cat "$FIX/captive_apple_success.txt")")" = "ok" ]
}

@test "captive: 200 with a login page is a portal" {
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  [ "$(captive_portal_classify 200 "$(cat "$FIX/captive_apple_portal.txt")")" = "portal" ]
}

@test "captive: 200 with no body read is unknown, not ok" {
  # Silence beats a guess: an empty body means the probe could not read
  # one, not that the network is clean.
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  [ "$(captive_portal_classify 200 '')" = "unknown" ]
}

@test "captive: a probe that never answered is unknown" {
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  [ "$(captive_portal_classify '' '')" = "unknown" ]
  [ "$(captive_portal_classify 000 '')" = "unknown" ]
}
```

If `tests/test_helpers.bats`'s `setup()` does not already define `FIX`, add `FIX="${BATS_TEST_DIRNAME}/fixtures"` to it alongside `REPO`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats tests/test_helpers.bats -f "captive"`
Expected: the 511 test FAILs (`unknown`, not `portal`), the login-page test FAILs (`ok`, not `portal`), and the empty-body test FAILs (`ok`, not `unknown`).

- [ ] **Step 4: Rewrite `captive_portal_classify`**

In `lib/common.sh`, replace lines 420-426:

```bash
captive_portal_classify() {
  case "${1:-}" in
    2[0-9][0-9])        printf 'ok' ;;
    3[0-9][0-9])        printf 'portal' ;;
    *)                  printf 'unknown' ;;
  esac
}
```

with:

```bash
# Classify a captive-portal canary probe. $1 = HTTP status, $2 = response
# body. Prints "ok" | "portal" | "unknown".
#
# The body is load-bearing, not decorative. This used to classify on the
# status alone — 3xx portal, 2xx ok — and both callers passed
# `curl -o /dev/null`, so a portal that answers 200 OK with its own login
# page (a hotel splash, a terms-of-service checkbox: the common case, not
# an edge case) was reported to the user as "No captive portal."
#
# Apple's own captive check works the same way this now does: request the
# canary, and treat anything that is not the literal success page as an
# interception. The marker below is the whole of that page's title element
# and is stable across every macOS release netdiag supports.
#
# "unknown" on an unreadable body is deliberate: a 200 with nothing
# captured means the probe failed to read a body, not that the network is
# clean, and silence beats a confident wrong answer. Callers already treat
# unknown as "say nothing".
CAPTIVE_CANARY_MARKER='<TITLE>Success</TITLE>'
captive_portal_classify() {
  local status="${1:-}" body="${2:-}"
  case "$status" in
    511)                printf 'portal'; return ;;
    3[0-9][0-9])        printf 'portal'; return ;;
    2[0-9][0-9])        ;;
    *)                  printf 'unknown'; return ;;
  esac
  if [ -z "$body" ]; then
    printf 'unknown'
  elif printf '%s' "$body" | grep -qiF "$CAPTIVE_CANARY_MARKER"; then
    printf 'ok'
  else
    printf 'portal'
  fi
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/test_helpers.bats -f "captive"`
Expected: 6 tests, all PASS.

- [ ] **Step 6: Pass the body from `lib/public.sh`**

In `lib/public.sh`, replace the captive-portal sniff block:

```bash
  # Captive portal sniff
  captive="$(curl -s -m 3 -o /dev/null -w '%{http_code} %{redirect_url}' http://captive.apple.com/hotspot-detect.html 2>/dev/null)"
  # One classifier shared with the live monitor — see lib/common.sh — so a
  # scan and a between-scans sample cannot disagree about what the answer
  # means. A probe that never answered classifies "unknown" and stays
  # silent here: silence beats a guess.
  case "$(captive_portal_classify "${captive%% *}")" in
    ok)     ok "No captive portal." ;;
    portal)
      CAPTIVE_PORTAL=1
      warn "Captive portal detected (HTTP $captive) — log in via browser."
      ;;
  esac
```

with:

```bash
  # Captive portal sniff. The body is captured, not discarded: a portal
  # answering 200 with its login page is the common case and is invisible
  # in the status alone — see captive_portal_classify in lib/common.sh.
  # No -L: a followed redirect lands on the portal's own 200 and erases
  # the evidence.
  local captive_raw captive_code captive_body
  captive_raw="$(curl -s -m 3 -w '\n%{http_code}' \
    http://captive.apple.com/hotspot-detect.html 2>/dev/null)"
  captive_code="${captive_raw##*$'\n'}"
  captive_body="${captive_raw%$'\n'*}"
  # One classifier shared with the live monitor — see lib/common.sh — so a
  # scan and a between-scans sample cannot disagree about what the answer
  # means. A probe that never answered classifies "unknown" and stays
  # silent here: silence beats a guess.
  case "$(captive_portal_classify "$captive_code" "$captive_body")" in
    ok)     ok "No captive portal." ;;
    portal)
      CAPTIVE_PORTAL=1
      CAPTIVE_PORTAL_CODE="$captive_code"
      warn "Captive portal detected (HTTP $captive_code) — log in via browser."
      ;;
  esac
```

Update the `local` declaration near the top of `public_run` from:

```bash
  local pub_out captive
```

to:

```bash
  local pub_out
```

and add `CAPTIVE_PORTAL_CODE=""` to `lib/globals.sh` beside `CAPTIVE_PORTAL=0`:

```bash
CAPTIVE_PORTAL=0
CAPTIVE_PORTAL_CODE=""   # observed HTTP status — CP-1's evidence
```

Also extend `lib/public.sh`'s header `Writes:` line to include `CAPTIVE_PORTAL_CODE`.

- [ ] **Step 7: Pass the body from `lib/monitor.sh`**

In `lib/monitor.sh`, replace lines 548-556:

```bash
  local captive
  captive="$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
    http://captive.apple.com/hotspot-detect.html 2>/dev/null || true)"
  # Same classifier lib/public.sh uses — see lib/common.sh.
  case "$(captive_portal_classify "$captive")" in
    ok)     MON_CAPTIVE=0 ;;
    portal) MON_CAPTIVE=1 ;;
    *)      MON_CAPTIVE="" ;;
  esac
```

with:

```bash
  # Body captured for the same reason lib/public.sh captures it: a portal
  # that answers 200 with its login page is invisible in the status alone.
  local captive_raw captive_code captive_body
  captive_raw="$(curl -s -m 3 -w '\n%{http_code}' \
    http://captive.apple.com/hotspot-detect.html 2>/dev/null || true)"
  captive_code="${captive_raw##*$'\n'}"
  captive_body="${captive_raw%$'\n'*}"
  # Same classifier lib/public.sh uses — see lib/common.sh.
  case "$(captive_portal_classify "$captive_code" "$captive_body")" in
    ok)     MON_CAPTIVE=0 ;;
    portal) MON_CAPTIVE=1 ;;
    *)      MON_CAPTIVE="" ;;
  esac
```

- [ ] **Step 8: Verify the suite and shellcheck**

Run: `bats tests/ ; shellcheck -x bin/netdiag lib/*.sh`
Expected: bats passes except the one known pre-existing failure (NET.2). shellcheck silent.

- [ ] **Step 9: Commit**

```bash
git add lib/common.sh lib/public.sh lib/monitor.sh lib/globals.sh tests/test_helpers.bats tests/fixtures/captive_apple_success.txt tests/fixtures/captive_apple_portal.txt
git commit -m "fix: detect captive portals that answer 200 instead of redirecting

The canary body is now compared against Apple's success page, the way
Apple's own check does it. Status-only classification reported 'No
captive portal' on every hotel splash page that returns 200, and on 511."
```

---

### Task 5: Fire CP-1 in a scan, and stop blaming the ISP for a portal

**Files:**
- Modify: `lib/diagnosis.sh` (CP-1 call sites; P1/P2 guard)
- Modify: `helpers/rules_catalog.py` (CP-1 scope and severity)
- Modify: `docs/DIAGNOSIS-RULES.md:553-578`
- Modify: `tests/test_monitor.bats:239-241`
- Test: `tests/test_parse.bats` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_parse.bats`:

```bash
# ── CP-1: a portal is a diagnosis, not just a log line ───────────────────
# lib/public.sh has set CAPTIVE_PORTAL since v0.1 and printed a warn line
# about it, but never called add_diag — so the portal never reached
# status.rules[], the GUI's "What we found", or the exit code. P1 fired
# instead, telling the user on a hotel network to "check their ISP's
# status page or call support".

@test "diagnosis: a portal blocking the internet is a critical CP-1, not P1" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=0 DNS_OK=0
  CAPTIVE_PORTAL=1 CAPTIVE_PORTAL_CODE=302
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local joined=" ${DIAG_RULE[*]} "
  [[ "$joined" == *" CP-1 "* ]]
  [[ "$joined" != *" P1 "* ]]
  [[ "$joined" != *" P2 "* ]]
  [ "$MAX_SEVERITY" -eq 2 ]
}

@test "diagnosis: a portal that still lets traffic through is a warning" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=1 DNS_OK=1
  CAPTIVE_PORTAL=1 CAPTIVE_PORTAL_CODE=302
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local joined=" ${DIAG_RULE[*]} "
  [[ "$joined" == *" CP-1 "* ]]
  [ "$MAX_SEVERITY" -eq 1 ]
}

@test "diagnosis: no portal leaves P1 in charge" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=0 DNS_OK=0
  CAPTIVE_PORTAL=0
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local joined=" ${DIAG_RULE[*]} "
  [[ "$joined" == *" P1 "* ]]
  [[ "$joined" != *" CP-1 "* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_parse.bats -f "portal"`
Expected: the first two FAIL — no `CP-1` in `DIAG_RULE`, and `P1` fires.

- [ ] **Step 3: Add the CP-1 call sites and guard P1/P2**

In `lib/diagnosis.sh`, insert this block immediately **before** the `# P1/P2 — public unreachable` block (before line 111's comment):

```bash
  # CP-1 — a captive portal is intercepting this network. Two literal
  # call sites rather than one with a variable severity: every add_diag
  # site in this tree passes its severity as a literal token, and
  # tests/test_rules_catalog.bats extracts them by regex to prove the
  # catalog matches the code.
  #
  # This rule existed for months with no scan call site at all. It lived
  # only in lib/monitor.sh, and docs/DIAGNOSIS-RULES.md argued a scan
  # didn't need one "because P1/P2 fire anyway". They do — and what they
  # say is "almost certainly an outage on your ISP's side, check their
  # status page or call support", which is exactly wrong on a hotel
  # network and sends the user to phone a company that is working fine.
  if [ "${CAPTIVE_PORTAL:-0}" -eq 1 ]; then
    if [ "$PUBLIC_OK" -eq 0 ]; then
      add_diag critical CP-1 "This network wants you to sign in before it will let you online — the check for internet access came back intercepted (HTTP ${CAPTIVE_PORTAL_CODE:-?}) rather than answered. Open a browser and load any plain http:// address; the network's sign-in or terms page should appear. Nothing else will work until you accept it. There is nothing wrong with your Mac, your router, or your internet provider."
    else
      add_diag warn CP-1 "This network is intercepting web requests to show a sign-in or terms page (HTTP ${CAPTIVE_PORTAL_CODE:-?}), even though traffic is currently getting through. Expect connections to break when its session expires — open a browser and complete the page to be safe."
    fi
  fi
```

Then change the P1/P2 guard from:

```bash
  if [ "$PUBLIC_OK" -eq 0 ] && loss_below "$GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
```

to:

```bash
  # CP-1 above owns the portal case. Without this guard both fire, and P1's
  # "call your ISP" outranks the one instruction that actually works.
  if [ "$PUBLIC_OK" -eq 0 ] && [ "${CAPTIVE_PORTAL:-0}" -eq 0 ] \
     && loss_below "$GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
```

Apply the same guard to the monitor's P1/P2 block in `lib/monitor.sh:672`, changing:

```bash
  if [ "$_mon_public_ok" = "0" ] && loss_below "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
```

to:

```bash
  # Mirrors lib/diagnosis.sh: CP-1 owns the portal case on both sides, or
  # the stream and the report disagree about what to tell the user.
  if [ "$_mon_public_ok" = "0" ] && [ "${MON_CAPTIVE:-}" != "1" ] \
     && loss_below "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test_parse.bats -f "portal"`
Expected: 3 tests, all PASS.

- [ ] **Step 5: Update the catalog entry**

In `helpers/rules_catalog.py`, replace the `CP-1` entry:

```python
    {
        "id": "CP-1",
        "title": "Captive portal blocking access",
        "category": "internet",
        "severity": "varies",
        "scope": "both",
        "blurb": (
            "The check for internet access came back intercepted rather "
            "than answered, which is the signature of a captive portal — "
            "the login or terms page hotel, airport, and coffee-shop WiFi "
            "often require before real internet access works. Open a "
            "browser and complete the portal; nothing else will work "
            "until it's accepted. Critical when nothing is getting "
            "through, a warning when traffic still flows and the portal "
            "is only waiting to cut it off."
        ),
        "doc": "DIAGNOSIS-RULES.md#cp-1--captive-portal-blocking-real-access",
    },
```

- [ ] **Step 6: Drop the monitor test's CP-1 exclusion**

In `tests/test_monitor.bats`, replace:

```bash
    case "$rule" in
      CP-1) continue ;;  # captive portal: a public.captive_portal fact, not a diagnosis rule
    esac
```

with:

```bash
    # No exclusions. CP-1 used to be one — it was emitted by the monitor
    # and by nothing else, on the theory that a scan didn't need it. It
    # did: without a scan call site a portal never reached status.rules[],
    # the GUI, or the exit code, and P1's "call your ISP" spoke for it.
```

- [ ] **Step 7: Correct the doc's rationale**

In `docs/DIAGNOSIS-RULES.md`, replace the whole `### CP-1 — Captive portal blocking real access` section with:

```markdown
### CP-1 — Captive portal blocking real access

- **Trigger:** the probe to `http://captive.apple.com/hotspot-detect.html`
  comes back intercepted rather than answered — a redirect (3xx), a 511
  Network Authentication Required, or a 200 whose body is not Apple's
  literal success page. Classified by `captive_portal_classify` in
  `lib/common.sh`, shared by `lib/public.sh::public_run` (scan) and
  `lib/monitor.sh::_mon_probe_public` (monitor).
- **Severity:** critical when `public.ok` is false — nothing is getting
  through and the network is unusable until the portal is accepted. Warn
  when traffic is still flowing and the portal is merely waiting to cut
  it off.
- **Evidence:** the observed HTTP status.
- **Recommendation:** open a browser and complete the portal's login or
  terms page.
- **Precedence: CP-1 suppresses P1 and P2**, in the scanner and in the
  monitor alike. Both are guarded on `CAPTIVE_PORTAL` / `MON_CAPTIVE`.

**Correcting the record.** This section previously argued that CP-1 was
monitor-only by design, because "a full scan runs the exact same probe
but doesn't need a rule for it: a detected portal already surfaces as
`public.captive_portal` in the JSON and a warn line in the Public
reachability section, and when the portal is actually blocking traffic
the `ifconfig.co` fetch fails too, so P1/P2 fire anyway."

That was wrong on both counts, and the stored run
`2026-08-26T22:53:05Z` shows how:

- A field in the JSON and a line in a section are not a diagnosis.
  `status.rules[]` is what feeds `status.severity`, the exit code, the
  GUI's "What we found" panel and the menu-bar dot. A portal reached none
  of them.
- "P1/P2 fire anyway" is the defect, not the mitigation. P1 says *"almost
  certainly an outage on your ISP's side — check their status page or
  call support."* On a hotel network that is not merely unhelpful, it
  sends the user to phone a company whose service is working, and buries
  the one action that would have fixed it in thirty seconds.

The probe was also weaker than this section implied: it classified on the
HTTP status alone with `curl -o /dev/null`, so a portal answering 200 with
its own login page — the common case — was reported as "No captive
portal." See `captive_portal_classify`.
```

- [ ] **Step 8: Verify the whole suite and shellcheck**

Run: `bats tests/ ; shellcheck -x bin/netdiag lib/*.sh`
Expected: bats passes except the one known pre-existing failure (NET.2). shellcheck silent. `tests/test_rules_catalog.bats`'s scope-derivation test now expects `both` for CP-1 and gets it.

- [ ] **Step 9: Commit**

```bash
git add lib/diagnosis.sh lib/monitor.sh helpers/rules_catalog.py docs/DIAGNOSIS-RULES.md tests/test_parse.bats tests/test_monitor.bats
git commit -m "fix: a captive portal is a diagnosis in a scan, not a log line

CP-1 gains scan call sites and suppresses P1/P2 on both sides. Users on
hotel WiFi were being told to phone their ISP."
```

---

### Task 6: D2 — every resolver failed

**Files:**
- Modify: `lib/diagnosis.sh` (new rule beside D1)
- Modify: `helpers/rules_catalog.py`
- Modify: `docs/DIAGNOSIS-RULES.md`
- Test: `tests/test_parse.bats` (append)

**Why no Swift changes.** `RunReportView.swift:258` colors the DNS row from
whichever rules carry the `dns` / `dhcp` category, and that is correct —
CLAUDE.md forbids the GUI holding diagnostic logic. The green dot over
"0 of 6 resolvers OK" is a missing rule in `lib/`, not a rendering bug.
Adding D2 turns the row red with no Swift touched.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_parse.bats`:

```bash
# ── D2: total resolver failure ───────────────────────────────────────────
# D1 requires PUBLIC_OK=1, so on a network with no internet the DNS check
# could measure "0 of 6 resolvers OK" and fire nothing at all — which the
# GUI, which colors that row from rules, rendered as a green dot beside
# the words "0 of 6 resolvers OK".

@test "diagnosis: every resolver failing fires D2 even with no internet" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=0 DNS_OK=0
  DNS_LINES="1.1.1.1|apple.com||FAIL
8.8.8.8|apple.com||FAIL"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local joined=" ${DIAG_RULE[*]} "
  [[ "$joined" == *" D2 "* ]]
}

@test "diagnosis: D2 does not fire when the DNS check never ran" {
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=1 DNS_OK=0 DNS_LINES=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local joined=" ${DIAG_RULE[*]} "
  [[ "$joined" != *" D2 "* ]]
}

@test "diagnosis: D2 and D1 do not both fire" {
  # D1 is the partial case (internet up, some lookups failing); D2 is the
  # total one. Both firing would put two DNS verdicts in one report.
  # shellcheck source=../lib/diagnosis.sh
  . "$REPO/lib/diagnosis.sh"
  GATEWAY="10.125.128.1" LINK_UP=1 GW_LOSS=0 PUBLIC_OK=1 DNS_OK=0
  DNS_LINES="1.1.1.1|apple.com||FAIL"
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
  diagnosis_run >/dev/null
  local joined=" ${DIAG_RULE[*]} "
  [[ "$joined" == *" D1 "* ]]
  [[ "$joined" != *" D2 "* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_parse.bats -f "D2"`
Expected: the first FAILs — no `D2` rule exists.

- [ ] **Step 3: Add D2 beside D1 in `lib/diagnosis.sh`**

Replace the D1 block:

```bash
  # D1 — partial DNS, internet reachable. DNS_LINES proves the check ran;
```

...through its `add_diag warn D1 "..."` line, with:

```bash
  # D1 / D2 — name resolution is failing. DNS_LINES proves the check ran;
  # DNS_OK=0 with no lines is a skipped check, not a failed one.
  #
  # D1 is the partial case and requires the internet to be up, because its
  # whole content is "everything else works, so it's your resolver". D2 is
  # the total case and requires nothing of the sort — which is the point.
  # With only D1, a network whose internet was down measured "0 of 6
  # resolvers OK" and fired no dns-category rule at all, and the GUI,
  # which colors the DNS row from the rules the CLI hands it, rendered a
  # green dot beside the words "0 of 6 resolvers OK". A row cannot be
  # allowed to contradict its own value; the fix belongs here rather than
  # in Swift because the GUI holds no diagnostic logic by design.
  #
  # Ordered D2-then-D1 with the elif so the two can never both fire.
  if [ -n "$DNS_LINES" ] && [ "$DNS_OK" -eq 0 ] && [ "$PUBLIC_OK" -eq 0 ]; then
    add_diag warn D2 "No name lookups are working at all — every DNS server your Mac tried failed to answer. On its own that would point at your DNS settings, but nothing else on the internet is reachable either, so this is most likely a symptom rather than the cause. Fix the connection first; if lookups still fail once it's back, switch your DNS to 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google) in System Settings → Network → Details → DNS."
  elif [ -n "$DNS_LINES" ] && [ "$DNS_OK" -eq 0 ] && [ "$PUBLIC_OK" -eq 1 ]; then
    add_diag warn D1 "The internet works but some name lookups are failing — your DNS server is flaky. Switch your DNS to 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google) in System Settings → Network → Details → DNS."
  fi
```

Delete the original standalone `if [ -n "$DNS_LINES" ] && [ "$DNS_OK" -eq 0 ] && [ "$PUBLIC_OK" -eq 1 ]; then ... fi` block that this replaces, so D1 has exactly one call site.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test_parse.bats -f "D2"`
Expected: 3 tests, all PASS.

- [ ] **Step 5: Add D2 to the catalog**

In `helpers/rules_catalog.py`, insert immediately after the `D1` entry:

```python
    {
        "id": "D2",
        "title": "No name lookups working at all",
        "category": "dns",
        "severity": "warn",
        "scope": "scan",
        "blurb": (
            "Every DNS server your Mac tried failed to answer, and the "
            "wider internet is unreachable too — so this is most likely a "
            "symptom of the connection being down rather than a DNS fault "
            "in its own right. Fix the connection first. If lookups still "
            "fail once it is back, switch your DNS to Cloudflare or "
            "Google in System Settings."
        ),
        "doc": "DIAGNOSIS-RULES.md#d2--no-name-lookups-working-at-all",
    },
```

- [ ] **Step 6: Document D2**

In `docs/DIAGNOSIS-RULES.md`, add immediately after the `### D1` section:

```markdown
### D2 — No name lookups working at all

- **Trigger:** `DNS_LINES` non-empty (the check ran), `DNS_OK == 0`, and
  `public.ok == false`.
- **Severity:** warn. The connection failure it accompanies is already
  critical; a second critical would double-count one fault.
- **Recommendation:** fix the connection first, then re-test DNS.

**Precedence: D1 and D2 are mutually exclusive**, split on `public.ok`.
D1 is the partial case and says "everything else works, so it's your
resolver" — a sentence that is only true when everything else does work.
D2 is the total case and deliberately declines to blame the resolver.

**Why D2 exists.** D1's `public.ok == true` guard meant a network with no
internet fired *no* `dns`-category rule at all, however badly DNS was
failing. `RunReportView` colors the "Name lookups (DNS)" row from the
categories of the rules the CLI hands it, so the report card showed a
green dot beside the words "0 of 6 resolvers OK" — visible in the
screenshots that prompted this work. The row was right and the dot was
wrong, and the missing piece was a rule, not a renderer: per CLAUDE.md the
GUI holds no diagnostic logic, so a threshold or verdict added to Swift to
paper over this would have been the wrong fix in the wrong file.
```

- [ ] **Step 7: Verify the whole suite and shellcheck**

Run: `bats tests/ ; shellcheck -x bin/netdiag lib/*.sh`
Expected: bats passes except the one known pre-existing failure (NET.2). shellcheck silent.

- [ ] **Step 8: Commit**

```bash
git add lib/diagnosis.sh helpers/rules_catalog.py docs/DIAGNOSIS-RULES.md tests/test_parse.bats
git commit -m "fix: '0 of 6 resolvers OK' no longer renders with a green dot

D1 required the internet to be up, so total resolver failure on a downed
network fired no dns-category rule and the GUI row stayed green. D2 is
the total case. No Swift change: the GUI holds no diagnostic logic."
```

---

### Task 7: Emit link state in the JSON, document it, and regenerate the samples

**Files:**
- Modify: `helpers/emit_json.py:342-354`
- Modify: `bin/netdiag` (export the new variables)
- Modify: `docs/JSON-SCHEMA.md`
- Modify: `CHANGELOG.md`
- Modify: `examples/sample-output.txt`, `examples/sample-output.json`
- Test: `tests/test_helpers.bats` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_helpers.bats`:

```bash
@test "emit_json: interface carries link state independent of the route" {
  run emit NETDIAG_INTERFACE=en0 \
           NETDIAG_LOCAL_IP=10.125.129.35 \
           NETDIAG_GATEWAY= \
           NETDIAG_LINK_STATUS=active \
           NETDIAG_LINK_UP=1 \
           NETDIAG_LINK_DHCP_ROUTER=10.125.128.1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq_get interface.link_up)" = 'true' ]
  [ "$(printf '%s' "$output" | jq_get interface.link_status)" = '"active"' ]
  [ "$(printf '%s' "$output" | jq_get interface.dhcp_router)" = '"10.125.128.1"' ]
  [ "$(printf '%s' "$output" | jq_get interface.gateway)" = 'null' ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/test_helpers.bats -f "link state"`
Expected: FAIL — `interface.link_up` is `null`; the keys do not exist.

- [ ] **Step 3: Emit the fields**

In `helpers/emit_json.py`, replace the `"interface"` block:

```python
        "interface": {
            "name": _env("INTERFACE"),
            "ip": _env("LOCAL_IP"),
            "gateway": _env("GATEWAY"),
            "gateway_mac": _env("GW_MAC"),
            "type": "wifi" if is_wifi else "wired",
        },
```

with:

```python
        "interface": {
            "name": _env("INTERFACE"),
            "ip": _env("LOCAL_IP"),
            "gateway": _env("GATEWAY"),
            "gateway_mac": _env("GW_MAC"),
            "type": "wifi" if is_wifi else "wired",
            # Association state, deliberately separate from `gateway`
            # above. `gateway` answers "is there a default route"; these
            # answer "is this Mac joined to anything", and conflating the
            # two is what made N1 tell users on hotel WiFi that their WiFi
            # was off. See lib/linkstate.sh and DIAGNOSIS-RULES.md#n1c.
            "link_status": _env("LINK_STATUS"),
            "link_up": os.environ.get("NETDIAG_LINK_UP", "") == "1",
            # The router the DHCP server offered, present whether or not
            # the kernel installed a route to it — so on a network that
            # withholds a route there is still an address to point a
            # browser at.
            "dhcp_router": _env("LINK_DHCP_ROUTER"),
        },
```

- [ ] **Step 4: Export the variables from `bin/netdiag`**

Find the `NETDIAG_*` export block that calls `helpers/emit_json.py` (search for `NETDIAG_GATEWAY=`) and add alongside it, preserving the existing style:

```bash
   NETDIAG_LINK_STATUS="$LINK_STATUS" \
   NETDIAG_LINK_UP="$LINK_UP" \
   NETDIAG_LINK_DHCP_ROUTER="$LINK_DHCP_ROUTER" \
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bats tests/test_helpers.bats -f "link state"`
Expected: PASS.

- [ ] **Step 6: Document the fields**

In `docs/JSON-SCHEMA.md`, find the `interface` row of the top-level field table and replace it with:

```markdown
| `interface` | object | `name`, `ip`, `gateway`, `gateway_mac`, `type`, `link_status`, `link_up`, `dhcp_router`. `gateway` is the default route's gateway and is `null` when there is no default route. `link_status` is `ifconfig`'s own word (`"active"` / `"inactive"` / `null`) and `link_up` is `true` when an active device also holds an address — together they answer "is this Mac joined to anything", which is a *different question* from `gateway`, and conflating the two is what made `N1` tell users on hotel WiFi that their WiFi was off (see `DIAGNOSIS-RULES.md#n1c`). `dhcp_router` is the router the DHCP server offered, present whether or not the kernel installed a route to it. |
```

- [ ] **Step 7: Add the CHANGELOG entry**

Prepend a new entry to `CHANGELOG.md` under the current unreleased heading, matching the file's existing prose style — full detail here, since per CLAUDE.md the artifact carries the detail and the chat summary does not:

```markdown
### Fixed — link state, captive portals, and a green dot over a red row

Four defects, all reachable from one screenshot of a Mac sitting on hotel
WiFi at −44 dBm being told it had no network connection at all.

- **A missing default route no longer erases the interface.** `lib/iface.sh`
  derived both `INTERFACE` and `GATEWAY` from a single
  `route -n get default`, and `lib/wifi.sh`, `lib/dhcp.sh` and
  `lib/netid.sh` all gate on `INTERFACE` — so one absent route took the
  SSID, the signal, the lease and the network identity with it, and `N1`
  went on to state that the Mac "isn't joined to a WiFi network", a claim
  nothing in the run had checked. New `lib/linkstate.sh` answers
  association, address and DHCP router from `ifconfig` and
  `ipconfig getpacket`, none of which consults the routing table.
- **`N1` split into `N1` and `N1c`.** `N1` is now genuinely nothing joined.
  `N1c` is joined-and-addressed with no route out — it names the network,
  leads with the sign-in page because that is overwhelmingly the cause,
  and quotes the DHCP router as somewhere to point a browser. It claims no
  portal it has not detected: with no route the canary is unreachable.
- **The route is re-read once before it is called missing.** Six of twelve
  consecutive stored runs fired `N1` under network id `unknown` while runs
  two minutes either side were filed against a live gateway on the same
  network. A route drops for a moment during a DHCP renewal or a WiFi
  roam; a single unlucky read turned that into the most alarming verdict
  netdiag can produce plus a junk history entry.
  `THRESH_ROUTE_RECHECK_DELAY_S`.
- **`CP-1` fires in a scan.** It previously existed only in
  `lib/monitor.sh`; `lib/public.sh` set `CAPTIVE_PORTAL` and printed a warn
  line but never called `add_diag`, so a portal never reached
  `status.rules[]`, the exit code, or the GUI. `P1` spoke in its place —
  *"almost certainly an outage on your ISP's side, check their status page
  or call support"* — on networks whose fix was a browser. `CP-1` now
  suppresses `P1`/`P2` in the scanner and the monitor alike, and is
  critical when nothing is getting through. `docs/DIAGNOSIS-RULES.md`
  carried the argument for the old behaviour; that section has been
  corrected rather than quietly deleted.
- **Portals that answer 200 are detected.** `captive_portal_classify`
  classified on the HTTP status alone and both callers passed
  `curl -o /dev/null`, so a hotel splash page returning 200 with its login
  HTML — the common case — was reported as "No captive portal". The body
  is now compared against Apple's literal success page, the way Apple's
  own check does it, and 511 is recognised.
- **"0 of 6 resolvers OK" no longer renders with a green dot.** `D1`
  required `public.ok == true`, so total resolver failure on a downed
  network fired no `dns`-category rule and `RunReportView`'s DNS row
  stayed green beside its own red value. New `D2` covers the total case.
  No Swift changed: the GUI holds no diagnostic logic, so the missing
  piece was a rule, not a renderer.
```

- [ ] **Step 8: Run the full suite**

Run: `bats tests/`
Expected: all PASS except the one known pre-existing failure (NET.2 in
`tests/test_regressions.bats`). If anything else fails, fix it before
continuing — do not regenerate samples over a failing suite.

Run: `shellcheck -x bin/netdiag lib/*.sh`
Expected: no output, exit 0.

- [ ] **Step 9: Regenerate the sample output**

Per CLAUDE.md these must be real captures, taken with `--redact`, from
stdout — **never** via `--log`, which deliberately keeps full detail and
yields an unredacted file that looks like it worked.

```bash
./bin/netdiag --redact --json > examples/sample-output.json
./bin/netdiag --redact | sed $'s/\x1b\\[[0-9;]*[mK]//g' > examples/sample-output.txt
jq . examples/sample-output.json > /dev/null && echo "valid JSON"
```

Expected: `valid JSON`. Confirm by eye that `examples/sample-output.json`
contains `"link_up"`, and that neither file contains the machine's public
IPv6 address or city. The ISP name is kept by design.

- [ ] **Step 10: Verify against a real portal if one is reachable**

If a captive network is available, run `./bin/netdiag --json | jq
'.status.rules, .public.captive_portal, .interface'` on it and confirm
`CP-1` (or `N1c`) appears in `status.rules`. If no such network is
available, say so explicitly in the commit body rather than implying it
was tested — this is the one claim in this plan that cannot be verified
from fixtures alone.

- [ ] **Step 11: Commit**

```bash
git add helpers/emit_json.py bin/netdiag docs/JSON-SCHEMA.md CHANGELOG.md tests/test_helpers.bats examples/sample-output.txt examples/sample-output.json
git commit -m "feat: emit link state in the JSON; document and re-capture samples

interface.link_status / link_up / dhcp_router answer 'is this Mac joined
to anything', which interface.gateway does not."
```

---

## Self-Review

**Spec coverage.** All four defects from the user's report are covered:
link state decoupled from the route (Tasks 1-2), the N1 prose defect
(Task 3), CP-1 in scans plus a hardened probe (Tasks 4-5), and the green
DNS dot (Task 6). The flicker re-check the user asked for is Task 2 Step 2
and 5; the "stop filing under unknown network" half is Task 2 Step 7.

**Placeholders.** None. Every code step carries the code; every doc step
carries the prose; every test step carries the assertions and the exact
`bats` invocation with its expected result.

**Type and name consistency.** `LINK_DEVICE`, `LINK_STATUS`, `LINK_IP`,
`LINK_DHCP_ROUTER`, `LINK_UP` are declared in Task 2 Step 1, written by
`linkstate_run` in Task 1 Step 4, read by `iface_run` (Task 2 Step 5),
`netid_run` (Task 2 Step 7), `diagnosis_run` (Tasks 3, 5, 6) and
`emit_json.py` (Task 7 Step 3) under the same names throughout.
`CAPTIVE_PORTAL_CODE` is declared in Task 4 Step 6 and read in Task 5
Step 3. `captive_portal_classify` takes `(status, body)` at every call
site from Task 4 onward.

**Known risks to watch during execution.**

1. `tests/test_rules_catalog.bats`'s call-site extraction requires the
   severity to be a **literal** token. Task 5 Step 3 therefore uses two
   `add_diag` lines rather than one with a variable. Do not "simplify"
   this.
2. `tests/test_rules_catalog.bats` also rejects numeric thresholds with
   units inside blurbs. The new `N1c`, `D2` and `CP-1` blurbs contain no
   digits; keep it that way.
3. The `iface_run` tests in Task 2 Step 3 stub `route`/`ifconfig`/
   `ipconfig`/`networksetup` as exported shell functions. If the bats
   version in use does not honour `export -f` for these, replace the
   stubs with a `PATH`-shadowing directory of scripts in
   `$BATS_TEST_TMPDIR` — same assertions, different mechanism.
4. `helpers/history.py::group_key()` is paired with `netid_run` by
   `tests/test_history.bats`. Task 2 Step 7 only extends an existing
   `gw=` fallback, so no Python change should be needed; if that test
   fails, the two have drifted and `group_key` needs the same change.
