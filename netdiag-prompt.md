# Build: `netdiag` — a comprehensive macOS network-diagnostic CLI

## Context

I'm building a network-investigation script for macOS called **`netdiag`**. The starting point is a working ~300-line bash script that runs a battery of checks (interface/gateway, WiFi info, ping, public IP, DNS, traceroute, per-hop loss), writes a timestamped log, attempts a root-cause diagnosis (WiFi vs router vs ISP vs DNS), and launches `gping` for live monitoring. The starting script is included verbatim below.

I want you to:

1. **Extend** the script with the 14 enhancements listed in the **Plan** section below — these dramatically improve real-world debugging value (bufferbloat under load, PMTU probe, continuous mtr-style loss, IPv6 parity, VPN-active detection, TCP reach, WiFi neighborhood scan, WiFi disconnect history, speed test, NTP/time-sync check, baseline diff, custom target argument, duplicate-IP detection, DHCP lease info).
2. **Refactor responsibly** as you grow — the current single-file bash will become hard to maintain past ~700 lines. Decide whether to (a) split into sourced modules under `lib/`, or (b) port the heavier parsing/correlation logic to a small Python helper invoked from the bash entry point. Pick whichever keeps the codebase clean; document the choice in `ARCHITECTURE.md`.
3. **Set up a GitHub repo** for the project with proper structure, README, license, CI, and distribution (see **Repo setup** section).

Before you start writing code, produce a short written plan (under 400 words) that confirms: (a) the file/module structure you'll use, (b) the bash-vs-Python split decision and why, (c) the order you'll implement the 14 features in, and (d) any clarifying questions for me. Then implement. After implementing, run the script against your own machine (or describe how you tested if running in a sandbox), and paste a sample full-run output into `examples/sample-output.txt`.

## Engineering constraints

- **Target platform:** macOS 14+ (Sonoma/Sequoia/Tahoe). Apple Silicon and Intel both. Don't worry about Linux portability for v1.
- **Shell:** zsh-installed-by-default *and* Homebrew bash 5+ both must work. Avoid bashisms that break in zsh and vice versa where reasonable; if you need bash, declare it in the shebang and document it.
- **External deps:** prefer macOS built-ins (`ipconfig`, `networksetup`, `route`, `scutil`, `wdutil`, `dig`, `traceroute`, `ping`, `nc`, `arp`, `log`, `sntp`, `system_profiler`, `curl`). Acceptable Homebrew additions: `mtr`, `gping`, `speedtest` (Ookla official) or `speedtest-cli`, `jq`. Detect missing deps and either skip the relevant check with a clear message or offer `brew install` instructions — do not hard-fail.
- **Permissions model:** the default run requires no `sudo`. Checks that need `sudo` (rich WiFi metrics via `wdutil info`, full disconnect logs, ARP table writes) must (a) try `sudo -n` first, (b) gracefully degrade and print a one-line hint about what you'd unlock by re-running with `sudo`, (c) never prompt for password mid-run.
- **Parallelism:** the current script runs everything sequentially. Many checks are independent (DNS to multiple resolvers, TCP reach to multiple ports, WiFi scan, NTP). Run independent checks in parallel using background jobs + `wait`. Target: full default run completes in ≤ 30 seconds on a healthy network (currently ~15s; the new features will add load but parallelism should keep it close).
- **Output modes:**
  - Default: human-readable colored output to stdout + ANSI-stripped log to `~/net-diag/<timestamp>.log`.
  - `--json` flag: machine-readable single JSON object to stdout (no colors, no log writing unless `--log` is also passed). Use this shape: `{ "version": "...", "timestamp": "...", "interface": {...}, "wifi": {...}, "gateway": {...}, "public": {...}, "dns": [...], "traceroute": {...}, "per_hop": [...], "bufferbloat": {...}, "mtu": {...}, "ipv6": {...}, "vpn": {...}, "tcp_reach": [...], "wifi_scan": [...], "wifi_disconnects": [...], "speedtest": {...}, "ntp": {...}, "duplicate_ips": [...], "dhcp": {...}, "diagnosis": [...] }`. Fields can be `null` if a check was skipped.
  - `--quiet` flag: only print the Diagnosis section to stdout (still writes the full log).
  - `--quick` (already present): skip slow checks (per-hop loss, speed test, baseline diff, WiFi scan).
- **Exit codes:** `0` = healthy, `1` = warnings only, `2` = at least one critical issue identified by the diagnosis stage, `3` = script error / could not run.
- **CLI surface:**
  ```
  netdiag [TARGET] [--quick] [--quiet] [--json] [--no-gping]
          [--speed] [--no-speed] [--mtu-only] [--wifi-only]
          [--baseline] [--no-baseline] [--log PATH] [-h|--help]
  ```
  Positional `TARGET` is an optional hostname/IP that gets added to ping, traceroute, TCP-reach, and DNS sections. Example: `netdiag github.com`.
- **Idempotent + safe:** no destructive actions. Diagnostic only. Never touch routing tables, DNS settings, WiFi associations, ARP cache writes, etc. Read-only.
- **shellcheck-clean:** no warnings at default severity. Add `# shellcheck disable=…` comments only with justification.

## Plan — the 14 enhancements

Implement these in the order listed (high-impact first). Each one should produce a labeled output section, contribute to the JSON output, and feed into the Diagnosis stage where appropriate.

### High-value

1. **Bufferbloat / latency-under-load.** Start a controlled download in the background (`curl -o /dev/null https://speed.cloudflare.com/__down?bytes=104857600` capped to ~10 seconds), simultaneously sample `ping -i 0.2 <gateway>` and `ping -i 0.2 1.1.1.1` for the duration. Compare idle RTT (from the existing gateway-reachability section) vs loaded RTT. Grade A–F using the DSLReports/Waveform thresholds: A < +5ms, B < +30ms, C < +60ms, D < +200ms, F ≥ +200ms. Surface both gateway-side and internet-side bloat separately — they have different culprits (router QoS vs ISP). Feed into Diagnosis: high bloat at gateway hop = "your router lacks SQM/fq_codel"; high bloat at ISP hop = "your ISP's CPE is the bottleneck".

2. **PMTU black-hole probe.** Send DF-set pings of decreasing size (`ping -D -s SIZE 1.1.1.1`) — try 1472, 1452, 1432, 1412, 1392, 1372, 1352, 1300, 1200 — to find the largest payload that gets a reply. Effective MTU = payload + 28. Report effective path MTU; flag if < 1500 (PPPoE/VPN/tunneling reduction). Feed into Diagnosis: an MTU below 1500 with otherwise healthy connectivity is the classic cause of "some sites work, others hang forever."

3. **Continuous loss test via `mtr`.** Replace the current "5-packet per hop" probe with `mtr -r -c 60 -n -i 0.2 1.1.1.1` (a 60-second run reporting per-hop average loss, last/best/worst/avg/stdev RTT). If `mtr` isn't installed, fall back to the current per-hop loop but print the install hint. Parse the report; flag any hop with > 2% loss; identify the *first* hop that introduces loss (the one before it had 0% — that hop is the culprit, not all subsequent ones).

4. **IPv6 parity.** Detect if interface has a global v6 address (`ifconfig <iface> inet6` → look for non-link-local). If yes: ping6 the v6 gateway (`ipconfig getv6packet <iface>` or extract from `ndp -an`), resolve AAAA records for the same names tested in v4 DNS, traceroute6 to `2606:4700:4700::1111` (Cloudflare v6), and run a TCP-reach test to a v6-only host (`ipv6.google.com`). Report v4-only vs dual-stack vs v6-only failures. Feed into Diagnosis: v6 broken with v4 working = misconfigured router or ISP, AND many "this site is slow/broken" reports are Happy-Eyeballs masking partial v6 failure.

5. **VPN-active detection.** Check for: (a) managed VPNs via `scutil --nc list` (look for "Connected"), (b) WireGuard/Tailscale interfaces (`ifconfig | grep -E '^(utun|wg)'`), (c) Tailscale specifically via `tailscale status` if installed, (d) `route -n get default` showing a `utun*` interface as the default route. If VPN is active, prominently flag it at the top of output: "VPN active via <name>; the 'gateway' below is the VPN endpoint, not your local router." Optionally re-run gateway + public checks against the physical interface (`route -n get -ifscope en0 default`) for comparison.

6. **TCP reach (not just ICMP).** Run `nc -G 3 -z <host> <port>` against a panel: `1.1.1.1:443`, `1.1.1.1:53`, `8.8.8.8:443`, `github.com:443`, `apple.com:443`. Parallel. Some networks block ICMP outright but allow TCP — this distinguishes "the network is down" from "ICMP is just filtered." Include any user-provided `TARGET` host on 443. Feed into Diagnosis: if TCP/443 works but ICMP doesn't → flag "ICMP filtered, ignore the ping-based failures."

### Medium-value

7. **WiFi neighborhood scan.** If on WiFi and `sudo` is available, run `sudo wdutil scan` (or `system_profiler SPAirPortDataType -detailLevel basic`) to enumerate nearby APs with their SSID, channel, and RSSI. Tabulate channel utilization (count of APs on each 2.4GHz channel 1/6/11 and each 5GHz channel). Flag if your current channel has > 3 other APs on it, or any neighboring AP with stronger RSSI than your own. Feed into Diagnosis: "5 other APs on channel 6 + your RSSI is -68 → switch to channel 11 or 5GHz."

8. **WiFi disconnect / roam history.** Pull recent events with `log show --predicate 'subsystem CONTAINS[c] "wifi" OR subsystem CONTAINS[c] "airport"' --info --last 1h 2>/dev/null` (no sudo needed for the user's own logs). Filter for keywords: "association", "disassoc", "deauth", "roam", "link down", "link up". Count disconnects/reassociations in the past hour; if > 3, flag "WiFi link is flapping." Show the last 5 events. If `sudo` is available, include the kernel ASSOC/DEAUTH reason codes for richer context.

9. **Speed test.** Optional via `--speed` flag (or run automatically only if `--quick` not set and last run was > 24h ago). Use Ookla's `speedtest` CLI if installed, else `speedtest-cli` (open source), else skip with install hint. Capture down/up/latency/jitter; record into baseline. Don't run during bufferbloat test — sequence them.

10. **NTP / time-sync check.** Use `sntp -t 3 time.apple.com` (built-in) and compare its returned time against the system clock. Flag drift > 30s — wrong system time breaks TLS certificate validation and looks like inexplicable "broken internet." Also check `systemsetup -getusingnetworktime` and `systemsetup -getnetworktimeserver` (no sudo needed for `-get` queries).

11. **Baseline diff.** Read the most recent N (default 10) `~/net-diag/*.log` files. Parse out the key metrics from each: gateway RTT, gateway loss %, hop count to 1.1.1.1, per-hop median RTT, public IP, ISP/ASN, WiFi RSSI/SNR/channel, speedtest down/up (if present), PMTU, bufferbloat grade. Compute medians and surface regressions in the current run: "Gateway RTT is 4× the 30-day median," "WiFi RSSI dropped from -55 to -78 since yesterday," "ISP changed from SPACEX-STARLINK to <other> — fallback connection active?" This is the highest-value long-term debugging feature; build the storage format to make it easy to extend.

12. **Custom target argument.** `netdiag github.com` adds the user's host to: ping panel, traceroute panel (a second traceroute), TCP-reach panel (TCP/443), DNS panel (resolve via all configured resolvers). Useful for "this specific site is slow" investigations.

### Polish

13. **Duplicate-IP / ARP conflict detection.** `arp -an` parsed; flag any IP that appears with two different MAC addresses, or any entry marked `(incomplete)` for the gateway. Use `arping` if installed for a more active check; otherwise just observe.

14. **DHCP lease detail.** The current script already pulls `ipconfig getsummary <iface>` but doesn't surface lease info. Add: lease start, lease expiration, time remaining, DHCP server identifier. Flag if lease expires within the next hour (renewal failures can cause sudden drops). Also surface the DNS servers handed out by DHCP separately from the configured system resolver — they sometimes differ if a user manually overrode DNS.

## JSON-output schema details

For each new section, follow this shape exactly so downstream tooling can rely on it. Use `null` for skipped, empty arrays for "ran but no findings."

```json
{
  "version": "0.2.0",
  "timestamp": "2026-05-30T01:31:27Z",
  "interface": {"name": "en0", "ip": "192.168.50.56", "mac": "...", "type": "wifi"},
  "wifi": {"ssid": "...", "bssid": "...", "rssi": -55, "noise": -90, "snr": 35, "channel": "36 (5GHz)", "phy": "11ax", "tx_rate_mbps": 866, "security": "FT_PSK"},
  "gateway": {"ip": "192.168.50.1", "loss_pct": 0, "rtt_avg_ms": 3.7},
  "public": {"ip": "...", "asn": "AS14593", "isp": "SPACEX-STARLINK", "city": "Quito", "country": "EC", "captive_portal": false},
  "dns": [{"resolver": "1.1.1.1", "name": "apple.com", "answer": "...", "elapsed_ms": 12, "ok": true}],
  "traceroute": {"target": "1.1.1.1", "hops": [{"n": 1, "ip": "192.168.50.1", "rtt_ms": 4.0}]},
  "mtr": {"target": "1.1.1.1", "duration_s": 60, "hops": [{"n": 1, "ip": "...", "loss_pct": 0, "avg_ms": 4.0, "best_ms": 3.5, "worst_ms": 5.2, "stdev_ms": 0.4}], "first_lossy_hop": null},
  "bufferbloat": {"idle_gw_rtt_ms": 3.7, "loaded_gw_rtt_ms": 4.5, "idle_inet_rtt_ms": 25, "loaded_inet_rtt_ms": 220, "gw_grade": "A", "inet_grade": "D"},
  "mtu": {"effective": 1500, "path": [{"size": 1472, "ok": true}]},
  "ipv6": {"available": true, "global_addr": "...", "gateway": "...", "ping6_loss_pct": 0, "aaaa_resolve_ok": true, "traceroute6_hops": 8, "tcp_v6_ok": true},
  "vpn": {"active": false, "type": null, "name": null},
  "tcp_reach": [{"host": "1.1.1.1", "port": 443, "ok": true, "elapsed_ms": 28}],
  "wifi_scan": {"current_channel": "36", "current_channel_neighbors": 0, "interference_aps": [{"ssid": "...", "channel": "36", "rssi": -72}]},
  "wifi_disconnects": {"window_hours": 1, "count": 0, "recent_events": []},
  "speedtest": {"down_mbps": 250.3, "up_mbps": 12.1, "latency_ms": 32, "jitter_ms": 4, "server": "..."},
  "ntp": {"system_time": "...", "ntp_time": "...", "drift_seconds": 0.4, "using_network_time": true},
  "duplicate_ips": [],
  "dhcp": {"server": "192.168.50.1", "lease_start": "...", "lease_end": "...", "time_remaining_s": 86000, "dns_servers": ["192.168.50.1"]},
  "baseline": {"compared_runs": 10, "regressions": [{"metric": "gateway_rtt_ms", "current": 12.3, "median_30d": 3.5, "factor": 3.5}]},
  "diagnosis": [{"severity": "warn|critical", "summary": "...", "evidence": ["..."], "recommendation": "..."}]
}
```

## Repo setup

Create a new public GitHub repository:

- **Name:** `netdiag` (preferred) or `mac-netdiag` if `netdiag` is taken on your account.
- **License:** MIT, in `LICENSE`.
- **Description:** "Comprehensive network diagnostic CLI for macOS — finds the root cause of internet problems."
- **Topics:** `macos`, `networking`, `cli`, `bash`, `diagnostics`, `wifi`, `bufferbloat`, `mtr`, `troubleshooting`.

### File structure

```
netdiag/
├── bin/
│   └── netdiag                # main executable (bash entry point)
├── lib/                       # if you split into modules
│   ├── common.sh
│   ├── wifi.sh
│   ├── dns.sh
│   ├── bufferbloat.sh
│   ├── mtu.sh
│   ├── mtr.sh
│   ├── ipv6.sh
│   ├── vpn.sh
│   ├── tcp_reach.sh
│   ├── ntp.sh
│   ├── baseline.sh
│   └── diagnosis.sh
├── helpers/                   # if you decided to use Python for parsing
│   └── parse_mtr.py           # e.g.
├── tests/
│   ├── fixtures/              # captured sample outputs (ipconfig, wdutil, mtr) for unit tests
│   └── test_*.bats            # bats-core tests
├── examples/
│   ├── sample-output.txt      # paste a real full-run from your machine here
│   └── sample-output.json     # paste --json output here
├── docs/
│   ├── ARCHITECTURE.md        # explain the bash-vs-Python split decision
│   └── DIAGNOSIS-RULES.md     # document each diagnosis rule with rationale
├── .github/
│   └── workflows/
│       ├── shellcheck.yml     # run shellcheck on every push
│       └── bats.yml           # run bats-core test suite on macos-latest runner
├── README.md
├── CHANGELOG.md               # follow keep-a-changelog format; start at 0.2.0
├── LICENSE
├── install.sh                 # one-liner installer (symlinks bin/netdiag into /usr/local/bin or ~/bin)
└── .gitignore
```

### README.md sections (in order)

1. **What it does** — one paragraph + a sample-output screenshot (a `examples/sample-output.txt` quoted block is fine).
2. **Why** — quick "single-pane-of-glass diagnosis instead of running 8 commands manually."
3. **Install** — three options:
   - Homebrew tap: `brew install <your-username>/netdiag/netdiag` (you'll need a second repo `homebrew-netdiag` with a `Formula/netdiag.rb` — include that formula in the README even if you don't create the tap repo immediately).
   - One-liner: `curl -fsSL https://raw.githubusercontent.com/<user>/netdiag/main/install.sh | bash`.
   - Manual: `git clone && ln -s $(pwd)/bin/netdiag /usr/local/bin/netdiag`.
4. **Usage** — all CLI flags with short examples.
5. **Sample output** — quote `examples/sample-output.txt` (truncated if long).
6. **Diagnosis rules** — list each rule from `docs/DIAGNOSIS-RULES.md` briefly.
7. **Dependencies** — built-in (macOS), Homebrew-optional (mtr, gping, speedtest, jq), and what degrades if missing.
8. **Permissions** — what works without sudo, what you unlock with sudo.
9. **JSON mode** — show the schema and a `jq` example.
10. **Roadmap** — copy the "future ideas" section below.
11. **Contributing** — point at `tests/`, shellcheck, conventional commits.
12. **License** — MIT.

### CI

- `.github/workflows/shellcheck.yml`: run shellcheck on push/PR against `bin/netdiag` and `lib/*.sh` with default severity.
- `.github/workflows/bats.yml`: on a `macos-latest` runner, install `bats-core` and run `tests/`. Include at least these tests: WiFi-detection from a fixture, DNS parsing, mtr report parsing, JSON output is valid JSON (pipe to `jq .`), exit-code-2 on simulated critical issue.

### Distribution

- After the main repo is created, also draft (don't necessarily push) a `homebrew-netdiag` repo with `Formula/netdiag.rb` that points at the latest release tarball. Include it in the README.
- Tag releases as `v0.2.0` etc. and use `gh release create` with a CHANGELOG entry.

### Repo creation steps

Use `gh` CLI for repo creation. Don't push anything until you've run the script and verified `examples/sample-output.txt` looks sane. Commit history should be clean — one commit per logical feature group is fine.

```bash
cd ~/dev   # or wherever you keep projects
gh repo create netdiag --public --description "Comprehensive network diagnostic CLI for macOS" \
  --license mit --gitignore Shell
cd netdiag
# ... build the project ...
git add -A
git commit -m "Initial release: 14 diagnostic checks + JSON output + diagnosis engine"
git push -u origin main
gh release create v0.2.0 --generate-notes
```

## Future ideas (note in README roadmap; don't build now)

- Web UI (small embedded HTTP server that serves the latest `~/net-diag/*.log` as HTML)
- Continuous mode (`--watch`): run every N minutes and alert on regressions
- Slack/Discord webhook on critical diagnosis
- Linux port
- iperf3 to user-provided server for LAN throughput
- DNS-over-HTTPS / DNS-over-TLS reachability check
- Detect Apple Private Relay active
- Detect captive DNS (resolver returning A records for non-existent domains)

## The starting script (verbatim — current state of ~/bin/netdiag)

```bash
#!/usr/bin/env bash
# netdiag — full network investigation for macOS.
# Runs a battery of checks, writes a timestamped report, attempts a root-cause
# diagnosis (wifi vs router vs ISP vs DNS), then launches gping against the
# discovered hops for live monitoring.
#
# Usage: netdiag [--no-gping] [--quick]

set -u

NO_GPING=0
QUICK=0
for arg in "$@"; do
  case "$arg" in
    --no-gping) NO_GPING=1 ;;
    --quick)    QUICK=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

LOG_DIR="$HOME/net-diag"
mkdir -p "$LOG_DIR"
STAMP="$(date +%Y-%m-%d-%H%M%S)"
LOG="$LOG_DIR/$STAMP.log"

# Colors (also stripped from the log)
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=; C_BOLD=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=
fi

# Print to terminal AND log (log gets ANSI stripped)
say() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOG"
}
hdr() { say ""; say "${C_BOLD}${C_BLU}── $* ──${C_RESET}"; }
ok()   { say "  ${C_GRN}✓${C_RESET} $*"; }
warn() { say "  ${C_YEL}⚠${C_RESET} $*"; }
bad()  { say "  ${C_RED}✗${C_RESET} $*"; }
info() { say "  ${C_DIM}·${C_RESET} $*"; }

# Findings — used by the diagnosis stage
WIFI_RSSI=""        # empty if unknown/wired
WIFI_NOISE=""
WIFI_SNR=""
GW_LOSS=""          # integer 0-100
GW_LATENCY=""       # ms
NEXTHOP_LOSS=""
DNS_OK=0            # 1 = working
PUBLIC_OK=0         # 1 = internet reachable
INTERFACE=""
GATEWAY=""
HOPS=()

say "${C_BOLD}netdiag${C_RESET}  ${C_DIM}$STAMP${C_RESET}"
say "${C_DIM}log: $LOG${C_RESET}"

# ── 1. Local interface + IP + gateway ──────────────────────────────────────
hdr "Local network"
INTERFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
GATEWAY="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
LOCAL_IP=""
if [ -n "$INTERFACE" ]; then
  LOCAL_IP="$(ipconfig getifaddr "$INTERFACE" 2>/dev/null)"
fi
if [ -n "$INTERFACE" ] && [ -n "$GATEWAY" ]; then
  ok "Interface: $INTERFACE   IP: ${LOCAL_IP:-?}   Gateway: $GATEWAY"
else
  bad "No default route — no network configured."
fi

# Additional gateways (multi-homed?)
GW_COUNT="$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2}' | sort -u | wc -l | tr -d ' ')"
if [ "${GW_COUNT:-0}" -gt 1 ]; then
  warn "Multiple default gateways detected:"
  netstat -rn -f inet | awk '$1=="default"{print "      "$2"  ("$NF")"}' | tee -a "$LOG"
fi

# ── 2. WiFi info ───────────────────────────────────────────────────────────
hdr "WiFi"
IS_WIFI=0
SSID=""
# Detect WiFi via hardware port type (more reliable than networksetup -getairportnetwork,
# which is broken on some macOS versions and falsely reports "not associated").
if [ -n "$INTERFACE" ]; then
  HW_PORT="$(networksetup -listallhardwareports 2>/dev/null | awk -v d="$INTERFACE" '
    /^Hardware Port:/{port=substr($0, index($0,$3))}
    /^Device:/{if($2==d){print port; exit}}')"
  if printf '%s' "$HW_PORT" | grep -qi 'Wi-Fi\|AirPort'; then
    IS_WIFI=1
    # Pull SSID from ipconfig getsummary (works without sudo on modern macOS).
    SUMMARY="$(ipconfig getsummary "$INTERFACE" 2>/dev/null)"
    SSID="$(printf '%s\n' "$SUMMARY" | awk -F': ' '/^[[:space:]]*SSID[[:space:]]*:/{print $2; exit}')"
    BSSID="$(printf '%s\n' "$SUMMARY" | awk -F': ' '/^[[:space:]]*BSSID[[:space:]]*:/{print $2; exit}')"
    SEC="$(printf '%s\n' "$SUMMARY"   | awk -F': ' '/^[[:space:]]*Security[[:space:]]*:/{print $2; exit}')"
    ok "SSID: ${SSID:-?}  (interface $INTERFACE)"
    [ -n "$BSSID" ] && info "BSSID: $BSSID"
    [ -n "$SEC" ]   && info "Security: $SEC"
  fi
fi
if [ "$IS_WIFI" -eq 1 ]; then

  # Try wdutil for rich info (needs sudo). Non-interactive: only attempt if cached creds.
  WDUTIL_OUT=""
  if sudo -n true 2>/dev/null; then
    WDUTIL_OUT="$(sudo -n wdutil info 2>/dev/null)"
  fi

  if [ -n "$WDUTIL_OUT" ]; then
    RSSI="$(printf '%s\n' "$WDUTIL_OUT"   | awk -F': ' '/^[[:space:]]*RSSI/{gsub(/ dBm/,"",$2); print $2; exit}')"
    NOISE="$(printf '%s\n' "$WDUTIL_OUT"  | awk -F': ' '/^[[:space:]]*Noise/{gsub(/ dBm/,"",$2); print $2; exit}')"
    CHAN="$(printf '%s\n' "$WDUTIL_OUT"   | awk -F': ' '/^[[:space:]]*Channel/{print $2; exit}')"
    TXRATE="$(printf '%s\n' "$WDUTIL_OUT" | awk -F': ' '/Tx Rate/{print $2; exit}')"
    PHYMODE="$(printf '%s\n' "$WDUTIL_OUT"| awk -F': ' '/PHY Mode/{print $2; exit}')"
    WIFI_RSSI="${RSSI:-}"
    WIFI_NOISE="${NOISE:-}"
    [ -n "$RSSI" ]  && info "RSSI: ${RSSI} dBm"
    [ -n "$NOISE" ] && info "Noise: ${NOISE} dBm"
    if [ -n "$RSSI" ] && [ -n "$NOISE" ]; then
      WIFI_SNR=$((RSSI - NOISE))
      info "SNR: ${WIFI_SNR} dB"
    fi
    [ -n "$CHAN" ]    && info "Channel: $CHAN"
    [ -n "$PHYMODE" ] && info "PHY: $PHYMODE"
    [ -n "$TXRATE" ]  && info "Tx Rate: $TXRATE"

    # Quality interpretation
    if [ -n "$RSSI" ]; then
      if   [ "$RSSI" -ge -55 ]; then ok   "Signal: excellent (RSSI ${RSSI})"
      elif [ "$RSSI" -ge -65 ]; then ok   "Signal: good (RSSI ${RSSI})"
      elif [ "$RSSI" -ge -72 ]; then warn "Signal: fair (RSSI ${RSSI}) — may see latency spikes"
      elif [ "$RSSI" -ge -80 ]; then warn "Signal: weak (RSSI ${RSSI}) — expect retransmissions"
      else                            bad  "Signal: very weak (RSSI ${RSSI}) — likely the problem"
      fi
    fi
    if [ -n "$WIFI_SNR" ]; then
      if   [ "$WIFI_SNR" -ge 40 ]; then :
      elif [ "$WIFI_SNR" -ge 25 ]; then info "SNR fine"
      elif [ "$WIFI_SNR" -ge 15 ]; then warn "SNR low (${WIFI_SNR} dB) — interference likely"
      else                              bad  "SNR very low (${WIFI_SNR} dB) — heavy interference"
      fi
    fi
  else
    warn "Rich WiFi metrics (RSSI/noise/channel) need sudo. Re-run as:"
    info "sudo netdiag    # for RSSI, noise, channel, PHY, tx rate"
  fi
else
  info "Not on WiFi (interface $INTERFACE looks wired)."
fi

# ── 3. Gateway reachability ────────────────────────────────────────────────
hdr "Gateway reachability"
if [ -n "$GATEWAY" ]; then
  PING_OUT="$(ping -c 10 -t 3 -i 0.2 "$GATEWAY" 2>&1)"
  printf '%s\n' "$PING_OUT" >> "$LOG"
  GW_LOSS="$(printf '%s\n' "$PING_OUT" | awk -F'[ %]' '/packet loss/{for(i=1;i<=NF;i++)if($i=="packet")print $(i-2)}' | head -1)"
  GW_LATENCY="$(printf '%s\n' "$PING_OUT" | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3)}' | head -1)"
  GW_LOSS="${GW_LOSS:-100}"
  if [ "${GW_LOSS%.*}" -eq 0 ]; then
    ok "Gateway $GATEWAY: 0% loss, ${GW_LATENCY} ms avg"
  elif [ "${GW_LOSS%.*}" -lt 20 ]; then
    warn "Gateway $GATEWAY: ${GW_LOSS}% loss, ${GW_LATENCY} ms"
  else
    bad "Gateway $GATEWAY: ${GW_LOSS}% loss — LAN/WiFi link is degraded"
  fi
else
  bad "No gateway to test."
fi

# ── 4. Public IP / ISP ─────────────────────────────────────────────────────
hdr "Public reachability"
PUB_OUT="$(curl -s -m 4 https://ifconfig.co/json 2>/dev/null)"
if [ -n "$PUB_OUT" ]; then
  PUBLIC_OK=1
  PUB_IP="$(printf '%s' "$PUB_OUT"   | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p')"
  PUB_ISP="$(printf '%s' "$PUB_OUT"  | sed -n 's/.*"asn_org": *"\([^"]*\)".*/\1/p')"
  PUB_CITY="$(printf '%s' "$PUB_OUT" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p')"
  PUB_CC="$(printf '%s' "$PUB_OUT"   | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p')"
  ok "Public IP: $PUB_IP  ($PUB_ISP, $PUB_CITY $PUB_CC)"
else
  bad "Could not reach ifconfig.co — no internet, captive portal, or DNS broken."
fi

# Captive portal sniff
CAPTIVE="$(curl -s -m 3 -o /dev/null -w '%{http_code} %{redirect_url}' http://captive.apple.com/hotspot-detect.html 2>/dev/null)"
if printf '%s' "$CAPTIVE" | grep -q '^200'; then
  ok "No captive portal."
elif printf '%s' "$CAPTIVE" | grep -qE '^3[0-9][0-9]'; then
  warn "Captive portal detected (HTTP $CAPTIVE) — log in via browser."
fi

# ── 5. DNS ─────────────────────────────────────────────────────────────────
hdr "DNS"
dns_check() {
  local resolver="$1" name="$2" out
  out="$(dig +time=2 +tries=1 +short @"$resolver" "$name" 2>/dev/null | head -1)"
  if [ -n "$out" ]; then ok "$resolver → $name = $out"; return 0
  else bad "$resolver → $name FAILED"; return 1; fi
}
DNS_FAIL=0
SYS_RES="$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
[ -n "$SYS_RES" ] && info "System resolver: $SYS_RES"
for name in apple.com cloudflare.com; do
  if [ -n "$SYS_RES" ]; then
    dns_check "$SYS_RES" "$name" || DNS_FAIL=$((DNS_FAIL+1))
  fi
  dns_check 1.1.1.1 "$name" || DNS_FAIL=$((DNS_FAIL+1))
  dns_check 8.8.8.8 "$name" || DNS_FAIL=$((DNS_FAIL+1))
done
[ "$DNS_FAIL" -eq 0 ] && DNS_OK=1

# ── 6. Traceroute ──────────────────────────────────────────────────────────
hdr "Traceroute to 1.1.1.1"
TRACE_OUT="$(traceroute -n -q 1 -w 2 -m 18 1.1.1.1 2>/dev/null)"
printf '%s\n' "$TRACE_OUT" | tee -a "$LOG" | sed 's/^/  /'
# Extract hop IPs (skip *'s)
while read -r line; do
  ip="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}')"
  [ -n "$ip" ] && HOPS+=("$ip")
done <<EOF
$(printf '%s\n' "$TRACE_OUT" | tail -n +2)
EOF

# ── 7. Per-hop quick ping (find first lossy hop) ───────────────────────────
if [ "$QUICK" -eq 0 ] && [ "${#HOPS[@]}" -gt 0 ]; then
  hdr "Per-hop loss (5 packets each)"
  i=0
  FIRST_LOSSY=""
  for h in "${HOPS[@]}"; do
    i=$((i+1))
    out="$(ping -c 5 -t 2 -i 0.2 "$h" 2>&1)"
    loss="$(printf '%s\n' "$out" | awk -F'[ %]' '/packet loss/{for(j=1;j<=NF;j++)if($j=="packet")print $(j-2)}' | head -1)"
    lat="$(printf '%s\n' "$out" | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3)}' | head -1)"
    loss="${loss:-100}"
    if [ "${loss%.*}" -eq 0 ]; then
      info "hop $i  $h  0% loss  ${lat} ms"
    else
      warn "hop $i  $h  ${loss}% loss  ${lat:-?} ms"
      [ -z "$FIRST_LOSSY" ] && FIRST_LOSSY="hop $i ($h)"
      [ "$i" -eq 2 ] && NEXTHOP_LOSS="$loss"
    fi
  done
  [ -n "$FIRST_LOSSY" ] && warn "First lossy hop: $FIRST_LOSSY"
fi

# ── 8. Diagnosis ───────────────────────────────────────────────────────────
hdr "Diagnosis"
DIAG=()
if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] && [ "$WIFI_RSSI" -lt -75 ]; then
  DIAG+=("WiFi signal is weak (RSSI ${WIFI_RSSI}). Move closer to the AP, or switch bands/AP.")
fi
if [ -n "$WIFI_SNR" ] && [ "$WIFI_SNR" -lt 20 ]; then
  DIAG+=("Low WiFi SNR (${WIFI_SNR} dB) suggests interference on this channel.")
fi
if [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -ge 20 ]; then
  if [ "$IS_WIFI" -eq 1 ] && [ -n "$WIFI_RSSI" ] && [ "$WIFI_RSSI" -lt -70 ]; then
    DIAG+=("Gateway loss + weak WiFi → the WiFi link is your problem, not the router/ISP.")
  else
    DIAG+=("Gateway loss with healthy WiFi → router itself is misbehaving (reboot it).")
  fi
fi
if [ "$PUBLIC_OK" -eq 0 ] && [ -n "$GW_LOSS" ] && [ "${GW_LOSS%.*}" -eq 0 ]; then
  if [ "$DNS_OK" -eq 0 ]; then
    DIAG+=("LAN healthy but no public reach AND DNS failing → DNS or upstream ISP outage.")
  else
    DIAG+=("LAN healthy, DNS working, but no public reach → ISP-side outage.")
  fi
fi
if [ "$DNS_OK" -eq 0 ] && [ "$PUBLIC_OK" -eq 1 ]; then
  DIAG+=("Internet reachable but DNS partially broken → try changing resolver (1.1.1.1 / 8.8.8.8).")
fi
if [ "${#DIAG[@]}" -eq 0 ]; then
  ok "Nothing obviously wrong from these checks."
else
  for d in "${DIAG[@]}"; do bad "$d"; done
fi

say ""
say "${C_DIM}Report saved to: $LOG${C_RESET}"

# ── 9. Launch gping ────────────────────────────────────────────────────────
if [ "$NO_GPING" -eq 0 ] && command -v gping >/dev/null 2>&1; then
  TARGETS=()
  [ -n "$GATEWAY" ] && TARGETS+=("$GATEWAY")
  for h in "${HOPS[@]}"; do TARGETS+=("$h"); done
  TARGETS+=(1.1.1.1 8.8.8.8)
  if [ "${#TARGETS[@]}" -gt 0 ]; then
    say ""
    say "${C_BOLD}Launching gping on ${#TARGETS[@]} targets (Ctrl-C to exit)…${C_RESET}"
    sleep 1
    exec gping "${TARGETS[@]}"
  fi
fi
```

## Acceptance criteria

You are done when ALL of the following are true:

1. `netdiag` runs end-to-end on macOS with all 14 new sections, no shellcheck warnings, no uncaught errors.
2. `netdiag --json` produces valid JSON matching the schema above; `netdiag --json | jq .` succeeds.
3. `netdiag --quick` skips bufferbloat, mtr (or per-hop loop), speed test, baseline diff, WiFi scan; finishes in ≤ 8 seconds on a healthy network.
4. `sudo netdiag` adds RSSI/noise/channel/PHY/tx_rate to the WiFi section AND the WiFi neighborhood scan.
5. `netdiag github.com` adds github.com to ping, traceroute, TCP-reach, and DNS sections.
6. Exit codes work as specified (0/1/2/3).
7. A successful run writes a parseable human-readable log to `~/net-diag/<timestamp>.log`.
8. The Diagnosis section explains conclusions with evidence (e.g., "Bufferbloat grade D: loaded RTT 220ms vs idle 25ms → router lacks SQM").
9. README is complete with all sections listed above; `examples/sample-output.txt` and `examples/sample-output.json` are real captures from your own run.
10. The repo is created on GitHub, tagged `v0.2.0`, with passing CI (shellcheck + bats).
11. `docs/ARCHITECTURE.md` explains the bash-vs-Python decision; `docs/DIAGNOSIS-RULES.md` lists every diagnosis rule.

Begin with the short written plan as instructed above, then implement.
