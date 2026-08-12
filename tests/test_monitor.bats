#!/usr/bin/env bats
#
# `netdiag --monitor` — the stream the menu-bar app consumes.
#
# The load-bearing test in this file is the parity block: for the same
# network state, lib/monitor.sh and lib/diagnosis.sh must name the same
# rule IDs. If they drift, the app shows a green dot over a red report and
# the user has no way to tell which one lied. That is checked here against
# synthetic state rather than by blocking ICMP with a firewall rule, which
# would test one condition once on one machine — this tests every condition
# on every push.
#
# Network-free by construction: every test drives the pure functions
# (_mon_rules, monitor_sample.py) or exercises argument validation, which
# exits before any probe runs.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  HELPERS="$REPO/helpers"
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  NETDIAG_VERSION="test"
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/netid.sh
  . "$REPO/lib/netid.sh"
  # shellcheck source=../lib/monitor.sh
  . "$REPO/lib/monitor.sh"
}

# Reset both rule engines to a healthy baseline, then let each test perturb
# exactly the field under study.
reset_state() {
  # monitor side
  MON_LINK_UP=1 MON_IFACE_TYPE=wifi MON_GATEWAY=192.168.1.1
  MON_GW_LOSS=0 MON_GW_RTT=3 MON_WIFI_RSSI="" MON_WIFI_SNR=""
  MON_DNS_OK=1 MON_TCP_OK=1 MON_PUBLIC_OK=1 MON_CAPTIVE=0
  MON_VPN_ACTIVE=0 MON_ICMP_FILTERED=0 MON_DEGRADED=0
  # scanner side
  GATEWAY=192.168.1.1 IS_WIFI=1 GW_LOSS=0 WIFI_RSSI="" WIFI_SNR=""
  DNS_OK=1 DNS_LINES="x|y|z|OK" PUBLIC_OK=1 PUBLIC_CHECKED=1
  TCP_REACH_ANY_OK=1 VPN_ACTIVE=0 CAPTIVE_PORTAL=0
  IPV6_AVAILABLE=0 MTU_EFFECTIVE="" MTR_FIRST_LOSSY_HOP=""
  INET_LOSS="" INET_LOSS_ALT="" NTP_DRIFT_S="" DHCP_TIME_REMAINING_S=""
  ARP_GW_INCOMPLETE=0 ARP_DUPLICATE_IPS="" DHCP_DNS_SERVERS="" SYS_RES_ALL=""
  WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0 WIFI_DISCONNECT_COUNT=0
  BUFFERBLOAT_GW_GRADE="" BUFFERBLOAT_INET_GRADE=""
  DIAG=(); DIAG_SEV=(); DIAG_RULE=(); MAX_SEVERITY=0
}

monitor_rules() {
  _mon_rules
  printf '%s' "$MON_RULES" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' '
}

# The scanner's rules, narrowed to the vocabulary a between-scans probe can
# reach. Everything the monitor cannot measure (NT-1, DI-*, DH-1, BL-1,
# M1, MT1, V6-1, B1/B2, WS-1, WD-1) is scan-only by design and must not be
# claimed by the stream.
MONITOR_VOCABULARY='^(N1|G1|G2|G3|P1|P2|D1|W1|W2|TCP-1|VPN-1)$'

scanner_rules() {
  . "$REPO/lib/diagnosis.sh"
  diagnosis_run >/dev/null
  printf '%s\n' "${DIAG_RULE[@]:-}" | grep -E "$MONITOR_VOCABULARY" | sort | tr '\n' ' '
}

# ── Rule parity: the monitor and the scanner agree ───────────────────────

@test "parity: a healthy network produces no rules on either side" {
  reset_state
  [ "$(monitor_rules)" = "$(scanner_rules)" ]
  reset_state
  [ -z "$(monitor_rules)" ]
}

@test "parity: heavy gateway loss on a strong signal blames the router (G2)" {
  reset_state; MON_GW_LOSS=25 GW_LOSS=25 MON_WIFI_RSSI=-60 WIFI_RSSI=-60
  local m s; m="$(monitor_rules)"; reset_state
  MON_GW_LOSS=25 GW_LOSS=25 MON_WIFI_RSSI=-60 WIFI_RSSI=-60; s="$(scanner_rules)"
  [ "$m" = "$s" ]
  [[ "$m" == *"G2"* ]]
}

@test "parity: the same loss on a weak signal blames the radio (G1)" {
  reset_state; MON_GW_LOSS=25 GW_LOSS=25 MON_WIFI_RSSI=-72 WIFI_RSSI=-72
  local m; m="$(monitor_rules)"; reset_state
  MON_GW_LOSS=25 GW_LOSS=25 MON_WIFI_RSSI=-72 WIFI_RSSI=-72
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"G1"* ]]
}

@test "parity: loss in the warn band produces G3 on both" {
  reset_state; MON_GW_LOSS=15 GW_LOSS=15
  local m; m="$(monitor_rules)"; reset_state; MON_GW_LOSS=15 GW_LOSS=15
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"G3"* ]]
}

@test "parity: on an ICMP-filtering network both name TCP-1 alongside the loss rule" {
  # The monitor must not quietly withhold G2 here. Suppression is the alert
  # engine's job; withholding the rule would make the stream disagree with
  # a scan taken one second later on the same link.
  reset_state; MON_GW_LOSS=100 GW_LOSS=100 MON_WIFI_RSSI=-50 WIFI_RSSI=-50
  local m; m="$(monitor_rules)"; reset_state
  MON_GW_LOSS=100 GW_LOSS=100 MON_WIFI_RSSI=-50 WIFI_RSSI=-50
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"TCP-1"* ]]
  [[ "$m" == *"G2"* ]]
}

@test "the icmp_filtered flag is set so the alert engine can suppress" {
  reset_state; MON_GW_LOSS=100
  _mon_rules
  [ "$MON_ICMP_FILTERED" -eq 1 ]
}

@test "parity: internet down with DNS also failing is P1 on both" {
  reset_state; MON_PUBLIC_OK=0 PUBLIC_OK=0 MON_DNS_OK=0 DNS_OK=0
  local m; m="$(monitor_rules)"; reset_state
  MON_PUBLIC_OK=0 PUBLIC_OK=0 MON_DNS_OK=0 DNS_OK=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"P1"* ]]
}

@test "parity: internet down with DNS working is P2 on both" {
  reset_state; MON_PUBLIC_OK=0 PUBLIC_OK=0
  local m; m="$(monitor_rules)"; reset_state; MON_PUBLIC_OK=0 PUBLIC_OK=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"P2"* ]]
}

@test "parity: DNS failing while the internet is reachable is D1 on both" {
  reset_state; MON_DNS_OK=0 DNS_OK=0
  local m; m="$(monitor_rules)"; reset_state; MON_DNS_OK=0 DNS_OK=0
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"D1"* ]]
}

@test "parity: a weak signal is W1 on both" {
  reset_state; MON_WIFI_RSSI=-80 WIFI_RSSI=-80
  local m; m="$(monitor_rules)"; reset_state; MON_WIFI_RSSI=-80 WIFI_RSSI=-80
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"W1"* ]]
}

@test "parity: a noisy channel is W2 on both" {
  reset_state; MON_WIFI_SNR=10 WIFI_SNR=10
  local m; m="$(monitor_rules)"; reset_state; MON_WIFI_SNR=10 WIFI_SNR=10
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"W2"* ]]
}

@test "parity: an active VPN is VPN-1 on both" {
  reset_state; MON_VPN_ACTIVE=1 VPN_ACTIVE=1
  local m; m="$(monitor_rules)"; reset_state; MON_VPN_ACTIVE=1 VPN_ACTIVE=1
  [ "$m" = "$(scanner_rules)" ]
  [[ "$m" == *"VPN-1"* ]]
}

@test "parity: no default route is N1 on both" {
  reset_state; MON_LINK_UP=0 GATEWAY=""
  local m; m="$(monitor_rules)"; reset_state; MON_LINK_UP=0 GATEWAY=""
  [ "$m" = "$(scanner_rules)" ]
  [ "$m" = "N1 " ]
}

@test "the monitor claims no rule the scanner cannot also produce" {
  # Guards against the stream inventing a verdict. Every rule id the
  # monitor can emit must exist in lib/diagnosis.sh.
  local rule
  for rule in $(grep -oE '_mon_add_rule (critical|warn|info) [A-Za-z0-9-]+' "$REPO/lib/monitor.sh" \
                | awk '{print $3}' | sort -u); do
    case "$rule" in
      CP-1) continue ;;  # captive portal: a public.captive_portal fact, not a diagnosis rule
    esac
    grep -qE "add_diag [a-z]+ ${rule} " "$REPO/lib/diagnosis.sh" \
      || { echo "monitor emits '$rule', which lib/diagnosis.sh never does"; return 1; }
  done
}

@test "no rule in lib/monitor.sh carries an inline numeric cutoff" {
  run grep -nE '(loss_at_least|loss_below) "\$[A-Z_]+" [0-9]+|-lt -?[1-9][0-9]* \]|-ge -?[1-9][0-9]* \]|-gt -?[1-9][0-9]* \]' \
    "$REPO/lib/monitor.sh"
  [ "$status" -ne 0 ] || { echo "inline cutoff in monitor.sh:"; echo "$output"; return 1; }
}

# ── Severity and cadence ─────────────────────────────────────────────────

@test "severity is the worst rule that fired" {
  reset_state; MON_GW_LOSS=25 MON_VPN_ACTIVE=1
  _mon_rules
  [ "$MON_SEVERITY" = "critical" ]
}

@test "an info-only rule does not escalate severity or halve the cadence" {
  # A VPN notice is not a reason to probe twice as often for the rest of
  # the session.
  reset_state; MON_VPN_ACTIVE=1
  _mon_rules
  [ "$MON_SEVERITY" = "info" ]
  [ "$MON_DEGRADED" -eq 0 ]
}

@test "a fault switches the monitor to its degraded cadence" {
  reset_state; MON_GW_LOSS=15
  _mon_rules
  [ "$MON_DEGRADED" -eq 1 ]
}

@test "a dead link is degraded and reports nothing it did not measure" {
  reset_state; MON_LINK_UP=0
  _mon_rules
  [ "$MON_DEGRADED" -eq 1 ]
  [ "$MON_RULES" = "N1 " ]
}

# ── Unmeasured is not zero ───────────────────────────────────────────────

@test "an unmeasured public reach does not read as an outage" {
  # The slow tier has not run yet on the first sample. Treating its empty
  # value as false would announce "your ISP is down" one second after
  # launch, on a working connection.
  reset_state; MON_PUBLIC_OK="" MON_DNS_OK=""
  _mon_rules
  [[ "$MON_RULES" != *"P1"* ]]
  [[ "$MON_RULES" != *"P2"* ]]
  [[ "$MON_RULES" != *"D1"* ]]
}

@test "an unmeasured gateway loss does not fire a loss rule" {
  reset_state; MON_GW_LOSS=""
  _mon_rules
  [[ "$MON_RULES" != *"G1"* ]]
  [[ "$MON_RULES" != *"G2"* ]]
  [[ "$MON_RULES" != *"G3"* ]]
}

@test "an unmeasured RSSI does not fire W1" {
  reset_state; MON_WIFI_RSSI=""
  _mon_rules
  [[ "$MON_RULES" != *"W1"* ]]
}

# ── Sample shape ─────────────────────────────────────────────────────────

emit() {
  env -i PATH="$PATH" "$@" python3 "$HELPERS/monitor_sample.py"
}

@test "monitor_sample: an empty environment still emits one valid object" {
  run emit
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "monitor_sample: emits exactly one line" {
  run emit NETDIAG_MON_SEQ=1
  [ "${#lines[@]}" -eq 1 ]
}

@test "monitor_sample: every documented top-level key is present" {
  run emit
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for k in ('schema','version','ts','seq','refreshed','link','network','vpn',
          'gateway','wifi','dns','tcp','public','status'):
    assert k in d, k
"
}

@test "monitor_sample: an unmeasured probe is null, never false" {
  # dns.ok unset must be null. False would mean "we asked and it failed".
  run emit NETDIAG_MON_LINK_UP=1
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['dns']['ok'] is None, d['dns']
assert d['public']['ok'] is None, d['public']
assert d['tcp']['any_ok'] is None, d['tcp']
assert d['public']['captive_portal'] is None
"
}

@test "monitor_sample: a measured negative is false, not null" {
  run emit NETDIAG_MON_DNS_OK=0 NETDIAG_MON_PUBLIC_OK=0 NETDIAG_MON_CAPTIVE=0
  printf '%s' "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['dns']['ok'] is False
assert d['public']['ok'] is False
assert d['public']['captive_portal'] is False
"
}

@test "monitor_sample: wifi is null on a wired link rather than an object of nulls" {
  run emit NETDIAG_MON_IFACE_TYPE=wired
  printf '%s' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["wifi"] is None'
}

@test "monitor_sample: an SSID containing quotes and backslashes round-trips" {
  # The reason this goes through python instead of printf. A stream the app
  # parses forever will eventually meet one of these.
  run emit NETDIAG_MON_IFACE_TYPE=wifi 'NETDIAG_MON_SSID=say "hi"\back'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json,sys
assert json.load(sys.stdin)['link']['ssid'] == 'say \"hi\"\\\\back'
"
}

@test "monitor_sample: rules and severity ride through to status" {
  run emit NETDIAG_MON_RULES='G2 TCP-1 ' NETDIAG_MON_SEVERITY=critical \
           NETDIAG_MON_ICMP_FILTERED=1 NETDIAG_MON_DEGRADED=1 NETDIAG_MON_CADENCE_S=5
  printf '%s' "$output" | python3 -c "
import json,sys
s = json.load(sys.stdin)['status']
assert s['rules'] == ['G2','TCP-1'], s
assert s['severity'] == 'critical'
assert s['icmp_filtered'] is True
assert s['degraded'] is True
assert s['cadence_s'] == 5
"
}

@test "monitor_sample: TCP targets parse into structured entries" {
  run emit 'NETDIAG_MON_TCP_LINES=1.1.1.1|443|1|30
8.8.8.8|443|0|'
  printf '%s' "$output" | python3 -c "
import json,sys
t = json.load(sys.stdin)['tcp']['targets']
assert t == [{'host':'1.1.1.1','port':443,'ok':True,'elapsed_ms':30.0},
             {'host':'8.8.8.8','port':443,'ok':False,'elapsed_ms':None}], t
"
}

@test "monitor_sample: refreshed lists the tiers that actually ran" {
  run emit 'NETDIAG_MON_REFRESHED=fast medium '
  printf '%s' "$output" | python3 -c "
import json,sys
assert json.load(sys.stdin)['refreshed'] == ['fast','medium']
"
}

# ── Flags and exit codes ─────────────────────────────────────────────────
# These exit during argument validation, before any probe runs.

@test "--monitor with a non-numeric interval exits 3, not 2" {
  run "$REPO/bin/netdiag" --monitor --monitor-fast-interval abc
  [ "$status" -eq 3 ]
  [[ "$output" == *"whole number of seconds"* ]]
}

@test "--monitor with a zero interval exits 3" {
  run "$REPO/bin/netdiag" --monitor --monitor-medium-interval 0
  [ "$status" -eq 3 ]
  [[ "$output" == *"at least 1 second"* ]]
}

@test "a monitor interval flag with no value exits 3" {
  run "$REPO/bin/netdiag" --monitor --monitor-slow-interval
  [ "$status" -eq 3 ]
  [[ "$output" == *"expects a value"* ]]
}

@test "the --monitor-*=VALUE form is accepted" {
  run "$REPO/bin/netdiag" --monitor --monitor-fast-interval=nope
  [ "$status" -eq 3 ]
  [[ "$output" == *"whole number of seconds"* ]]
}

@test "--monitor-count is validated too" {
  run "$REPO/bin/netdiag" --monitor --monitor-count -1
  [ "$status" -eq 3 ]
}

@test "--monitor and its interval flags are documented in --help" {
  run "$REPO/bin/netdiag" --help
  [ "$status" -eq 0 ]
  for flag in --monitor --monitor-fast-interval --monitor-medium-interval \
              --monitor-slow-interval --monitor-count; do
    [[ "$output" == *"$flag"* ]] || { echo "missing from --help: $flag"; return 1; }
  done
}

@test "--monitor writes nothing under the log directory" {
  # It runs for days. Anything it accumulates, it accumulates forever.
  run grep -n 'LOG=/dev/null' "$REPO/bin/netdiag"
  [ "$status" -eq 0 ]
  # Code lines only — the header comment names baseline.jsonl precisely to
  # say it is never written.
  run grep -cE '^[^#]*(baseline\.jsonl|LOG_DIR|>>[[:space:]]*"\$LOG)' "$REPO/lib/monitor.sh"
  [ "$output" -eq 0 ]
}

# ── Pause and resume ─────────────────────────────────────────────────────
# The one block here that spawns a real monitor, because the bug it guards
# was invisible to every static check and to every terminal experiment.
#
# The app pauses the monitor while a scan runs — a speed test saturates the
# link on purpose, so samples taken during one are fiction. The obvious
# mechanism, SIGSTOP from the parent, is actively unsafe: POSIX sends
# SIGHUP+SIGCONT to a process group that becomes newly orphaned while any
# member is stopped, and a stopped monitor still has live children (the
# 2 s gateway ping, with_timeout's killer subshells). The moment one exits,
# the group orphans and the SIGHUP kills it.
#
# Measured under the GUI: the monitor died 2.1 s into every pause — exactly
# one ping probe — and the app restarted it *during the scan the pause
# existed to protect*. It never reproduced from a terminal, because a
# controlling terminal keeps the group non-orphaned. That is precisely how
# it would have shipped.

# Start a monitor in the background and return its pid. `pgrep -f` is
# deliberately avoided: bats runs each test through a shell whose own
# command line contains the pattern, so pgrep matches the wrong process and
# the signal lands on the test runner.
start_monitor() {
  "$REPO/bin/netdiag" --monitor --monitor-fast-interval 2 \
    --monitor-medium-interval 3600 --monitor-slow-interval 3600 \
    > "$BATS_TEST_TMPDIR/stream.jsonl" 2>"$BATS_TEST_TMPDIR/stream.err" &
  printf '%s' "$!"
}

alive() { ps -o stat= -p "$1" >/dev/null 2>&1; }
samples() { wc -l < "$BATS_TEST_TMPDIR/stream.jsonl" | tr -d ' '; }

# Wait for a condition, up to $1 seconds. Returns 1 if it never held.
#
# Sleeping a fixed number of seconds and then asserting encodes the speed of
# the machine that wrote the test. A GitHub runner is slower than a laptop
# and its "gateway" is virtualised, so the first cycle — a real ping plus a
# DNS lookup — can take longer than the cadence it was given. Three tests
# here failed in CI for exactly that reason and passed locally every time.
# Polling keeps the assertion (it did happen) without the assumption (within
# n seconds on this hardware).
wait_until() {
  local timeout="$1"; shift
  local deadline=$(( SECONDS + timeout ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

have_samples() { [ "$(samples)" -ge "${1:-1}" ]; }
not_alive()    { ! alive "$1"; }

@test "SIGUSR1 suspends probing and SIGUSR2 resumes it" {
  local pid; pid="$(start_monitor)"
  wait_until 30 have_samples 1 || { echo "monitor produced no samples at all"; kill -9 "$pid"; return 1; }
  local before; before="$(samples)"

  kill -USR1 "$pid"
  sleep 6
  local paused; paused="$(samples)"
  # Still a fixed sleep, and it has to be: this asserts that samples *stop*,
  # and there is no event to wait for when the expected behaviour is
  # silence. The bound stays generous — at most one in-flight cycle plus the
  # pause marker, against the three more that 6 s at a 2 s cadence would
  # produce unpaused.
  [ $((paused - before)) -le 2 ]

  kill -USR2 "$pid"
  wait_until 30 have_samples $((paused + 1)) || { echo "monitor never resumed"; kill -9 "$pid"; return 1; }
  kill -TERM "$pid" 2>/dev/null || true
}

@test "a paused monitor stays alive rather than being killed by SIGHUP" {
  # The actual regression. Six seconds is three times the ping probe that
  # used to orphan the process group and take it down.
  local pid; pid="$(start_monitor)"
  sleep 4
  kill -USR1 "$pid"
  sleep 7
  alive "$pid" || { echo "monitor died while paused"; return 1; }
  kill -TERM "$pid" 2>/dev/null || true
}

@test "a paused monitor says so rather than going silently quiet" {
  local pid; pid="$(start_monitor)"
  sleep 4
  kill -USR1 "$pid"
  sleep 3
  run tail -1 "$BATS_TEST_TMPDIR/stream.jsonl"
  printf '%s' "$output" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]["paused"] is True'
  kill -TERM "$pid" 2>/dev/null || true
}

@test "SIGTERM stops the monitor promptly, paused or not" {
  # "Promptly" is bounded by the longest probe a cycle can be inside when
  # the signal lands, not by a number that felt right on a laptop.
  local pid; pid="$(start_monitor)"
  wait_until 30 have_samples 1 || { echo "monitor produced no samples at all"; kill -9 "$pid"; return 1; }
  kill -TERM "$pid"
  wait_until 15 not_alive "$pid" || { echo "monitor ignored SIGTERM"; kill -9 "$pid"; return 1; }

  pid="$(start_monitor)"
  wait_until 30 have_samples 1 || { echo "monitor produced no samples at all"; kill -9 "$pid"; return 1; }
  kill -USR1 "$pid"
  sleep 2
  kill -TERM "$pid"
  wait_until 15 not_alive "$pid" || { echo "paused monitor ignored SIGTERM"; kill -9 "$pid"; return 1; }
  return 0
}

@test "lib/monitor.sh traps the pause signals it documents" {
  run grep -cE '^[[:space:]]*trap _mon_on_(pause|resume) +USR[12]' "$REPO/lib/monitor.sh"
  [ "$output" -eq 2 ]
}

@test "the GUI pauses with SIGUSR1, never SIGSTOP" {
  # Structural guard on the fix. SIGSTOP against this process is a latent
  # kill that only manifests under a GUI parent.
  local gui="$REPO/gui/Sources/NetdiagGUI/Services/MonitorStream.swift"
  [ -f "$gui" ] || skip "GUI sources not present"
  run grep -nE '^[^/]*kill\(process\.processIdentifier, SIG(STOP|CONT)\)' "$gui"
  [ "$status" -ne 0 ] || { echo "GUI still uses SIGSTOP/SIGCONT:"; echo "$output"; return 1; }
  run grep -c 'SIGUSR1' "$gui"
  [ "$output" -ge 1 ]
}

# ── Orphan cleanup ───────────────────────────────────────────────────────
# A stream exists for a consumer. A network probe still running with no
# reader is the single most likely reason an always-on tool gets
# uninstalled, and it is invisible — nothing in the UI can show a process
# the app no longer knows about.
#
# Taking EPIPE on a closed stdout is not enough on its own: measured,
# SIGKILL of the GUI left the monitor probing 30 s later, because a pipe fd
# survives in ways the child cannot audit. So the parent is checked
# explicitly, with `kill -0` rather than $PPID — bash captures PPID once at
# startup and still reports a dead pid after re-parenting to launchd.

@test "the monitor exits when the process that started it dies" {
  # An intermediate shell stands in for the app: it spawns the monitor,
  # then is killed outright, exactly as a force-quit or a crash would be.
  local out="$BATS_TEST_TMPDIR/pid"
  bash -c "'$REPO/bin/netdiag' --monitor --monitor-fast-interval 2 \
             >/dev/null 2>&1 & echo \$! > '$out'; sleep 60" &
  local shell_pid=$!
  sleep 4
  local mon_pid; mon_pid="$(cat "$out")"
  ps -o stat= -p "$mon_pid" >/dev/null 2>&1 || { echo "monitor never started"; return 1; }

  kill -9 "$shell_pid" 2>/dev/null
  # One cadence plus one in-flight probe is the honest bound.
  local i
  for i in $(seq 1 20); do
    ps -o stat= -p "$mon_pid" >/dev/null 2>&1 || return 0
    sleep 1
  done
  kill -9 "$mon_pid" 2>/dev/null
  echo "orphaned monitor was still running 20 s after its parent died"
  return 1
}

@test "the parent check uses kill -0, not a re-read of PPID" {
  # bash sets PPID once at startup and never updates it, so comparing it
  # against itself would silently never fire — the guard would look
  # present and do nothing.
  run grep -cE 'kill -0 "\$parent_pid"' "$REPO/lib/monitor.sh"
  [ "$output" -eq 1 ]
}
