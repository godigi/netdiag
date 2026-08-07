# shellcheck shell=bash
# lib/output.sh — JSON build, baseline regression check, "Report saved to"
# line. Always builds JSON (the baseline helper needs it); rebuilds after
# the regression check so regressions surface inside the JSON's diagnosis
# array too.
#
# Reads:  almost every module global
# Writes: BASELINE_JSON, MOST_LIKELY_ROOT_CAUSE (recomputed),
#         DIAGNOSIS_LINES (extended with regressions), MAX_SEVERITY
#         (extended via add_diag), $LOG_DIR/baseline.jsonl (file)
# Entry:  output_run

build_json() {
  # Most-likely root cause = first critical diagnosis, else first warn,
  # else empty. DIAG_SEV/DIAG are parallel arrays.
  MOST_LIKELY_ROOT_CAUSE=""
  local s i
  for s in critical warn; do
    for i in "${!DIAG[@]}"; do
      if [ "${DIAG_SEV[$i]}" = "$s" ] && [ -z "$MOST_LIKELY_ROOT_CAUSE" ]; then
        MOST_LIKELY_ROOT_CAUSE="${DIAG[$i]}"
      fi
    done
  done

  NETDIAG_VERSION="$NETDIAG_VERSION" \
  NETDIAG_TIMESTAMP="$TIMESTAMP_ISO" \
  NETDIAG_INTERFACE="$INTERFACE" \
  NETDIAG_LOCAL_IP="${LOCAL_IP:-}" \
  NETDIAG_GATEWAY="$GATEWAY" \
  NETDIAG_IS_WIFI="$IS_WIFI" \
  NETDIAG_WIFI_SSID="$WIFI_SSID" \
  NETDIAG_WIFI_BSSID="$WIFI_BSSID" \
  NETDIAG_WIFI_SEC="$WIFI_SEC" \
  NETDIAG_WIFI_RSSI="${WIFI_RSSI:-}" \
  NETDIAG_WIFI_NOISE="${WIFI_NOISE:-}" \
  NETDIAG_WIFI_SNR="${WIFI_SNR:-}" \
  NETDIAG_WIFI_CHAN="$WIFI_CHAN" \
  NETDIAG_WIFI_PHY="$WIFI_PHY" \
  NETDIAG_WIFI_TX="$WIFI_TX" \
  NETDIAG_VPN_ACTIVE="$VPN_ACTIVE" \
  NETDIAG_VPN_TYPE="$VPN_TYPE" \
  NETDIAG_VPN_NAME="$VPN_NAME" \
  NETDIAG_GW_LOSS="${GW_LOSS:-}" \
  NETDIAG_GW_LATENCY="${GW_LATENCY:-}" \
  NETDIAG_GW_JITTER="${GW_JITTER:-}" \
  NETDIAG_INET_RTT_AVG="${INET_RTT_AVG:-}" \
  NETDIAG_INET_RTT_JITTER="${INET_RTT_JITTER:-}" \
  NETDIAG_INET_LOSS="${INET_LOSS:-}" \
  NETDIAG_HOSTS_CUSTOM_COUNT="${HOSTS_CUSTOM_COUNT:-0}" \
  NETDIAG_HOSTS_SUSPICIOUS_LINES="${HOSTS_SUSPICIOUS_LINES:-}" \
  NETDIAG_PUB_IP="$PUB_IP" \
  NETDIAG_PUB_ASN="$PUB_ASN" \
  NETDIAG_PUB_ISP="$PUB_ISP" \
  NETDIAG_PUB_CITY="$PUB_CITY" \
  NETDIAG_PUB_CC="$PUB_CC" \
  NETDIAG_CAPTIVE_PORTAL="$CAPTIVE_PORTAL" \
  NETDIAG_BUFFERBLOAT_IDLE_GW_RTT="$BUFFERBLOAT_IDLE_GW_RTT" \
  NETDIAG_BUFFERBLOAT_LOADED_GW_RTT="$BUFFERBLOAT_LOADED_GW_RTT" \
  NETDIAG_BUFFERBLOAT_IDLE_INET_RTT="$BUFFERBLOAT_IDLE_INET_RTT" \
  NETDIAG_BUFFERBLOAT_LOADED_INET_RTT="$BUFFERBLOAT_LOADED_INET_RTT" \
  NETDIAG_BUFFERBLOAT_GW_DELTA="$BUFFERBLOAT_GW_DELTA" \
  NETDIAG_BUFFERBLOAT_INET_DELTA="$BUFFERBLOAT_INET_DELTA" \
  NETDIAG_BUFFERBLOAT_GW_GRADE="$BUFFERBLOAT_GW_GRADE" \
  NETDIAG_BUFFERBLOAT_INET_GRADE="$BUFFERBLOAT_INET_GRADE" \
  NETDIAG_MTU_EFFECTIVE="$MTU_EFFECTIVE" \
  NETDIAG_MTU_PATH_SIZE="$MTU_PATH_SIZE" \
  NETDIAG_DNS_LINES="$DNS_LINES" \
  NETDIAG_IPV6_AVAILABLE="$IPV6_AVAILABLE" \
  NETDIAG_IPV6_GLOBAL_ADDR="$IPV6_GLOBAL_ADDR" \
  NETDIAG_IPV6_GATEWAY="$IPV6_GATEWAY" \
  NETDIAG_IPV6_PING_LOSS="$IPV6_PING_LOSS" \
  NETDIAG_IPV6_AAAA_OK="$IPV6_AAAA_OK" \
  NETDIAG_IPV6_TRACE_HOPS="$IPV6_TRACE_HOPS" \
  NETDIAG_IPV6_TCP_OK="$IPV6_TCP_OK" \
  NETDIAG_TCP_REACH_LINES="$TCP_REACH_LINES" \
  NETDIAG_WIFI_SCAN_CURRENT_CHANNEL="$WIFI_SCAN_CURRENT_CHANNEL" \
  NETDIAG_WIFI_SCAN_CURRENT_BAND="$WIFI_SCAN_CURRENT_BAND" \
  NETDIAG_WIFI_SCAN_NEIGHBOR_COUNT="$WIFI_SCAN_NEIGHBOR_COUNT" \
  NETDIAG_WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS="$WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS" \
  NETDIAG_WIFI_DISCONNECT_WINDOW_HOURS="$WIFI_DISCONNECT_WINDOW_HOURS" \
  NETDIAG_WIFI_DISCONNECT_COUNT="$WIFI_DISCONNECT_COUNT" \
  NETDIAG_SPEEDTEST_DOWN_MBPS="$SPEEDTEST_DOWN_MBPS" \
  NETDIAG_SPEEDTEST_UP_MBPS="$SPEEDTEST_UP_MBPS" \
  NETDIAG_SPEEDTEST_LATENCY_MS="$SPEEDTEST_LATENCY_MS" \
  NETDIAG_SPEEDTEST_JITTER_MS="$SPEEDTEST_JITTER_MS" \
  NETDIAG_SPEEDTEST_SERVER="$SPEEDTEST_SERVER" \
  NETDIAG_NTP_DRIFT_S="$NTP_DRIFT_S" \
  NETDIAG_NTP_USING_NETWORK_TIME="$NTP_USING_NETWORK_TIME" \
  NETDIAG_NTP_SERVER="$NTP_SERVER" \
  NETDIAG_DHCP_SERVER="$DHCP_SERVER" \
  NETDIAG_DHCP_LEASE_START="$DHCP_LEASE_START" \
  NETDIAG_DHCP_LEASE_END="$DHCP_LEASE_END" \
  NETDIAG_DHCP_TIME_REMAINING_S="${DHCP_TIME_REMAINING_S:-}" \
  NETDIAG_DHCP_DNS_SERVERS="$DHCP_DNS_SERVERS" \
  NETDIAG_ARP_DUPLICATE_IPS="$ARP_DUPLICATE_IPS" \
  NETDIAG_GW_MAC="$GW_MAC" \
  NETDIAG_NETWORK_ID="$NETWORK_ID" \
  NETDIAG_NETWORK_LABEL="$NETWORK_LABEL" \
  NETDIAG_ARP_GW_INCOMPLETE="$ARP_GW_INCOMPLETE" \
  NETDIAG_MTR_FIRST_LOSSY_HOP="$MTR_FIRST_LOSSY_HOP" \
  NETDIAG_TARGET="$TARGET" \
  NETDIAG_TARGET_PING_LOSS="$TARGET_PING_LOSS" \
  NETDIAG_TARGET_PING_RTT="$TARGET_PING_RTT" \
  NETDIAG_TRACE_LINES="$TRACE_LINES" \
  NETDIAG_TARGET_TRACE_LINES="$TARGET_TRACE_LINES" \
  NETDIAG_PER_HOP_LINES="$PER_HOP_LINES" \
  NETDIAG_BASELINE_JSON="$BASELINE_JSON" \
  NETDIAG_DIAGNOSIS_LINES="$DIAGNOSIS_LINES" \
  NETDIAG_MOST_LIKELY_ROOT_CAUSE="${MOST_LIKELY_ROOT_CAUSE:-}" \
  NETDIAG_WAN_LB_ASNS="$WAN_LB_ASNS" \
  NETDIAG_WAN_LB_IPS="$WAN_LB_IPS" \
  NETDIAG_WAN_LB_ACTIVE="$WAN_LB_ACTIVE" \
  NETDIAG_WAN_DOUBLE_NAT="$WAN_DOUBLE_NAT" \
  NETDIAG_WAN_DOUBLE_NAT_CHAIN="$WAN_DOUBLE_NAT_CHAIN" \
  NETDIAG_WAN_NAT_HOME_CHAIN="$WAN_NAT_HOME_CHAIN" \
  NETDIAG_WAN_NAT_HOME_COUNT="$WAN_NAT_HOME_COUNT" \
  NETDIAG_WAN_NAT_ISP_CHAIN="$WAN_NAT_ISP_CHAIN" \
  NETDIAG_WAN_NAT_ISP_COUNT="$WAN_NAT_ISP_COUNT" \
  NETDIAG_WAN_UPNP_STATE="$WAN_UPNP_STATE" \
  NETDIAG_WAN_UPNP_DEVICE="$WAN_UPNP_DEVICE" \
  NETDIAG_WAN_UPNP_URL="$WAN_UPNP_URL" \
  NETDIAG_WAN_UPNP_TESTED_VIA="$WAN_UPNP_TESTED_VIA" \
  NETDIAG_TIMING_LINES="$TIMING_LINES" \
  NETDIAG_RUN_ELAPSED_S="$(run_elapsed_s)" \
  NETDIAG_QUICK="$QUICK" \
  NETDIAG_REDACT="$REDACT" \
  python3 "$HELPERS_DIR/emit_json.py"
}

# ── Retention ────────────────────────────────────────────────────────────
# Nothing bounded ~/net-diag before this. The launchd watcher runs every
# 15 min — 96 timestamped .log files and 96 appended JSONL records a day,
# forever — and both baseline.py and summary.py parse the *entire* JSONL
# on every run, so the cost grows without limit.
#
# Both caps are overridable by env var for users who want deeper history:
#   NETDIAG_KEEP_LOGS=0      → keep every log file
#   NETDIAG_KEEP_HISTORY=0   → never truncate baseline.jsonl
# Baseline history is kept much deeper than logs: it's one line per run and
# the thing regressions are actually computed from.
NETDIAG_KEEP_LOGS="${NETDIAG_KEEP_LOGS:-200}"
NETDIAG_KEEP_HISTORY="${NETDIAG_KEEP_HISTORY:-2000}"

prune_history() {
  local file="$1" keep="$2" lines tmp
  [ "$keep" -gt 0 ]   || return 0
  [ -f "$file" ]      || return 0
  lines="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
  is_numeric "$lines" || return 0
  # Only rewrite when meaningfully over the cap, so the common case is a
  # single wc(1) and no file churn.
  [ "$lines" -gt $((keep + keep / 10)) ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/netdiag-hist.XXXXXX")" || return 0
  if tail -n "$keep" "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

prune_logs() {
  local keep="$1" count
  [ "$keep" -gt 0 ] || return 0
  [ -d "$LOG_DIR" ] || return 0
  count="$(find "$LOG_DIR" -maxdepth 1 -name '*.log' -type f 2>/dev/null | wc -l | tr -d ' ')"
  is_numeric "$count" || return 0
  [ "$count" -gt "$keep" ] || return 0
  # Newest-first, drop everything past the cap. Filenames are generated
  # timestamps (no spaces), and -print0/xargs -0 keeps it safe regardless.
  find "$LOG_DIR" -maxdepth 1 -name '*.log' -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | tail -n "+$((keep + 1))" \
    | tr '\n' '\0' \
    | xargs -0 rm -f 2>/dev/null || true
}

output_run() {
  local json_tmp baseline_out baseline_lines reg
  # macOS mktemp(1) only substitutes the trailing X's. Any suffix after
  # them (e.g. ".json") is treated as literal and breaks subsequent runs
  # because the file already exists. Keep X's at the end; the file is
  # internal so the extension doesn't matter.
  json_tmp="$(mktemp "${TMPDIR:-/tmp}/netdiag-out.XXXXXX")"
  build_json > "$json_tmp"

  # Baseline comparison: compare current JSON to history, surface any
  # regressions, then rebuild the JSON so they appear in its diagnosis array.
  if [ "$NO_BASELINE" -eq 0 ] && [ "$BASELINE" -eq 1 ]; then
    mkdir -p "$LOG_DIR"
    # --quick skips the *comparison* per the spec's 8 s budget: it costs two
    # python3 starts plus a full parse of baseline.jsonl, which is the most
    # expensive thing left in a quick run. The snapshot is still appended
    # below, so the launchd watcher — which runs --quick — keeps building
    # the history that full runs are measured against.
    if [ "$QUICK" -eq 0 ]; then
      baseline_out="$(python3 "$HELPERS_DIR/baseline.py" \
        --history "$LOG_DIR/baseline.jsonl" --current "$json_tmp" --n 10 2>/dev/null || true)"
      BASELINE_JSON="$baseline_out"
      if [ -n "$baseline_out" ]; then
        baseline_lines="$(printf '%s' "$baseline_out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('regressions', []):
    kind  = r.get('kind', '?')
    label = r.get('label', r.get('metric'))
    cur   = r.get('current'); med = r.get('median')
    if kind == 'spike':
        print(f'{label} is {cur} vs {med} median (×{r.get(\"factor\",\"?\")} spike)')
    elif kind == 'drop':
        print(f'{label} dropped to {cur} from {med} median')
    elif kind == 'change':
        print(f'{label} changed: \"{cur}\" (was previously \"{med}\")')
")"
        if [ -n "$baseline_lines" ]; then
          while IFS= read -r reg; do
            [ -z "$reg" ] && continue
            add_diag warn BL-1 "Something changed since your last runs: $reg"
            DIAGNOSIS_LINES+="warn|BL-1|Something changed since your last runs: $reg"$'\n'
            warn "Something changed since your last runs: $reg"
          done <<<"$baseline_lines"
          # Rebuild JSON now that DIAGNOSIS_LINES has the regressions.
          build_json > "$json_tmp"
        fi
      fi
    fi
    # Append final snapshot to history (one record per run).
    python3 -c "import json; print(json.dumps(json.load(open('$json_tmp'))))" \
      >> "$LOG_DIR/baseline.jsonl" 2>/dev/null || true
    prune_history "$LOG_DIR/baseline.jsonl" "$NETDIAG_KEEP_HISTORY"
  fi
  # Prune logs regardless of the baseline flags — a --no-baseline run still
  # wrote a log file, and the watcher is the thing that accumulates them.
  prune_logs "$NETDIAG_KEEP_LOGS"

  # Timing breakdown: only useful to someone already reading the detailed
  # sections, and it's the evidence for the spec's runtime budget.
  if [ "$EXPERT" -eq 1 ] && [ "$JSON_MODE" -eq 0 ] && [ -n "$TIMING_LINES" ]; then
    hdr "Timing"
    printf '%s' "$TIMING_LINES" \
      | awk -F'|' '{printf "      %-16s %6.2f s\n", $1, $2}' \
      | log_pipe
    info "total: $(run_elapsed_s) s (budget: $([ "$QUICK" -eq 1 ] && echo 8 || echo 30) s)"
  fi

  if [ "$JSON_MODE" -eq 1 ]; then
    cat "$json_tmp"
  elif [ "$WATCH_CHILD" -eq 0 ]; then
    say ""
    # Hint about --expert only when we suppressed the section bodies AND
    # the user didn't already ask for the minimal output.
    if [ "$EXPERT" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
      say "${C_DIM}Pass --expert to see the underlying measurements.${C_RESET}"
    fi
    say "${C_DIM}Report saved to: $LOG${C_RESET}"
  fi
  rm -f "$json_tmp"
}
