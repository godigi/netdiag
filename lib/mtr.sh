# shellcheck shell=bash
# lib/mtr.sh — per-hop loss measurement. Prefers `mtr -j -c 60 -i 0.2`
# under sudo (60 cycles for continuous-loss view); falls back to a
# parallel 5-packet-per-hop loop when mtr/jq/sudo are unavailable.
#
# Reads:  QUICK, HOPS
# Writes: PER_HOP_LINES, NEXTHOP_LOSS, MTR_FIRST_LOSSY_HOP
# Entry:  mtr_run

# NEXTHOP_LOSS is declared in globals.sh and is reserved for upcoming JSON
# / baseline support — currently set but not yet read elsewhere.
# shellcheck disable=SC2034

# Threshold above which a hop's loss% is "interesting" (vs measurement noise).
_MTR_LOSS_THRESHOLD=2

# Classify a hop as "rate_limited" when its loss exceeds the threshold but
# at least one downstream hop is healthy — that means data is making it
# through, so the loss is the router refusing to send ICMP TTL-Exceeded
# replies fast enough, not a real forwarding failure. Real loss propagates
# to every hop past the bad one.
#
# Args: $1 = current hop's loss%, $2... = downstream hops' loss%s.
# Echoes: "rate_limited" or empty string.
_classify_hop_loss() {
  local cur_loss="$1"; shift
  awk -v l="$cur_loss" -v t="$_MTR_LOSS_THRESHOLD" 'BEGIN{exit !(l+0 > t)}' \
    || { printf ''; return; }
  local d
  for d in "$@"; do
    if awk -v l="$d" -v t="$_MTR_LOSS_THRESHOLD" 'BEGIN{exit !(l+0 <= t)}'; then
      printf 'rate_limited'
      return
    fi
  done
  printf ''
}

# Walk the collected hop arrays (HOP_NUMS, HOP_IPS, HOP_LOSSES, HOP_AVGS),
# tag rate-limited hops, emit PER_HOP_LINES, print them in the right severity,
# and set MTR_FIRST_LOSSY_HOP only when loss is real (propagates downstream).
_emit_per_hop_results() {
  local n total status hop_line avg_disp
  total=${#HOP_NUMS[@]}
  for ((n=0; n<total; n++)); do
    status="$(_classify_hop_loss "${HOP_LOSSES[$n]}" "${HOP_LOSSES[@]:$((n+1))}")"
    PER_HOP_LINES+="${HOP_NUMS[$n]}|${HOP_IPS[$n]}|${HOP_LOSSES[$n]}|${HOP_AVGS[$n]}"$'\n'
    avg_disp="${HOP_AVGS[$n]:-?}"
    hop_line="$(printf 'hop %2d  %-15s  %5s%% loss  %7s ms' \
      "${HOP_NUMS[$n]}" "${HOP_IPS[$n]}" "${HOP_LOSSES[$n]:-?}" "$avg_disp")"
    if awk -v l="${HOP_LOSSES[$n]}" -v t="$_MTR_LOSS_THRESHOLD" 'BEGIN{exit !(l+0 > t)}'; then
      if [ "$status" = "rate_limited" ]; then
        # Downstream is healthy; this hop just deprioritises ICMP TTL replies.
        info "$hop_line  (likely ICMP rate-limit, downstream is clean)"
      else
        warn "$hop_line"
        [ -z "$MTR_FIRST_LOSSY_HOP" ] && \
          MTR_FIRST_LOSSY_HOP="hop ${HOP_NUMS[$n]} (${HOP_IPS[$n]})"
      fi
    else
      info "$hop_line"
    fi
  done
  [ -n "$MTR_FIRST_LOSSY_HOP" ] && warn "First lossy hop: $MTR_FIRST_LOSSY_HOP"
  return 0
}

_run_per_hop_fallback() {
  if [ "${#HOPS[@]}" -eq 0 ]; then
    info "No hops to test (traceroute returned no IPs)."
    return
  fi
  # Fire all hop pings concurrently to one temp file per hop, then collect in
  # original hop order. Bounded by the slowest hop (~1-2 s) rather than the
  # sum (~12 s for 8 hops).
  local hop_tmp i h out loss lat
  hop_tmp="$(mktemp -d "${TMPDIR:-/tmp}/netdiag-hops.XXXXXX")"
  i=0
  # Track each ping's PID so we wait only on our own children, not on
  # the progress-spinner the orchestrator may have forked.
  local ping_pids=()
  for h in "${HOPS[@]}"; do
    i=$((i+1))
    ping -c 5 -t 2 -i 0.2 "$h" > "$hop_tmp/hop-$i" 2>&1 &
    ping_pids+=("$!")
  done
  local pid
  for pid in "${ping_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  HOP_NUMS=(); HOP_IPS=(); HOP_LOSSES=(); HOP_AVGS=()
  i=0
  for h in "${HOPS[@]}"; do
    i=$((i+1))
    out="$(cat "$hop_tmp/hop-$i" 2>/dev/null)"
    loss="$(printf '%s\n' "$out" | awk -F'[ %]' '/packet loss/{for(j=1;j<=NF;j++)if($j=="packet")print $(j-2)}' | head -1)"
    lat="$(printf '%s\n' "$out" | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3)}' | head -1)"
    HOP_NUMS+=("$i")
    HOP_IPS+=("$h")
    HOP_LOSSES+=("${loss:-100}")
    HOP_AVGS+=("${lat:-}")
    # NEXTHOP_LOSS tracks hop 2's loss for legacy JSON consumers.
    if [ "$i" -eq 2 ] && [ -n "$loss" ] && [ "${loss%.*}" -gt 0 ]; then
      NEXTHOP_LOSS="$loss"
    fi
  done
  rm -rf "$hop_tmp"
  _emit_per_hop_results
}

# Parse mtr's TSV (hopnum<TAB>host<TAB>loss%<TAB>avg) into the HOP_* arrays
# and emit. Designed to be called directly from tests with fixture data.
parse_mtr_tsv() {
  local hopnum host loss avg
  HOP_NUMS=(); HOP_IPS=(); HOP_LOSSES=(); HOP_AVGS=()
  while IFS=$'\t' read -r hopnum host loss avg; do
    [ -z "$hopnum" ] && continue
    HOP_NUMS+=("$hopnum")
    HOP_IPS+=("$host")
    HOP_LOSSES+=("$loss")
    HOP_AVGS+=("$avg")
  done
  _emit_per_hop_results
}

mtr_run() {
  [ "$QUICK" -eq 0 ] || return 0

  if command -v mtr >/dev/null 2>&1 && sudo -n true 2>/dev/null && command -v jq >/dev/null 2>&1; then
    hdr "Continuous loss to 1.1.1.1 (mtr -j -c 60 -i 0.2)"
    local mtr_json mtr_tsv
    mtr_json="$(with_timeout 20 sudo -n mtr -j -c 60 -n -i 0.2 1.1.1.1 2>/dev/null || true)"
    printf '%s\n' "$mtr_json" >> "$LOG"
    if [ -z "$mtr_json" ] || ! printf '%s' "$mtr_json" | jq -e .report >/dev/null 2>&1; then
      warn "mtr returned no parseable report — falling back to per-hop loop."
      _run_per_hop_fallback
      return
    fi
    # TSV: hopnum, host, loss%, avg
    mtr_tsv="$(printf '%s' "$mtr_json" \
      | jq -r '.report.hubs[] | [.count, .host, (.["Loss%"]|tostring), (.Avg|tostring)] | @tsv')"
    parse_mtr_tsv <<<"$mtr_tsv"
    return
  fi

  hdr "Per-hop loss (5 packets each)"
  if ! command -v mtr >/dev/null 2>&1; then
    info "Tip: \`brew install mtr\` enables a 60-cycle continuous-loss view."
  elif ! command -v jq >/dev/null 2>&1; then
    info "Tip: \`brew install jq\` and re-run to enable the mtr-based view."
  elif ! sudo -n true 2>/dev/null; then
    info "Tip: cache sudo creds (\`sudo -v\`) and re-run for the mtr-based view."
  fi
  _run_per_hop_fallback
}
