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
MON_VPN_ACTIVE=0
MON_VPN_TYPE=""
MON_VPN_NAME=""
MON_GW_LOSS=""
MON_GW_RTT=""
MON_WIFI_RSSI=""
MON_WIFI_NOISE=""
MON_WIFI_SNR=""
MON_WIFI_CHAN=""
MON_DNS_OK=""
MON_DNS_RESOLVER=""
MON_DNS_MS=""
MON_TCP_OK=""
MON_TCP_LINES=""
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
MON_ICMP_FILTERED=0
MON_DEGRADED=0
MON_REFRESHED=""
MON_STOP=0
MON_PAUSED=0
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
    local hw_port
    hw_port="$(printf '%s\n' "$MON_HW_PORTS" | awk -v d="$MON_INTERFACE" '
      /^Hardware Port:/{port=substr($0, index($0,$3))}
      /^Device:/{if($2==d){print port; exit}}')"
    if printf '%s' "$hw_port" | grep -qi 'Wi-Fi\|AirPort'; then
      MON_IFACE_TYPE="wifi"
      local summary
      summary="$(ipconfig getsummary "$MON_INTERFACE" 2>/dev/null || true)"
      MON_SSID="$(printf '%s\n' "$summary"  | awk -F': ' '/^[[:space:]]*SSID[[:space:]]*:/{print $2; exit}')"
      MON_BSSID="$(printf '%s\n' "$summary" | awk -F': ' '/^[[:space:]]*BSSID[[:space:]]*:/{print $2; exit}')"
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
  # netid_run reads these four by name and writes the two below. They look
  # unused to shellcheck because the read happens in another file through
  # dynamic scope, which is exactly the point: the precedence logic stays
  # in one place.
  # shellcheck disable=SC2034
  local IS_WIFI=0 WIFI_SSID="$MON_SSID" GW_MAC="$MON_GW_MAC" GATEWAY="$MON_GATEWAY"
  local NETWORK_ID="" NETWORK_LABEL=""
  # shellcheck disable=SC2034
  [ "$MON_IFACE_TYPE" = "wifi" ] && IS_WIFI=1
  netid_run
  MON_NETWORK_ID="$NETWORK_ID"
  MON_NETWORK_LABEL="$NETWORK_LABEL"
}

_mon_probe_vpn() {
  MON_VPN_ACTIVE=0; MON_VPN_TYPE=""; MON_VPN_NAME=""
  # A utun/wg interface carrying the default route is free to detect —
  # _mon_probe_link already read it.
  if printf '%s' "$MON_INTERFACE" | grep -qE '^(utun|wg)'; then
    MON_VPN_ACTIVE=1; MON_VPN_TYPE="utun-route"; MON_VPN_NAME="$MON_INTERFACE"
    return 0
  fi
  local scutil_nc
  scutil_nc="$(scutil --nc list 2>/dev/null || true)"
  if printf '%s' "$scutil_nc" | grep -q '(Connected)'; then
    MON_VPN_ACTIVE=1
    MON_VPN_TYPE="managed"
    MON_VPN_NAME="$(printf '%s' "$scutil_nc" | awk -F'"' '/\(Connected\)/{print $2; exit}')"
  fi
}

_mon_probe_gateway() {
  MON_GW_LOSS=""; MON_GW_RTT=""
  [ -n "$MON_GATEWAY" ] || return 0
  local out
  # -q: summary only. The scanner keeps the per-packet lines because it
  # logs them; nothing here reads them.
  #
  # MONITOR_PING_COUNT is 10, not the 3 or 5 a "quick liveness check"
  # suggests, and the reason is quantisation rather than accuracy. At 3
  # packets the only reportable losses are 0/33/67/100%, so one dropped
  # packet reads as 33% — comfortably past the 20% critical floor. At 5 it
  # reads as exactly 20%, which still trips it. At 10 the quantum is 10%:
  # one drop lands in G3's warn band and it takes two to reach critical,
  # which is the same shape the scanner's 20-packet probe produces. Cost
  # is 2 s of a 10 s cycle, at one packet per second average.
  out="$(with_timeout 6 ping -q -c "$MONITOR_PING_COUNT" -i "$MONITOR_PING_INTERVAL" "$MON_GATEWAY" 2>/dev/null || true)"
  MON_GW_LOSS="$(printf '%s\n' "$out" | awk -F'[ %]' '/packet loss/{for(i=1;i<=NF;i++)if($i=="packet")print $(i-2)}' | head -1)"
  MON_GW_RTT="$(printf '%s\n' "$out"  | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}')"
  is_numeric "$MON_GW_LOSS" || MON_GW_LOSS=""
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
  MON_INET_LOSS=""; MON_INET_RTT=""
  [ "$MON_LINK_UP" -eq 1 ] || return 0
  local out
  out="$(with_timeout 3 ping -q -c 5 -i 0.2 1.1.1.1 2>/dev/null || true)"
  MON_INET_LOSS="$(printf '%s\n' "$out" | awk -F'[ %]' '/packet loss/{for(i=1;i<=NF;i++)if($i=="packet")print $(i-2)}' | head -1)"
  MON_INET_RTT="$(printf '%s\n' "$out"  | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}')"
  is_numeric "$MON_INET_LOSS" || MON_INET_LOSS=""
  is_numeric "$MON_INET_RTT"  || MON_INET_RTT=""
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
  rssi="$(printf  '%s\n' "$out" | awk -F': ' '/^[[:space:]]*RSSI/{gsub(/ dBm/,"",$2); print $2; exit}')"
  noise="$(printf '%s\n' "$out" | awk -F': ' '/^[[:space:]]*Noise/{gsub(/ dBm/,"",$2); print $2; exit}')"
  MON_WIFI_CHAN="$(printf '%s\n' "$out" | awk -F': ' '/^[[:space:]]*Channel/{print $2; exit}')"
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
  local captive
  captive="$(curl -s -m 3 -o /dev/null -w '%{http_code}' \
    http://captive.apple.com/hotspot-detect.html 2>/dev/null || true)"
  case "$captive" in
    200)      MON_CAPTIVE=0 ;;
    3[0-9][0-9]) MON_CAPTIVE=1 ;;
    *)        MON_CAPTIVE="" ;;
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

  if [ "$MON_LINK_UP" -eq 0 ]; then
    _mon_add_rule critical N1
    MON_DEGRADED=1
    return 0
  fi

  # G1/G2/G3, evaluated exactly as lib/diagnosis.sh evaluates them —
  # including when ICMP turns out to be filtered.
  #
  # It is tempting to suppress these when TCP-1 holds, and wrong. The
  # constraint this project is built on is that the CLI owns every verdict
  # and the GUI owns only alert policy. A monitor that quietly withheld G2
  # on a hotel network would name a different rule set than a scan taken
  # one second later on the same link, and the app would show a green dot
  # over a red report. So the rule fires, `status.icmp_filtered` says the
  # ping numbers are not to be trusted, and the alert engine — whose job
  # this is — declines to notify. Same facts, one place to decide.
  if loss_at_least "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    if [ -n "$MON_WIFI_RSSI" ] && is_numeric "$MON_WIFI_RSSI" && [ "$MON_WIFI_RSSI" -le "$THRESH_WIFI_RSSI_G1_DBM" ]; then
      _mon_add_rule critical G1
    else
      _mon_add_rule critical G2
    fi
  elif loss_at_least "$MON_GW_LOSS" "$LOSS_WARN_PCT"; then
    _mon_add_rule warn G3
  fi

  # P1/P2 need the slow tier to have run at least once. An unmeasured
  # public reach is "" and must not read as an outage — the same
  # distinction that JSON-SCHEMA.md draws between null and 0.
  if [ "${MON_PUBLIC_OK:-}" = "0" ] && loss_below "$MON_GW_LOSS" "$THRESH_GW_LOSS_CRIT_PCT"; then
    if [ "${MON_DNS_OK:-}" = "0" ]; then
      _mon_add_rule critical P1
    else
      _mon_add_rule critical P2
    fi
  fi

  # D1 — resolution failing while the internet itself is reachable.
  if [ "${MON_DNS_OK:-}" = "0" ] && [ "${MON_PUBLIC_OK:-}" = "1" ]; then
    _mon_add_rule warn D1
  fi

  if [ "${MON_CAPTIVE:-}" = "1" ]; then
    _mon_add_rule warn CP-1
  fi

  if [ "$MON_VPN_ACTIVE" -eq 1 ]; then
    _mon_add_rule info VPN-1
  fi

  # TCP-1 matching lib/diagnosis.sh's logic. Real connections work, only
  # ping is being dropped — common on hotel and corporate WiFi.
  if [ "${MON_TCP_OK:-0}" = "1" ] \
     && loss_at_least "$MON_GW_LOSS" "$THRESH_ICMP_FILTERED_LOSS_PCT"; then
    MON_ICMP_FILTERED=1
    _mon_add_rule info TCP-1
  fi

  # ── L1 / L2 — internet-side packet loss ────────────────────────────────
  local _mon_icmp_filtered=0
  if [ "${MON_PUBLIC_OK:-0}" = "1" ] && [ "${MON_TCP_OK:-0}" = "1" ] \
     && loss_at_least "$MON_INET_LOSS" "$THRESH_ICMP_TOTAL_LOSS_PCT"; then
    _mon_icmp_filtered=1
    _mon_add_rule info ICMP-1
  fi

  if [ "$_mon_icmp_filtered" -eq 0 ] && loss_below "$MON_GW_LOSS" "$LOSS_WARN_PCT"; then
    if loss_at_least "$MON_INET_LOSS" "$LOSS_CRIT_PCT"; then
      _mon_add_rule critical L1
    elif loss_at_least "$MON_INET_LOSS" "$LOSS_WARN_PCT"; then
      _mon_add_rule warn L2
    fi
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

# Interruptible sleep. A bare `sleep` swallows the signal until it returns,
# so a GUI sending SIGTERM would wait up to a full cadence for the process
# to die; backgrounding it and waiting makes the trap fire immediately.
_mon_sleep() {
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

monitor_run() {
  local now next_fast=0 next_medium=0 next_slow=0 cadence
  local prev_network_id="" network_changed announced_pause=0
  # Captured once: bash never updates PPID, so this is the pid of whoever
  # started us and stays that way even after re-parenting.
  local parent_pid="$PPID"
  trap _mon_on_signal INT TERM
  trap _mon_on_pause  USR1
  trap _mon_on_resume USR2

  while :; do
    [ "$MON_STOP" -eq 0 ] || break
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
      fi
    fi

    network_changed=0
    if [ "$MON_NETWORK_ID" != "$prev_network_id" ]; then
      network_changed=1
      prev_network_id="$MON_NETWORK_ID"
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

    _mon_rules

    cadence="$MONITOR_FAST_INTERVAL"
    [ "$MON_DEGRADED" -eq 1 ] && cadence="$MONITOR_DEGRADED_INTERVAL"
    next_fast=$((now + cadence))

    MON_SEQ=$((MON_SEQ + 1))
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
