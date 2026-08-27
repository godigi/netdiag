# shellcheck shell=bash
# lib/monitor.sh — `netdiag --monitor`: a long-lived process that emits one
# compact JSON object per line on stdout, flushed per sample.
#
# This is the machine-readable sibling of --watch. --watch re-runs --quick
# on an interval and prints prose for a human watching a terminal;
# --monitor never prints prose, never writes a log, never touches
# baseline.jsonl, and emits a deliberately *smaller* shape than a full run
# (documented in docs/JSON-SCHEMA.md). The menu-bar app consumes it; a
# person would not enjoy reading it.
#
# Reads:  MONITOR_* interval flags set by bin/netdiag's argparse
# Entry:  monitor_run (loops until SIGINT/SIGTERM or stdout closes)
#
# ── Three cadence tiers ────────────────────────────────────────────────
# Probing everything on the fastest interval would be both rude to the
# network and pointless: a public-IP lookup answers a question that
# changes hourly, a gateway ping one that changes second to second.
#
#   fast   gateway ping, VPN state, link/SSID     10 s (5 s when degraded)
#   medium DNS resolve, TCP/443, RSSI/SNR         60 s
#   slow   public IP, ISP, ASN, country, portal   300 s + on network change
#
# The slow tier is the only one making an external call, so it is the only
# one where rate-limit politeness is at stake — hence 300 s, and hence the
# network-change trigger, because a changed public IP is the one thing
# worth knowing immediately after joining somewhere new.
#
# ── The monitor computes rules, not verdicts ───────────────────────────
# Each sample carries status.rules: the IDs from docs/DIAGNOSIS-RULES.md
# that *would* fire on this sample, evaluated here in bash against
# lib/thresholds.sh — the same constants lib/diagnosis.sh reads. The GUI
# renders that list and never re-derives a threshold. If the two ever
# disagree about what "lossy" means, the app contradicts the report it
# links to and the user has no way to tell which lied.
#
# ── Power is the GUI's problem, but pausing is ours ────────────────────
# The monitor stays dumb about sleep and battery: NSWorkspace delivers
# those events to the app for free, where bash would have to poll pmset.
# The app decides *when* to pause; this file implements *how*.
#
#   SIGUSR1  pause  — stop probing, keep the process alive
#   SIGUSR2  resume
#   SIGTERM / SIGINT  exit cleanly
#
# Pausing is a signal handler here rather than SIGSTOP from the caller,
# and that is not a stylistic choice — SIGSTOP is actively unsafe for this
# process. POSIX says that when a process group becomes newly orphaned and
# any member of it is stopped, the kernel delivers SIGHUP followed by
# SIGCONT to the whole group. A SIGSTOPped monitor still has children (the
# two-second gateway ping, the with_timeout killer subshells); the instant
# one of them exits, the group orphans, the SIGHUP lands, and the monitor
# dies. Measured: it survived about 2.1 s of every SIGSTOP under a GUI
# parent, exactly the length of one ping probe. It never happened under a
# shell, because a controlling terminal keeps the group non-orphaned —
# which is precisely why the bug would have shipped.
#
# Handling it in-process also makes the pause testable, and lets a paused
# monitor say so rather than going mysteriously silent.
#
# The one thing it manages by itself is a dead link: with no default route
# there is nothing to probe, so it stops probing and emits a minimal N1
# sample at the fast cadence. It deliberately does *not* exit — a stream
# that dies at the instant WiFi drops cannot report that WiFi dropped,
# which is the single event the app exists to announce.
#
# ── It exits when whoever started it goes away ─────────────────────────
# A stream exists for a consumer. If the consumer is gone there is nobody
# to stream to, and a network probe running forever with no reader is the
# single most likely reason an always-on tool gets uninstalled.
#
# The obvious mechanism — writing to a closed pipe and taking the EPIPE —
# is not sufficient on its own. Measured: SIGKILL the GUI and the monitor
# was still probing 30 s later, because a pipe fd survives in ways this
# process cannot audit. So the parent is checked explicitly each cycle.
#
# `kill -0` rather than re-reading $PPID: bash captures PPID once at
# startup and never updates it, so after re-parenting to launchd it still
# reports the pid of a process that no longer exists. `kill -0` is a
# builtin, costs nothing, and flips the moment the parent is reaped.

# The WiFi scrapes are shared with the scanner; one parser per upstream
# format means a macOS release that moves a label is fixed once.
# shellcheck source=lib/wifi_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/wifi_common.sh"

# ── Sample state ─────────────────────────────────────────────────────────
# All MON_* — a distinct namespace from the scanner's globals so that
# sourcing both (as bin/netdiag does) can't have one silently read the
# other's value.
MON_SEQ=0
MON_INTERFACE=""
MON_IFACE_TYPE=""
MON_LINK_UP=0
MON_GATEWAY=""
MON_GW_MAC=""
MON_SSID=""
MON_BSSID=""
MON_LOCAL_IP=""
MON_NETWORK_ID=""
MON_NETWORK_LABEL=""
MON_NETWORK_GROUP=""
MON_VPN_ACTIVE=0
MON_VPN_TYPE=""
MON_VPN_NAME=""
MON_GW_LOSS=""
MON_GW_RTT=""
# How many consecutive cycles the warn-band loss condition has held for
# each leg — gateway and internet — used to confirm G3/L2 before either
# fires (see THRESH_MON_LOSS_CONFIRM_CYCLES in lib/thresholds.sh). Declared
# here, not just assigned inside _mon_rules, because bin/netdiag runs under
# `set -u` and the very first cycle reads them before ever writing them.
MON_GW_LOSS_STREAK=0
MON_INET_LOSS_STREAK=0
# Rolling loss windows, one per leg: newest-last "sent:lost" pairs, one per
# completed probe, trimmed to MONITOR_LOSS_WINDOW_PROBES entries. Plain
# space-separated scalars rather than arrays — this file must run under
# zsh AND bash, and array syntax (and even subscript origin) differs
# between them. The reported MON_GW_LOSS / MON_INET_LOSS are computed over
# the whole window, which is what makes the percentage a property of the
# link rather than of one burst; see _mon_loss_summarize.
MON_GW_HIST=""
MON_INET_HIST=""
MON_INET_HIST_ALT=""
MON_INET_LOSS_ALT=""
MON_WIFI_RSSI=""
MON_WIFI_NOISE=""
MON_WIFI_SNR=""
MON_WIFI_CHAN=""
MON_DNS_OK=""
MON_DNS_RESOLVER=""
MON_DNS_MS=""
MON_TCP_OK=""
MON_TCP_LINES=""
# A small HTTPS reachability probe runs with the fast tier. It answers the
# question users actually care about — whether ordinary internet traffic can
# leave the Mac — rather than treating Wi-Fi association or ICMP replies as
# proof that websites will load.
MON_WEB_OK=""
MON_PUB_IP=""
MON_PUB_ISP=""
MON_PUB_ASN=""
MON_PUB_CC=""
MON_PUB_CC_ISO=""
MON_PUB_CITY=""
MON_PUBLIC_OK=""
MON_CAPTIVE=""
MON_RULES=""
MON_SEVERITY="ok"
# `ok` severity means no diagnosis rule fired. It does not mean the probes
# succeeded; keep measurement availability separate so the GUI can avoid a
# green "all good" card when the link could not be tested.
MON_MEASUREMENT_STATE="unknown"
MON_ICMP_FILTERED=0
MON_DEGRADED=0
MON_REFRESHED=""
MON_STOP=0
MON_PAUSED=0
MON_REFRESH_REQUESTED=0
MON_HW_PORTS=""
# launchd's pid. Named rather than written as a bare 1 so the orphan check
# below reads as the sentinel it is, and so tests/test_thresholds.bats's
# "no inline cutoff" guard stays a useful signal instead of something this
# file has to be excused from.
MON_INIT_PID=1

# Previous-sample identity, for the schema-2 changes array. Snapshotted
# by _mon_snapshot_prev after every successful emit; MON_HAVE_PREV=0
# suppresses a spurious "everything changed" on the first sample.
MON_HAVE_PREV=0
MON_PREV_PUB_IP=""
MON_PREV_PUB_CC=""
MON_PREV_PUB_ISP=""
MON_PREV_VPN_ACTIVE=""
MON_PREV_VPN_NAME=""
MON_PREV_SSID=""
MON_PREV_BSSID=""
# The wall-clock second the previous cycle began, and the cadence it was
# scheduled at — the two inputs _mon_gap_seconds compares.
MON_PREV_CYCLE_TS=""
MON_PREV_CADENCE=""
MON_GAP_S=""
MON_PREV_INTERFACE=""
MON_PREV_RULES=""

# ── Fast tier ────────────────────────────────────────────────────────────

# One `route -n get default` for both fields: it is a syscall to the
# routing table, but two of them per sample forever adds up and they can
# disagree if the route changes between the calls.
_mon_probe_link() {
  local route_out
  route_out="$(route -n get default 2>/dev/null || true)"
  MON_INTERFACE="$(printf '%s\n' "$route_out" | awk '/interface:/{print $2; exit}')"
  MON_GATEWAY="$(printf '%s\n' "$route_out"  | awk '/gateway:/{print $2; exit}')"
  if [ -n "$MON_INTERFACE" ] && [ -n "$MON_GATEWAY" ]; then
    MON_LINK_UP=1
  else
    MON_LINK_UP=0
  fi
  MON_LOCAL_IP=""
  [ -n "$MON_INTERFACE" ] && MON_LOCAL_IP="$(ipconfig getifaddr "$MON_INTERFACE" 2>/dev/null || true)"

  # Hardware-port list is static for the life of the machine, so read it
  # once. networksetup is ~100 ms — affordable at startup, not every 10 s.
  if [ -z "$MON_HW_PORTS" ]; then
    MON_HW_PORTS="$(networksetup -listallhardwareports 2>/dev/null || true)"
  fi
  MON_IFACE_TYPE="wired"
  MON_SSID=""; MON_BSSID=""
  if [ -n "$MON_INTERFACE" ]; then
    local hw_port ssid bssid
    hw_port="$(wifi_hw_port_for_device "$MON_INTERFACE" "$MON_HW_PORTS")"
    if wifi_port_is_wireless "$hw_port"; then
      MON_IFACE_TYPE="wifi"
      local summary
      summary="$(ipconfig getsummary "$MON_INTERFACE" 2>/dev/null || true)"
      {
        IFS=$'\t' read -r ssid bssid _
      } <<<"$(wifi_parse_ipconfig_summary "$summary")"
      MON_SSID="$ssid"
      MON_BSSID="$bssid"
    fi
  fi

  # Gateway MAC from the ARP cache — a local table read, no packets. This
  # is the strongest identity a network has and the thing "you're not on
  # the network you think you are" keys off.
  MON_GW_MAC=""
  if [ -n "$MON_GATEWAY" ]; then
    MON_GW_MAC="$(arp -n "$MON_GATEWAY" 2>/dev/null \
      | awk '/ at /{ if ($4 != "(incomplete)") print $4; exit }')"
  fi
  _mon_identity
}

# Reuse lib/netid.sh rather than reimplementing precedence. Identity has to
# be byte-identical to what a scan records or the app cannot join a live
# sample to the history it charts.
_mon_identity() {
  # netid_run reads these four by name and writes the three below. They look
  # unused to shellcheck because the read happens in another file through
  # dynamic scope, which is exactly the point: the precedence logic stays
  # in one place.
  # shellcheck disable=SC2034
  local IS_WIFI=0 WIFI_SSID="$MON_SSID" GW_MAC="$MON_GW_MAC" GATEWAY="$MON_GATEWAY"
  local NETWORK_ID="" NETWORK_LABEL="" NETWORK_GROUP=""
  # shellcheck disable=SC2034
  [ "$MON_IFACE_TYPE" = "wifi" ] && IS_WIFI=1
  netid_run
  MON_NETWORK_ID="$NETWORK_ID"
  MON_NETWORK_LABEL="$NETWORK_LABEL"
  # The history group key, not the raw record id — this is the id the
  # app joins against --history's networks with. See netid.sh.
  MON_NETWORK_GROUP="$NETWORK_GROUP"
}

_mon_probe_vpn() {
  # Reuse the scan's detector, including Tailscale. Dynamic locals keep the
  # shared function from mutating scanner globals in the monitor process.
  # shellcheck disable=SC2034
  local INTERFACE="$MON_INTERFACE" VPN_ACTIVE=0 VPN_TYPE="" VPN_NAME=""
  vpn_detect
  MON_VPN_ACTIVE="$VPN_ACTIVE"
  MON_VPN_TYPE="$VPN_TYPE"
  MON_VPN_NAME="$VPN_NAME"
}

# ── Rolling loss window ──────────────────────────────────────────────────
# A loss percentage is only as fine as its denominator: at 20 packets per
# probe one dropped packet reads 5%, at 10 it reads 10%, and either way the
# instrument swings on a single packet and back — movement of the probe,
# not of the network. So the reported figure is accumulated across probes:
# each leg keeps its last MONITOR_LOSS_WINDOW_PROBES results and reports
# lost×100÷sent over the whole window. At the defaults that is five
# 20-packet probes — a 100-packet denominator, 1% quantum — refreshed
# every fast cycle, so real loss ramps smoothly toward the thresholds and
# routine noise contributes a fraction of a percent that then decays out.
#
# Counts, not percentages, are what accumulate: averaging ratios weights a
# short run equally with a long one. The probes send fixed counts today,
# but the arithmetic stays honest if that ever changes.

# Fold one probe's "sent:lost" into a history string and summarise it:
# prints "<trimmed history>|<total sent>|<total lost>", keeping only the
# newest MONITOR_LOSS_WINDOW_PROBES entries. Pure: no globals read or
# written, so both legs share it and tests can drive it directly.
_mon_loss_summarize() {
  printf '%s' "$1" | awk -v k="$MONITOR_LOSS_WINDOW_PROBES" '
    { n = split($0, f, / /); start = n - k + 1; if (start < 1) start = 1;
      ts = ""; s = 0; l = 0;
      for (i = start; i <= n; i++) {
        split(f[i], p, /:/); s += p[1]; l += p[2];
        ts = (ts == "" ? "" : ts " ") f[i]
      }
      print ts "|" s "|" l }'
}

# Report a leg's windowed loss percentage from its totals. Kept separate
# so the rounding rule lives in exactly one place.
_mon_loss_pct() {
  awk -v s="$1" -v l="$2" 'BEGIN { if (s > 0) printf "%.0f", l * 100 / s }'
}

# Clear both windows: a dead link or a different network invalidates every
# reading in them. Stale packets from before the change would dilute a
# fresh problem; a window half full of the old network is measuring
# neither network.
_mon_loss_reset() {
  MON_GW_HIST=""
  MON_INET_HIST=""
  MON_INET_HIST_ALT=""
}

# Parse ping's -q summary into raw counts, fold it into a leg's history,
# and report the windowed percentage. Pure: takes the current history
# string, prints "<new history>|<loss pct>", and prints "|"" on a probe
# that produced no parseable summary — clearing the window rather than
# leaving it frozen, because "could not measure" must not read as
# "measured, clean", and a window reporting last cycle's answer forever is
# the stale-data bug this file has already been burned by once.
# Args: history string, ping output, expected sent count.
_mon_loss_fold() {
  local hist="$1" out="$2" expect="$3"
  local sent recv summary totals sent_t lost_t
  # Fields carry trailing commas ("20 packets transmitted, 20 packets
  # received, …"), so the keyword is matched as a prefix, not exactly, and
  # the count sits two fields before it ("20" "packets" "transmitted,").
  sent="$(printf '%s\n' "$out" | awk '/packets transmitted/{for(i=1;i<=NF;i++)if($i ~ /^transmitted/){print $(i-2); exit}}')"
  recv="$(printf '%s\n' "$out" | awk '/packets transmitted/{for(i=1;i<=NF;i++)if($i ~ /^received/){print $(i-2); exit}}')"
  case "$sent" in ''|*[!0-9]*) sent="" ;; esac
  case "$recv" in ''|*[!0-9]*) recv="" ;; esac
  if [ -z "$sent" ] || [ -z "$recv" ] || [ "$recv" -gt "$sent" ] \
     || [ "$sent" -ne "$expect" ]; then
    printf '|'
    return 0
  fi
  summary="$(_mon_loss_summarize "${hist:+$hist }${sent}:$((sent - recv))")"
  totals="${summary#*|}"
  sent_t="${totals%%|*}"
  lost_t="${totals##*|}"
  printf '%s|%s' "${summary%%|*}" "$(_mon_loss_pct "$sent_t" "$lost_t")"
}

_mon_probe_gateway() {
  MON_GW_LOSS=""; MON_GW_RTT=""
  [ -n "$MON_GATEWAY" ] || return 0
  local out summary
  # -q: summary only. The scanner keeps the per-packet lines because it
  # logs them; nothing here reads them.
  #
  # MONITOR_PING_COUNT is 10, not the 3 or 5 a "quick liveness check"
  # suggests, and the reason is quantisation rather than accuracy. At 3
  # packets the only reportable losses are 0/33/67/100%, so one dropped
  # packet reads as 33% — comfortably past the 20% critical floor. At 5 it
  # reads as exactly 20%, which still trips it. Per-probe quantisation no
  # longer decides anything by itself — the reported figure accumulates
  # over the rolling window (_mon_loss_fold) — but a wider burst still
  # fills the window faster and costs little at 0.2 s spacing. Cost is 2 s
  # of a 10 s cycle, at one packet per second average.
  #
  # -W bounds the wait for the last reply; without it macOS ping sits ~10 s
  # past the final packet before printing statistics, and with_timeout 6
  # killed it first. The statistics line is the measurement, so losing it
  # meant a dead gateway reported "not measured" rather than 100% loss.
  # See PING_REPLY_WAIT_MS in lib/thresholds.sh.
  out="$(with_timeout 6 ping -q -c "$MONITOR_PING_COUNT" -i "$MONITOR_PING_INTERVAL" \
    -W "$PING_REPLY_WAIT_MS" "$MON_GATEWAY" 2>/dev/null || true)"
  summary="$(_mon_loss_fold "$MON_GW_HIST" "$out" "$MONITOR_PING_COUNT")"
  MON_GW_HIST="${summary%%|*}"
  MON_GW_LOSS="${summary#*|}"
  MON_GW_RTT="$(ping_parse_summary "$out" | cut -d'|' -f2)"
  is_numeric "$MON_GW_RTT"  || MON_GW_RTT=""
}

# ── Medium tier ──────────────────────────────────────────────────────────

_mon_probe_dns() {
  MON_DNS_OK=""; MON_DNS_RESOLVER=""; MON_DNS_MS=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  MON_DNS_RESOLVER="$(scutil --dns 2>/dev/null \
    | awk '/nameserver\[0\]/{print $3; exit}')"
  [ -n "$MON_DNS_RESOLVER" ] || return 0
  local t0 answer
  t0="$EPOCHREALTIME"
  answer="$(with_timeout 3 dig +time=2 +tries=1 +short @"$MON_DNS_RESOLVER" cloudflare.com 2>/dev/null | head -1)"
  MON_DNS_MS="$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.0f", (b-a)*1000}')"
  if [ -n "$answer" ]; then MON_DNS_OK=1; else MON_DNS_OK=0; fi
}

_mon_probe_tcp() {
  MON_TCP_OK=""; MON_TCP_LINES=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  # TCP-1 exists because hotel and corporate networks block ICMP wholesale.
  # Without a TCP probe alongside the ping, a monitor on such a network
  # reports 100% loss forever and every loss alert it can raise is a false
  # one. Two independent targets so a single unreachable host doesn't read
  # as "the internet is gone".
  local entry host port t0 ms any=0
  for entry in "1.1.1.1:443" "8.8.8.8:443"; do
    host="${entry%:*}"; port="${entry##*:}"
    t0="$EPOCHREALTIME"
    if with_timeout 4 nc -G 3 -z "$host" "$port" >/dev/null 2>&1; then
      ms="$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.0f", (b-a)*1000}')"
      MON_TCP_LINES+="${host}|${port}|1|${ms}"$'\n'
      any=1
    else
      MON_TCP_LINES+="${host}|${port}|0|"$'\n'
    fi
  done
  MON_TCP_OK="$any"
}

_mon_probe_internet() {
  MON_INET_LOSS=""; MON_INET_LOSS_ALT=""; MON_INET_RTT=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  local out out_alt summary summary_alt tmp_dir target target_alt
  target="${INET_TARGET:-1.1.1.1}"
  target_alt="${INET_TARGET_ALT:-8.8.8.8}"
  # MONITOR_INET_PING_COUNT, not a token burst: at five packets one dropped
  # packet reads as exactly LOSS_CRIT_PCT, so a single routine drop at a
  # rate-limiting resolver fired L1 as an immediate critical — the red card
  # flashed for one cycle and cleared on the next. Twenty packets is the
  # scanner's own count; see lib/thresholds.sh. The reported figure is the
  # rolling window over the last MONITOR_LOSS_WINDOW_PROBES probes
  # (_mon_loss_fold), so the percentage's denominator is ~100 packets and
  # one drop moves it one point, not twenty. The two independent targets run
  # concurrently, matching internet_ping.sh's scanner path; L1 is allowed
  # only when both windows agree.
  netdiag_mktemp_dir monitor-inet || return 0
  tmp_dir="$NETDIAG_TMP_DIR"
  # -W for the same reason as the gateway probe above: 20 packets at 0.2 s
  # is 4 s of sending, and macOS ping's ~10 s tail wait put the statistics
  # line outside with_timeout 8 on exactly the dead paths it describes.
  with_timeout 8 ping -q -c "$MONITOR_INET_PING_COUNT" -i "$LOSS_PROBE_INTERVAL" \
    -W "$PING_REPLY_WAIT_MS" "$target" >"$tmp_dir/primary" 2>/dev/null &
  local pid_a=$!
  with_timeout 8 ping -q -c "$MONITOR_INET_PING_COUNT" -i "$LOSS_PROBE_INTERVAL" \
    -W "$PING_REPLY_WAIT_MS" "$target_alt" >"$tmp_dir/alternate" 2>/dev/null &
  local pid_b=$!
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true
  out="$(cat "$tmp_dir/primary" 2>/dev/null || true)"
  out_alt="$(cat "$tmp_dir/alternate" 2>/dev/null || true)"
  rm -rf "$tmp_dir"
  netdiag_tmp_forget "$tmp_dir"
  summary="$(_mon_loss_fold "$MON_INET_HIST" "$out" "$MONITOR_INET_PING_COUNT")"
  MON_INET_HIST="${summary%%|*}"
  MON_INET_LOSS="${summary#*|}"
  summary_alt="$(_mon_loss_fold "$MON_INET_HIST_ALT" "$out_alt" "$MONITOR_INET_PING_COUNT")"
  MON_INET_HIST_ALT="${summary_alt%%|*}"
  MON_INET_LOSS_ALT="${summary_alt#*|}"
  MON_INET_RTT="$(ping_parse_summary "$out" | cut -d'|' -f2)"
  is_numeric "$MON_INET_RTT"  || MON_INET_RTT=""
}

# Probe normal HTTPS traffic, not just Wi-Fi association or ICMP. A Mac can
# remain associated at full RSSI while a wall/interference makes data traffic
# unusable. Two independent 204 canaries keep one blocked endpoint from
# becoming an ISP verdict; a captive portal normally returns a redirect or a
# 200 page instead of the expected 204 and is therefore not counted as web
# reachability.
_mon_probe_web() {
  MON_WEB_OK=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local tmp_dir code_a code_b
  netdiag_mktemp_dir monitor-web || return 0
  tmp_dir="$NETDIAG_TMP_DIR"
  curl -4 -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 1 --max-time 2 \
    https://cp.cloudflare.com/generate_204 >"$tmp_dir/cloudflare" 2>/dev/null &
  local pid_a=$!
  curl -4 -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 1 --max-time 2 \
    https://www.gstatic.com/generate_204 >"$tmp_dir/google" 2>/dev/null &
  local pid_b=$!
  wait "$pid_a" 2>/dev/null || true
  wait "$pid_b" 2>/dev/null || true

  code_a="$(cat "$tmp_dir/cloudflare" 2>/dev/null || true)"
  code_b="$(cat "$tmp_dir/google" 2>/dev/null || true)"
  rm -rf "$tmp_dir"
  netdiag_tmp_forget "$tmp_dir"

  MON_WEB_OK="$(_mon_web_verdict "$code_a" "$code_b")"
}

# Turn two canary status codes into a reachability verdict: "1" reachable,
# "0" answered but intercepted, "" nothing answered. Pure, so the three-way
# distinction is testable without a network.
#
# 000 is curl's code for a request that never completed — DNS failure,
# refused connection, timeout. It is the *absence* of an answer, and reading
# it as one is what let a dead link report as a captive portal and, worse,
# satisfy the "measurement" gate: the app's own "checking" card then could
# not appear on the outage it was written for. A real portal answers with a
# redirect or a login page, which is a genuine response and still reads 0.
_mon_web_verdict() {
  local a="$1" b="$2"
  [ "$a" = "000" ] && a=""
  [ "$b" = "000" ] && b=""
  if [ "$a" = "204" ] || [ "$b" = "204" ]; then
    printf '1'
  elif [ -n "$a" ] || [ -n "$b" ]; then
    printf '0'
  fi
}

_mon_probe_wifi_signal() {
  MON_WIFI_RSSI=""; MON_WIFI_NOISE=""; MON_WIFI_SNR=""; MON_WIFI_CHAN=""
  [ "$MON_IFACE_TYPE" = "wifi" ] || return 0
  # wdutil needs root. The GUI runs unprivileged, so in practice these stay
  # null and W1/W2 never fire from the monitor — which is correct: a null
  # RSSI is "not measured", and inventing one would be worse than the
  # missing alert. `sudo -n` never prompts.
  sudo -n true 2>/dev/null || return 0
  local out rssi noise
  out="$(with_timeout 4 sudo -n wdutil info 2>/dev/null || true)"
  [ -n "$out" ] || return 0
  {
    # Fields 1-3 only; the parser's SSID/BSSID tail is scanner policy.
    IFS=$'\t' read -r rssi noise MON_WIFI_CHAN _
  } <<<"$(wifi_parse_wdutil "$out")"
  is_numeric "$rssi"  || rssi=""
  is_numeric "$noise" || noise=""
  MON_WIFI_RSSI="$rssi"
  MON_WIFI_NOISE="$noise"
  if [ -n "$rssi" ] && [ -n "$noise" ]; then
    MON_WIFI_SNR=$((rssi - noise))
  fi
}

# ── Slow tier ────────────────────────────────────────────────────────────

_mon_probe_public() {
  MON_PUBLIC_OK=""; MON_CAPTIVE=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  local out
  out="$(curl -4 -s -m 4 https://ifconfig.co/json 2>/dev/null || curl -s -m 4 https://ifconfig.co/json 2>/dev/null || true)"
  if [ -n "$out" ]; then
    MON_PUBLIC_OK=1
    MON_PUB_IP="$(printf   '%s' "$out" | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p')"
    MON_PUB_ISP="$(printf  '%s' "$out" | sed -n 's/.*"asn_org": *"\([^"]*\)".*/\1/p')"
    MON_PUB_ASN="$(printf  '%s' "$out" | sed -n 's/.*"asn": *"\([^"]*\)".*/\1/p')"
    MON_PUB_CITY="$(printf '%s' "$out" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p')"
    MON_PUB_CC="$(printf   '%s' "$out" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p')"
    MON_PUB_CC_ISO="$(printf '%s' "$out" | sed -n 's/.*"country_iso": *"\([^"]*\)".*/\1/p')"
  else
    MON_PUBLIC_OK=0
  fi
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
}

# ── Rule evaluation ──────────────────────────────────────────────────────
# A deliberately partial mirror of lib/diagnosis.sh: only the rules whose
# inputs a between-scans probe actually measures. NT-1, DI-*, DH-1 and BL-1
# are scan-only and are never claimed here — the app triggers a real scan
# for those rather than have the monitor guess.
#
# Every cutoff comes from lib/thresholds.sh. Nothing in this function may
# contain a numeric literal.

_mon_add_rule() {
  local sev="$1" rule="$2"
  MON_RULES+="${rule} "
  case "$sev" in
    critical) MON_SEVERITY="critical" ;;
    warn)     [ "$MON_SEVERITY" = "critical" ] || MON_SEVERITY="warn" ;;
    info)     case "$MON_SEVERITY" in ok) MON_SEVERITY="info" ;; esac ;;
  esac
  return 0
}

_mon_rules() {
  MON_RULES=""
  MON_SEVERITY="ok"
  MON_ICMP_FILTERED=0
  MON_MEASUREMENT_STATE="unknown"

  if [ "$MON_LINK_UP" -eq 0 ]; then
    _mon_add_rule critical N1
    MON_DEGRADED=1
    MON_MEASUREMENT_STATE="link-down"
    MON_WEB_OK=""
    # No link means neither leg was probed this cycle — a streak the link
    # drop interrupted is not a streak that held.
    MON_GW_LOSS_STREAK=0
    MON_INET_LOSS_STREAK=0
    return 0
  fi

  # This is data availability, not a health verdict. A healthy RSSI is not
  # evidence that traffic is usable, and an empty ping summary is not
  # evidence of zero loss. The state is emitted separately from severity so
  # the GUI can say "checking" instead of claiming that everything is good.
  #
  # A loss figure is non-empty only when _mon_loss_fold parsed a complete
  # transmitted/received pair, so 100 counts here exactly as 0 does: both
  # are answers. What does not count is a probe that produced nothing —
  # including MON_WEB_OK, which is now empty rather than 0 when curl's
  # request never completed (see _mon_web_verdict).
  if [ -n "$MON_GW_LOSS" ] || [ -n "$MON_INET_LOSS" ] || [ -n "$MON_WEB_OK" ]; then
    MON_MEASUREMENT_STATE="measured"
  fi

  # Prefer the fast HTTPS reachability result when it has run. Fall back to
  # the slower public probe for compatibility with the first sample and with
  # older test/CLI inputs that do not provide MON_WEB_OK.
  local _mon_public_ok="${MON_WEB_OK:-$MON_PUBLIC_OK}"

  # Is the gateway's ping loss filtering rather than fault? Decided before
  # the loss rules below because it decides whether they run at all, and
  # evaluated identically in lib/diagnosis.sh — the two engines must name
  # the same rules for the same link (tests/test_monitor.bats's parity
  # block) or the app shows a green dot over a red report.
  #
  # An earlier version of this block let G1/G2/G3 fire anyway and left the
  # alert engine to decline the notification. That kept the user from being
  # *pinged*, but the report still printed "reboot your router (unplug it
  # for 30 seconds)" directly above "the network is up; don't worry about
  # the ping numbers above", let the critical one own the headline, and
  # exited 2 on every hotel and corporate network. TCP reaching 1.1.1.1:443
  # means packets are crossing the gateway, so the gateway is forwarding and
  # merely declining to answer pings itself; TCP-1's own prose still quotes
  # the loss figure, so suppressing the contradiction loses no number.
  local _mon_gw_filtered=0
  if [ "${MON_TCP_OK:-0}" = "1" ] \
     && loss_at_least "$MON_GW_LOSS" "$THRESH_ICMP_FILTERED_LOSS_PCT"; then
    _mon_gw_filtered=1
    MON_ICMP_FILTERED=1
    _mon_add_rule info TCP-1
  fi

  # G1/G2/G3, evaluated exactly as lib/diagnosis.sh evaluates them.
  # G3 is confirmed rather than immediate: a single cycle's loss is a blip
  # (see THRESH_MON_LOSS_CONFIRM_CYCLES), so the warn band only fires once
  # it has held for THRESH_MON_LOSS_CONFIRM_CYCLES consecutive cycles.
  # Critical never waits — a real outage must not sit behind a confirmation
  # window — and any cycle that is not in the warn band (clean, or escalated
  # to critical) resets the streak, so a one-off blip followed by a clean
  # cycle can never quietly accumulate toward firing later.
  if [ "$_mon_gw_filtered" -eq 1 ]; then
    # TCP-1 already described this link. Reset both streaks: filtered cycles
    # are not evidence toward a confirmed G3.
    MON_GW_LOSS_STREAK=0
  elif loss_at_least "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    MON_GW_LOSS_STREAK=0
    if [ -n "$MON_WIFI_RSSI" ] && is_numeric "$MON_WIFI_RSSI" && [ "$MON_WIFI_RSSI" -le "$THRESH_WIFI_RSSI_G1_DBM" ]; then
      _mon_add_rule critical G1
    else
      _mon_add_rule critical G2
    fi
  elif loss_at_least "$MON_GW_LOSS" "$LOSS_WARN_PCT"; then
    MON_GW_LOSS_STREAK=$((MON_GW_LOSS_STREAK + 1))
    if [ "$MON_GW_LOSS_STREAK" -ge "$THRESH_MON_LOSS_CONFIRM_CYCLES" ]; then
      _mon_add_rule warn G3
    fi
  else
    MON_GW_LOSS_STREAK=0
  fi

  # P1/P2 need a current public reach result. The fast HTTPS canary is
  # authoritative once it has run; the slower public-IP probe remains the
  # compatibility fallback. An unmeasured value is "" and must not read as
  # an outage — the same distinction that JSON-SCHEMA.md draws between null
  # and 0.
  # Mirrors lib/diagnosis.sh: CP-1 owns the portal case on both sides, or
  # the stream and the report disagree about what to tell the user.
  if [ "$_mon_public_ok" = "0" ] && [ "${MON_CAPTIVE:-}" != "1" ] \
     && loss_below "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    if [ "${MON_DNS_OK:-}" = "0" ]; then
      _mon_add_rule critical P1
    else
      _mon_add_rule critical P2
    fi
  fi

  # D1 — resolution failing while the internet itself is reachable.
  if [ "${MON_DNS_OK:-}" = "0" ] && [ "$_mon_public_ok" = "1" ]; then
    _mon_add_rule warn D1
  fi

  if [ "${MON_CAPTIVE:-}" = "1" ]; then
    _mon_add_rule warn CP-1
  fi

  if [ "$MON_VPN_ACTIVE" -eq 1 ]; then
    _mon_add_rule info VPN-1
  fi

  # TCP-1 is decided above the gateway loss rules, because it decides
  # whether they fire at all.

  # ── L1 / L2 — internet-side packet loss ────────────────────────────────
  local _mon_icmp_filtered=0
  if [ "$_mon_public_ok" = "1" ] && [ "${MON_TCP_OK:-0}" = "1" ] \
     && loss_at_least "$MON_INET_LOSS" "$THRESH_ICMP_TOTAL_LOSS_PCT" \
     && loss_at_least "$MON_INET_LOSS_ALT" "$THRESH_ICMP_TOTAL_LOSS_PCT"; then
    _mon_icmp_filtered=1
    _mon_add_rule info ICMP-1
  fi

  # L2 is confirmed the same way G3 is, and for the same reason; L1 stays
  # immediate. Falling out of the gateway-is-quiet guard above also resets
  # the streak — a cycle where the condition could not even be evaluated is
  # not a cycle where it held.
  if [ "$_mon_icmp_filtered" -eq 0 ] && loss_below "$MON_GW_LOSS" "$LOSS_WARN_PCT"; then
    if loss_at_least "$MON_INET_LOSS" "$LOSS_CRIT_PCT" \
       && loss_at_least "$MON_INET_LOSS_ALT" "$LOSS_CRIT_PCT"; then
      MON_INET_LOSS_STREAK=0
      _mon_add_rule critical L1
    elif loss_at_least "$MON_INET_LOSS" "$LOSS_WARN_PCT" \
         || loss_at_least "$MON_INET_LOSS_ALT" "$LOSS_WARN_PCT"; then
      MON_INET_LOSS_STREAK=$((MON_INET_LOSS_STREAK + 1))
      if [ "$MON_INET_LOSS_STREAK" -ge "$THRESH_MON_LOSS_CONFIRM_CYCLES" ]; then
        _mon_add_rule warn L2
      fi
    else
      MON_INET_LOSS_STREAK=0
    fi
  else
    MON_INET_LOSS_STREAK=0
  fi

  # Cadence follows severity, not rule count: an info-level VPN notice is
  # not a reason to probe twice as often.
  case "$MON_SEVERITY" in
    warn|critical) MON_DEGRADED=1 ;;
    *)             MON_DEGRADED=0 ;;
  esac
  return 0
}

# ── Previous-sample snapshot ─────────────────────────────────────────────
# Called after each successful emit, so the next sample diffs against
# what the consumer actually saw.
#
# Identity fields keep their last KNOWN value: the diff in
# monitor_sample.py suppresses comparisons where either side is null,
# so an empty value here (a link-down sample, a fetch that failed)
# must not erase the baseline — otherwise en0 → "" → en5 never
# reports interface-changed. Rules and the VPN flag are always
# evaluated, so they snapshot unconditionally; their empties are
# meaningful (that is what lets rule-cleared and vpn-disconnected
# fire).
_mon_snapshot_prev() {
  [ -n "$MON_PUB_IP" ]    && MON_PREV_PUB_IP="$MON_PUB_IP"
  [ -n "$MON_PUB_CC" ]    && MON_PREV_PUB_CC="$MON_PUB_CC"
  [ -n "$MON_PUB_ISP" ]   && MON_PREV_PUB_ISP="$MON_PUB_ISP"
  [ -n "$MON_VPN_NAME" ]  && MON_PREV_VPN_NAME="$MON_VPN_NAME"
  [ -n "$MON_SSID" ]      && MON_PREV_SSID="$MON_SSID"
  [ -n "$MON_BSSID" ]     && MON_PREV_BSSID="$MON_BSSID"
  [ -n "$MON_INTERFACE" ] && MON_PREV_INTERFACE="$MON_INTERFACE"
  MON_PREV_VPN_ACTIVE="$MON_VPN_ACTIVE"
  MON_PREV_RULES="$MON_RULES"
  MON_HAVE_PREV=1
  return 0
}

# ── Emit ─────────────────────────────────────────────────────────────────
# Through python3 rather than bash printf. An SSID may contain a quote, a
# backslash, or a newline, and a JSON-escaping bug in a stream the GUI
# parses forever is a far worse trade than ~50 ms of interpreter startup
# once per cycle. At the 10 s fast cadence that is 0.5% duty.
_mon_emit() {
  # The sibling import (rules_catalog.py) must not write __pycache__ into a
  # sealed app bundle: newer Homebrew pythons do so by default, and inside
  # the signed .app that mutates a resource the signature covers.
  PYTHONDONTWRITEBYTECODE=1 \
  NETDIAG_MON_SCHEMA=2 \
  NETDIAG_MON_VERSION="$NETDIAG_VERSION" \
  NETDIAG_MON_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  NETDIAG_MON_SEQ="$MON_SEQ" \
  NETDIAG_MON_GAP_S="$MON_GAP_S" \
  NETDIAG_MON_REFRESHED="$MON_REFRESHED" \
  NETDIAG_MON_LINK_UP="$MON_LINK_UP" \
  NETDIAG_MON_INTERFACE="$MON_INTERFACE" \
  NETDIAG_MON_IFACE_TYPE="$MON_IFACE_TYPE" \
  NETDIAG_MON_LOCAL_IP="$MON_LOCAL_IP" \
  NETDIAG_MON_GATEWAY="$MON_GATEWAY" \
  NETDIAG_MON_GW_MAC="$MON_GW_MAC" \
  NETDIAG_MON_SSID="$MON_SSID" \
  NETDIAG_MON_BSSID="$MON_BSSID" \
  NETDIAG_MON_NETWORK_ID="$MON_NETWORK_ID" \
  NETDIAG_MON_NETWORK_LABEL="$MON_NETWORK_LABEL" \
  NETDIAG_MON_NETWORK_GROUP="$MON_NETWORK_GROUP" \
  NETDIAG_MON_VPN_ACTIVE="$MON_VPN_ACTIVE" \
  NETDIAG_MON_VPN_TYPE="$MON_VPN_TYPE" \
  NETDIAG_MON_VPN_NAME="$MON_VPN_NAME" \
  NETDIAG_MON_GW_LOSS="$MON_GW_LOSS" \
  NETDIAG_MON_GW_RTT="$MON_GW_RTT" \
  NETDIAG_MON_INET_LOSS="$MON_INET_LOSS" \
  NETDIAG_MON_INET_RTT="$MON_INET_RTT" \
  NETDIAG_MON_WIFI_RSSI="$MON_WIFI_RSSI" \
  NETDIAG_MON_WIFI_NOISE="$MON_WIFI_NOISE" \
  NETDIAG_MON_WIFI_SNR="$MON_WIFI_SNR" \
  NETDIAG_MON_WIFI_CHAN="$MON_WIFI_CHAN" \
  NETDIAG_MON_DNS_OK="$MON_DNS_OK" \
  NETDIAG_MON_DNS_RESOLVER="$MON_DNS_RESOLVER" \
  NETDIAG_MON_DNS_MS="$MON_DNS_MS" \
  NETDIAG_MON_TCP_OK="$MON_TCP_OK" \
  NETDIAG_MON_TCP_LINES="$MON_TCP_LINES" \
  NETDIAG_MON_WEB_OK="$MON_WEB_OK" \
  NETDIAG_MON_PUBLIC_OK="$MON_PUBLIC_OK" \
  NETDIAG_MON_PUB_IP="$MON_PUB_IP" \
  NETDIAG_MON_PUB_ISP="$MON_PUB_ISP" \
  NETDIAG_MON_PUB_ASN="$MON_PUB_ASN" \
  NETDIAG_MON_PUB_CITY="$MON_PUB_CITY" \
  NETDIAG_MON_PUB_CC="$MON_PUB_CC" \
  NETDIAG_MON_PUB_CC_ISO="$MON_PUB_CC_ISO" \
  NETDIAG_MON_CAPTIVE="$MON_CAPTIVE" \
  NETDIAG_MON_RULES="$MON_RULES" \
  NETDIAG_MON_SEVERITY="$MON_SEVERITY" \
  NETDIAG_MON_MEASUREMENT_STATE="$MON_MEASUREMENT_STATE" \
  NETDIAG_MON_ICMP_FILTERED="$MON_ICMP_FILTERED" \
  NETDIAG_MON_DEGRADED="$MON_DEGRADED" \
  NETDIAG_MON_PAUSED="$MON_PAUSED" \
  NETDIAG_MON_CADENCE_S="$1" \
  NETDIAG_MON_HAVE_PREV="$MON_HAVE_PREV" \
  NETDIAG_MON_PREV_PUB_IP="$MON_PREV_PUB_IP" \
  NETDIAG_MON_PREV_PUB_CC="$MON_PREV_PUB_CC" \
  NETDIAG_MON_PREV_PUB_ISP="$MON_PREV_PUB_ISP" \
  NETDIAG_MON_PREV_VPN_ACTIVE="$MON_PREV_VPN_ACTIVE" \
  NETDIAG_MON_PREV_VPN_NAME="$MON_PREV_VPN_NAME" \
  NETDIAG_MON_PREV_SSID="$MON_PREV_SSID" \
  NETDIAG_MON_PREV_BSSID="$MON_PREV_BSSID" \
  NETDIAG_MON_PREV_INTERFACE="$MON_PREV_INTERFACE" \
  NETDIAG_MON_PREV_RULES="$MON_PREV_RULES" \
  python3 "$HELPERS_DIR/monitor_sample.py"
}

# ── Loop ─────────────────────────────────────────────────────────────────

# ── Sleep and stall detection ────────────────────────────────────────────
#
# The seconds lost between two consecutive cycles, or empty when the
# elapsed time is within tolerance. $1 = elapsed seconds since the
# previous cycle started, $2 = the cadence that cycle was scheduled at.
#
# The header of this file says the monitor stays dumb about sleep and
# leaves it to the GUI's NSWorkspace notifications. That is right for the
# GUI and wrong for every other consumer: `--monitor` is documented as a
# stream for *any* program, and a laptop lid closed for eight hours emits
# two samples eight hours apart with nothing marking the discontinuity.
# A program reading that stream sees an eight-hour outage that never
# happened — the loss and latency figures either side are both fine, and
# the silence between them is indistinguishable from a dead link.
#
# Reports the elapsed time rather than a boolean, because "how long was I
# not looking" is the question a consumer actually has to answer, and it
# is the difference between a hiccup and an overnight sleep.
#
# Pure: no clock reads, no state. Both inputs come from the caller.
_mon_gap_seconds() {
  local elapsed="${1:-}" cadence="${2:-}"
  case "$elapsed" in ''|*[!0-9]*) return 0 ;; esac
  case "$cadence" in ''|*[!0-9]*|0) return 0 ;; esac
  [ "$elapsed" -gt $((cadence * THRESH_MON_GAP_FACTOR)) ] || return 0
  printf '%s' "$elapsed"
}

# Interruptible sleep. A bare `sleep` swallows the signal until it returns,
# so a GUI sending SIGTERM would wait up to a full cadence for the process
# to die; backgrounding it and waiting makes the trap fire immediately.
_mon_sleep() {
  if [ "$MON_REFRESH_REQUESTED" -eq 1 ]; then
    MON_REFRESH_REQUESTED=0
    return 0
  fi
  sleep "$1" &
  wait $! 2>/dev/null || true
}

# All three are reached via trap, an indirect dispatch static analysis
# can't follow.
# shellcheck disable=SC2317,SC2329
_mon_on_signal() { MON_STOP=1; }
# shellcheck disable=SC2317,SC2329
_mon_on_pause()  { MON_PAUSED=1; }
# shellcheck disable=SC2317,SC2329
_mon_on_resume() { MON_PAUSED=0; }
# shellcheck disable=SC2317,SC2329
_mon_on_refresh() { MON_REFRESH_REQUESTED=1; }

monitor_run() {
  local now next_fast=0 next_medium=0 next_slow=0 cadence
  local prev_network_id="" network_changed announced_pause=0
  # Captured once: bash never updates PPID, so this is the pid of whoever
  # started us and stays that way even after re-parenting.
  local parent_pid="$PPID"
  trap _mon_on_signal INT TERM
  trap _mon_on_pause  USR1
  trap _mon_on_resume USR2
  # The GUI uses SIGALRM as a cheap "sample now" nudge after a network
  # transition. Bash's default action is to terminate the monitor, so this
  # must stay an explicit, harmless flag rather than an untrapped signal.
  trap _mon_on_refresh ALRM

  while :; do
    [ "$MON_STOP" -eq 0 ] || break

    # A refresh request interrupts the remainder of the cadence. The signal
    # is intentionally handled between cycles: a probe already in flight
    # must finish and be emitted as a coherent sample before the next one.
    if [ "$MON_REFRESH_REQUESTED" -eq 1 ]; then
      MON_REFRESH_REQUESTED=0
      next_fast=0
      next_medium=0
      next_slow=0
    fi
    # Checked even while paused — a paused monitor whose consumer died is
    # exactly as orphaned as a running one, and rather harder to notice.
    # A parent of MON_INIT_PID means we were started by launchd, or were
    # already orphaned before the loop began; either way there is no
    # meaningful parent left to watch.
    if [ "$parent_pid" -gt "$MON_INIT_PID" ] && ! kill -0 "$parent_pid" 2>/dev/null; then
      break
    fi

    # Paused: probe nothing, emit nothing, but stay alive and responsive.
    # One sample announces the pause so a consumer — or a person watching
    # the stream in a terminal — sees why it went quiet, rather than being
    # left to wonder whether the process died.
    if [ "$MON_PAUSED" -eq 1 ]; then
      if [ "$announced_pause" -eq 0 ]; then
        announced_pause=1
        MON_REFRESHED=""
        MON_SEQ=$((MON_SEQ + 1))
        _mon_emit "$MONITOR_FAST_INTERVAL" || break
        _mon_snapshot_prev
      fi
      # One second at a time so SIGUSR2 resumes promptly. The trap fires
      # during _mon_sleep's `wait`, so the real latency is immediate; this
      # bound only covers the gap between iterations.
      _mon_sleep 1
      continue
    fi
    announced_pause=0

    now="$EPOCHSECONDS"
    # How long since the previous cycle began, against what that cycle was
    # scheduled for. Computed here rather than after the probes so it
    # measures the gap the consumer experienced — the silence between two
    # samples — not the time this cycle's own work took.
    MON_GAP_S=""
    if [ -n "$MON_PREV_CYCLE_TS" ] && [ -n "$MON_PREV_CADENCE" ]; then
      MON_GAP_S="$(_mon_gap_seconds \
        "$((now - MON_PREV_CYCLE_TS))" "$MON_PREV_CADENCE")"
    fi
    MON_REFRESHED=""

    # Fast tier drives everything: it establishes whether there is a link
    # at all, and the identity the other tiers are scoped to.
    if [ "$now" -ge "$next_fast" ]; then
      MON_REFRESHED+="fast "
      _mon_probe_link
      _mon_probe_vpn
      if [ "$MON_LINK_UP" -eq 1 ]; then
        _mon_probe_gateway
        _mon_probe_internet
        _mon_probe_web
      else
        # No link, no valid window: every packet in it predates the drop.
        _mon_loss_reset
      fi
    fi

    network_changed=0
    if [ "$MON_NETWORK_ID" != "$prev_network_id" ]; then
      network_changed=1
      prev_network_id="$MON_NETWORK_ID"
      # A different network is a different path; loss measured on the old
      # one says nothing about this one. Cleared here rather than keyed per
      # network because the window's whole point is describing *this*
      # link's recent past — there is no "come back to it later" case.
      [ -n "$MON_NETWORK_ID" ] && _mon_loss_reset
    fi

    # A dead link means nothing to probe. Skipping the other tiers here is
    # the monitor's only power decision, and it is about pointlessness
    # rather than battery: a DNS query with no default route cannot
    # succeed, it can only cost four seconds of timeout per cycle.
    if [ "$MON_LINK_UP" -eq 1 ]; then
      if [ "$now" -ge "$next_medium" ] || [ "$network_changed" -eq 1 ]; then
        MON_REFRESHED+="medium "
        _mon_probe_dns
        _mon_probe_tcp
        _mon_probe_wifi_signal
        next_medium=$((now + MONITOR_MEDIUM_INTERVAL))
      fi
      # The slow tier is the only external call, so it is the only one
      # where being polite matters — but a network change is exactly when
      # its answer has certainly gone stale, so that overrides the timer.
      if [ "$now" -ge "$next_slow" ] || [ "$network_changed" -eq 1 ]; then
        MON_REFRESHED+="slow "
        _mon_probe_public
        next_slow=$((now + MONITOR_SLOW_INTERVAL))
      fi
    fi

    # ── Freshness on internet-side loss ───────────────────────────────────
    # The fast tier pings the internet every cycle; the TCP and public
    # probes run on the medium (60 s) and slow (300 s) tiers and are
    # carried over stale between refreshes. A real internet outage —
    # gateway quiet, internet ping at critical loss — therefore reads, for
    # up to a minute, exactly like an ICMP-filtering hotel network: TCP and
    # public still "ok" from before the drop, so _mon_rules concludes
    # ICMP-1 (info) instead of L1 (critical), severity stays info, the
    # menu-bar dot stays green, and no connection-lost alert fires. A
    # manual scan is the only thing that forces fresh probes — which is why
    # alerts appeared only after the user pressed "Check My Connection".
    #
    # Forcing a fresh TCP probe the moment the fast tier sees the outage
    # breaks that stale-data lock within one cycle. If TCP now fails too,
    # _mon_rules names L1 (critical), degraded engages, and the fast tier
    # drops to its 5 s cadence for the duration of the outage. Public is
    # forced the same way so P1/P2 (which gate on MON_PUBLIC_OK) do not sit
    # behind the 300 s slow timer either. Gated on the tier not having
    # already run this cycle, so a cycle that hit the medium/slow timers on
    # its own pays nothing extra, and during a sustained outage the forced
    # path fires only on cycles the scheduled tiers skipped.
    if [ "$MON_LINK_UP" -eq 1 ] \
       && loss_at_least "$MON_INET_LOSS" "$LOSS_CRIT_PCT" \
       && loss_below "$MON_GW_LOSS" "$LOSS_WARN_PCT"; then
      if ! printf '%s' "$MON_REFRESHED" | grep -qw medium; then
        MON_REFRESHED+="medium "
        _mon_probe_tcp
        next_medium=$((now + MONITOR_MEDIUM_INTERVAL))
      fi
      if ! printf '%s' "$MON_REFRESHED" | grep -qw slow; then
        MON_REFRESHED+="slow "
        _mon_probe_public
        next_slow=$((now + MONITOR_SLOW_INTERVAL))
      fi
    fi

    _mon_rules

    cadence="$MONITOR_FAST_INTERVAL"
    [ "$MON_DEGRADED" -eq 1 ] && cadence="$MONITOR_DEGRADED_INTERVAL"
    next_fast=$((now + cadence))

    MON_SEQ=$((MON_SEQ + 1))
    MON_PREV_CYCLE_TS="$now"
    MON_PREV_CADENCE="$cadence"
    # A failed emit means stdout is gone — the GUI exited, or a `| head -5`
    # closed the pipe. Either way there is no one left to talk to.
    _mon_emit "$cadence" || break
    _mon_snapshot_prev

    if [ "$MONITOR_COUNT" -gt 0 ] && [ "$MON_SEQ" -ge "$MONITOR_COUNT" ]; then
      break
    fi
    [ "$MON_STOP" -eq 0 ] || break

    # Sleep only the remainder: the probes themselves take 2-6 s, and
    # sleeping a full interval on top would make the real cadence drift
    # well past what the app's Settings slider claims.
    local spent remain
    spent=$((EPOCHSECONDS - now))
    remain=$((cadence - spent))
    [ "$remain" -gt 0 ] && _mon_sleep "$remain"
  done
  return 0
}
