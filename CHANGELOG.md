# Changelog

All notable changes to `netdiag` are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Known

- `.github/workflows/shellcheck.yml` still carries a stale
  `nimbalyst-local` entry in `ignore_paths`, left over from another
  project, and CI has no smoke test that runs netdiag end to end. Neither
  is fixed here because pushing workflow files needs a token scope this
  branch doesn't have — both are one-file changes for a maintainer.

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
