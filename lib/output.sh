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
  NETDIAG_RUN_MODE="${RUN_MODE:-}" \
  NETDIAG_INTERFACE="$INTERFACE" \
  NETDIAG_LOCAL_IP="${LOCAL_IP:-}" \
  NETDIAG_GATEWAY="$GATEWAY" \
  NETDIAG_LINK_STATUS="${LINK_STATUS:-}" \
  NETDIAG_LINK_UP="${LINK_UP:-0}" \
  NETDIAG_LINK_SELF_ASSIGNED="${LINK_SELF_ASSIGNED:-0}" \
  NETDIAG_LINK_MEDIA_MBPS="${LINK_MEDIA_MBPS:-}" \
  NETDIAG_LINK_MEDIA_MAX_MBPS="${LINK_MEDIA_MAX_MBPS:-}" \
  NETDIAG_LINK_DUPLEX="${LINK_DUPLEX:-}" \
  NETDIAG_LINK_SERVICE="${LINK_SERVICE:-}" \
  NETDIAG_LINK_METERED="${LINK_METERED:-0}" \
  NETDIAG_LINK_DHCP_ROUTER="${LINK_DHCP_ROUTER:-}" \
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
  NETDIAG_INET_TARGET="${INET_TARGET:-}" \
  NETDIAG_INET_TARGET_ALT="${INET_TARGET_ALT:-}" \
  NETDIAG_INET_RTT_AVG_ALT="${INET_RTT_AVG_ALT:-}" \
  NETDIAG_INET_LOSS_ALT="${INET_LOSS_ALT:-}" \
  NETDIAG_HOSTS_CUSTOM_COUNT="${HOSTS_CUSTOM_COUNT:-0}" \
  NETDIAG_HOSTS_SUSPICIOUS_LINES="${HOSTS_SUSPICIOUS_LINES:-}" \
  NETDIAG_PUB_IP="$PUB_IP" \
  NETDIAG_PUB_ASN="$PUB_ASN" \
  NETDIAG_PUB_ISP="$PUB_ISP" \
  NETDIAG_PUB_CITY="$PUB_CITY" \
  NETDIAG_PUB_CC="$PUB_CC" \
  NETDIAG_PUB_CC_ISO="$PUB_CC_ISO" \
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
  NETDIAG_RUN_ELAPSED_S="${_run_elapsed_frozen:-$(run_elapsed_s)}" \
  NETDIAG_QUICK="$QUICK" \
  NETDIAG_REDACT="$REDACT" \
  python3 "$HELPERS_DIR/emit_json.py"
}

# ── The canonical, private snapshot ──────────────────────────────────────
# build_json honours $REDACT, which is right for stdout and wrong for
# everything that stays on this machine. `output_run` appended the emitted
# JSON to baseline.jsonl *after* redaction, so every `--redact` run wrote a
# record whose public IP, SSID, gateway MAC and — fatally — network.id had
# all been replaced with "[redacted]". Eleven such records exist in the
# author's own history, two of them written by v0.5.2.
#
# The damage is worse than a few masked fields. network.id is the join key
# helpers/baseline.py scopes history by, so a redacted record can never
# match a real one: it is dead weight in the file, and it drags the
# retention cap down for the records that still mean something. The GUI's
# "Copy shareable report" runs --redact, so this would have fired on every
# use.
#
# baseline.jsonl is a local, private file. Redaction exists for the copy
# that *leaves* the machine, so the comparison input, the history append,
# and the archive all read the unredacted build; only the stdout rendition
# under --json is masked, and it is built separately at the end of the run.
#
# Save/restore rather than a subshell: build_json assigns
# MOST_LIKELY_ROOT_CAUSE as a global, and a subshell would drop it.
build_json_private() {
  local _saved_redact="$REDACT"
  REDACT=0
  build_json
  REDACT="$_saved_redact"
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

# Where prune_history rolls the lines it takes off the front. Derived from
# the live file so a caller pointing at a test path gets a test archive:
# baseline.jsonl → baseline-archive.jsonl.
history_archive_path() {
  printf '%s-archive.jsonl' "${1%.jsonl}"
}

# Truncating the live history used to *delete* the oldest runs. That is the
# wrong trade for a file whose whole value is depth: at the launchd
# watcher's 15-minute cadence the 2000-line cap is about three weeks, and
# the first lines to go are always the oldest — the ones a history chart is
# for. The author's own file was at 1,968 of the 2,200 trigger when this
# was written, with 2.5 months of runs about to be discarded.
#
# So the head rolls into baseline-archive.jsonl instead. `--history` reads
# archive + live and dedupes on timestamp; helpers/baseline.py still reads
# only the live file, so the per-run comparison cost stays bounded by the
# cap while nothing is ever actually lost.
#
# The archive is deliberately uncapped. It is one line per run of a file
# that took two months to reach 5 MB, and "the retention policy quietly ate
# your history" is the failure this exists to prevent.
#
# Order matters: append to the archive first, truncate second. Crashing
# between the two duplicates records rather than dropping them, and
# helpers/history.py dedupes on timestamp precisely so that the safe
# failure is also the harmless one.
prune_history() {
  local file="$1" keep="$2" pid
  local lock="${file}.lock"
  # Appends happen before pruning, and launchd/manual runs can overlap. A
  # directory is an atomic lock on macOS; without it two pruners can each
  # archive the same head and then race their tail into the live store.
  if ! mkdir "$lock" 2>/dev/null; then
    # Recover a lock left by a killed process, but never disturb a live one.
    if [ -r "$lock/pid" ]; then
      pid="$(cat "$lock/pid" 2>/dev/null || true)"
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$lock/pid" 2>/dev/null || true
        rmdir "$lock" 2>/dev/null || true
        mkdir "$lock" 2>/dev/null || return 0
      else
        return 0
      fi
    else
      return 0
    fi
  fi
  printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
  _prune_history_locked "$file" "$keep"
  local rc=$?
  rm -f "$lock/pid" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

_prune_history_locked() {
  local file="$1" keep="$2" lines tmp archive head_lines
  [ "$keep" -gt 0 ]   || return 0
  [ -f "$file" ]      || return 0
  lines="$(wc -l < "$file" 2>/dev/null | tr -d ' ')"
  is_numeric "$lines" || return 0
  # Only rewrite when meaningfully over the cap, so the common case is a
  # single wc(1) and no file churn.
  [ "$lines" -gt $((keep + keep / 10)) ] || return 0
  head_lines=$((lines - keep))
  archive="$(history_archive_path "$file")"
  # If the archive can't be written, leave the live file alone. A history
  # that is over its cap costs a little parse time; a history whose oldest
  # runs were deleted because an append failed costs the runs.
  head -n "$head_lines" "$file" >> "$archive" 2>/dev/null || return 0
  netdiag_mktemp_dir netdiag-hist || return 0
  tmp="$NETDIAG_TMP_DIR/record"
  if tail -n "$keep" "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
  rm -rf "$NETDIAG_TMP_DIR"
  netdiag_tmp_forget "$NETDIAG_TMP_DIR"
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
  local json_tmp json_tmp_dir baseline_out baseline_lines reg
  # Frozen once, here, before the first render. Every build_json call this
  # run makes — the private snapshot below, its regression rebuild, and
  # the stdout render at the bottom — reads this same value through
  # build_json's `${_run_elapsed_frozen:-$(run_elapsed_s)}`, instead of
  # each one calling run_elapsed_s() itself and getting whatever moment it
  # happened to run at. Un-frozen, the stored record and the stdout render
  # measured different instants and so disagreed on timings.total_s (and,
  # at the boundary, over_budget) — a divergence that used to be silent
  # but that run_id now makes checkable: a consumer can follow the id from
  # stdout into the stored record and find the numbers it was just shown
  # not matching. Every render in one run now carries identical timings,
  # by construction.
  local _run_elapsed_frozen
  _run_elapsed_frozen="$(run_elapsed_s)"
  # Explicitly initialized: read unconditionally below (every JSON_MODE
  # run, not just one that appends), while only *assigned* inside the
  # HISTORY_APPEND branch — under Homebrew bash 5's `set -u`, a bare
  # `local run_id_val` is not enough to make an unconditional read of it
  # safe; the declaration has to carry a value.
  local run_id_val=""
  # Keep the private record in a registered directory so an interrupted run
  # cannot leave a network snapshot behind in the system temp directory.
  if ! netdiag_mktemp_dir netdiag-out; then
    warn "Temporary storage is unavailable; no report was written."
    [ "$JSON_MODE" -eq 1 ] && build_json
    return 0
  fi
  json_tmp_dir="$NETDIAG_TMP_DIR"
  json_tmp="$json_tmp_dir/record.json"
  # Unredacted throughout: this file feeds the baseline comparison and the
  # history append, both of which are local and both of which need the real
  # network.id to be worth anything. See build_json_private.
  build_json_private > "$json_tmp"

  # Baseline comparison: compare current JSON to history, surface any
  # regressions, then rebuild the JSON so they appear in its diagnosis array.
  #
  # Comparing and appending are separate conditions. --quick skips the
  # *comparison* per the spec's 8 s budget: it costs two python3 starts plus
  # a full parse of baseline.jsonl, which is the most expensive thing left
  # in a quick run. It still appends below, so the launchd watcher — which
  # runs --quick — keeps building the history that full runs are measured
  # against. --speed-only is the same trade for a different reason: its
  # numbers are worth storing and its verdict is not worth comparing.
  if [ "$NO_BASELINE" -eq 0 ] && [ "$BASELINE" -eq 1 ] && [ "$QUICK" -eq 0 ]; then
    mkdir -p "$LOG_DIR"
    # THRESH_SPEED_* judge a speedtest drop the same way THRESH_COMPARE_*
    # judge a --show comparison: through the environment, from
    # lib/thresholds.sh, because a cutoff that decides whether a number is
    # normal lives in exactly one place. baseline.py refuses to run without
    # them rather than carrying a default.
    export THRESH_SPEED_DROP_FACTOR THRESH_SPEED_CONFIRM_RUNS
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
" 2>/dev/null || true)"
      if [ -n "$baseline_lines" ]; then
        while IFS= read -r reg; do
          [ -z "$reg" ] && continue
          add_diag warn BL-1 "Something changed since your last runs: $reg"
          DIAGNOSIS_LINES+="warn|BL-1|Something changed since your last runs: $reg"$'\n'
          warn "Something changed since your last runs: $reg"
        done <<<"$baseline_lines"
        # Rebuild JSON now that DIAGNOSIS_LINES has the regressions.
        build_json_private > "$json_tmp"
      fi
    fi
  fi
  # Append final snapshot to history (one record per run). Every record
  # carries run_mode, so a consumer can tell a full check from a spot one
  # instead of counting them alike.
  if [ "$HISTORY_APPEND" -eq 1 ]; then
    mkdir -p "$LOG_DIR"
    # One python3 invocation computes the id AND performs the append, and
    # prints the id only once the append has actually landed. This used to
    # be two calls — compute the id here, append the record there — which
    # let the id "succeed" independently of the write it names: an append
    # failure (a store path that went unwritable mid-run, a full disk)
    # still left run_id_val holding a real-looking id pointing at a record
    # that was never written, so `--show` on it exits 3. That was the
    # hazard, not a safety property; computing and appending together
    # means the id and the record it names now either both exist or
    # neither does.
    #
    # canonical()/run_id() are imported from helpers/history.py rather
    # than reimplemented, so this id and the one --history derives later
    # from the stored bytes can never disagree. json_tmp, the store path,
    # and HELPERS_DIR are passed as sys.argv rather than interpolated into
    # the python source string: an apostrophe anywhere in an install path
    # (a user's home directory, a Homebrew prefix) used to land inside a
    # single-quoted Python string literal and produce a silent
    # SyntaxError, swallowed by 2>/dev/null.
    #
    # A failure anywhere in the script (no python3, an unreadable
    # $json_tmp, an unwritable store path) means nothing is printed before
    # the failure, leaving run_id_val empty — which reaches emit_json.py
    # as a set-but-empty NETDIAG_RUN_ID (present in the environment, empty
    # string), not an unset one: _env() folds "" to None exactly as it
    # would an unset var, so it still renders as `"run_id": null`, per the
    # every-key-present convention the rest of this JSON follows. The
    # overall `|| true` keeps an append failure from ever killing the run.
    run_id_val="$(python3 -c '
import json, sys

json_tmp, store_path, helpers_dir = sys.argv[1:4]
sys.path.insert(0, helpers_dir)
from history import canonical, run_id

rec = json.load(open(json_tmp))
rid = run_id(str(rec.get("timestamp") or ""), canonical(rec))
with open(store_path, "a") as f:
    f.write(json.dumps(rec) + "\n")
print(rid)
' "$json_tmp" "$LOG_DIR/baseline.jsonl" "$HELPERS_DIR" 2>/dev/null || true)"
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
    info "total: ${_run_elapsed_frozen:-$(run_elapsed_s)} s (budget: $([ "$QUICK" -eq 1 ] && echo 8 || echo 30) s)"
  fi

  if [ "$JSON_MODE" -eq 1 ]; then
    # A second render, always — not a copy of $json_tmp. run_id must appear
    # on stdout but must never appear in the bytes that were appended to
    # baseline.jsonl above (history.py derives the id from exactly those
    # bytes), so the build that carries it can't be the build that was
    # stored. build_json already honours $REDACT, so this one call is
    # correct whether or not --redact was passed; see emit_json.py's
    # redact() for why it also nulls run_id specifically rather than
    # letting the ordinary secret-scrub handle it. timings.total_s is
    # frozen (see _run_elapsed_frozen at the top of this function), so
    # this render's timings match the stored record's exactly — run_id
    # isn't the only thing this render and that record now agree on.
    #
    # Rendered straight to stdout rather than rereading the private record:
    # that record intentionally omits run_id, while the public render carries
    # it without changing the bytes history.py hashes.
    NETDIAG_RUN_ID="$run_id_val" build_json
  elif [ "$WATCH_CHILD" -eq 0 ]; then
    say ""
    # Hint about --expert only when we suppressed the section bodies AND
    # the user didn't already ask for the minimal output.
    if [ "$EXPERT" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
      say "${C_DIM}Pass --expert to see the underlying measurements.${C_RESET}"
    fi
    say "${C_DIM}Report saved to: $LOG${C_RESET}"
  fi
  rm -rf "$json_tmp_dir"
  netdiag_tmp_forget "$json_tmp_dir"
}
