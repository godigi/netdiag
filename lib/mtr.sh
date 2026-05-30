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
_run_per_hop_fallback() {
  if [ "${#HOPS[@]}" -eq 0 ]; then
    info "No hops to test (traceroute returned no IPs)."
    return
  fi
  # Fire all hop pings concurrently to one temp file per hop, then iterate
  # in original hop order to preserve output. Bounded by the slowest hop
  # (~1-2 s) rather than the sum of all hops (~12 s for 8 hops).
  local hop_tmp i h out loss lat first_lossy=""
  hop_tmp="$(mktemp -d "${TMPDIR:-/tmp}/netdiag-hops.XXXXXX")"
  i=0
  for h in "${HOPS[@]}"; do
    i=$((i+1))
    ping -c 5 -t 2 -i 0.2 "$h" > "$hop_tmp/hop-$i" 2>&1 &
  done
  wait
  i=0
  for h in "${HOPS[@]}"; do
    i=$((i+1))
    out="$(cat "$hop_tmp/hop-$i" 2>/dev/null)"
    loss="$(printf '%s\n' "$out" | awk -F'[ %]' '/packet loss/{for(j=1;j<=NF;j++)if($j=="packet")print $(j-2)}' | head -1)"
    lat="$(printf '%s\n' "$out" | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3)}' | head -1)"
    loss="${loss:-100}"
    PER_HOP_LINES+="${i}|${h}|${loss}|${lat:-}"$'\n'
    local hop_line
    # Right-align the hop number and loss%, pad IP to 15 cols so columns line up.
    hop_line="$(printf 'hop %2d  %-15s  %5s%% loss  %7s ms' "$i" "$h" "${loss:-?}" "${lat:-?}")"
    if [ "${loss%.*}" -eq 0 ]; then
      info "$hop_line"
    else
      warn "$hop_line"
      [ -z "$first_lossy" ] && first_lossy="hop $i ($h)"
      [ "$i" -eq 2 ] && NEXTHOP_LOSS="$loss"
    fi
  done
  rm -rf "$hop_tmp"
  [ -n "$first_lossy" ] && { MTR_FIRST_LOSSY_HOP="$first_lossy"; warn "First lossy hop: $first_lossy"; }
}

# Compute MTR_FIRST_LOSSY_HOP from an mtr JSON report's TSV form.
# Reads "hopnum<TAB>host<TAB>loss%<TAB>avg" lines on stdin, writes PER_HOP_LINES
# entries, and updates MTR_FIRST_LOSSY_HOP if the previous hop had ≤ 2% loss
# and the current hop has > 2% loss. Designed so unit tests can call this
# directly with fixture data.
parse_mtr_tsv() {
  local hopnum host loss avg prev_loss=0 hop_line
  while IFS=$'\t' read -r hopnum host loss avg; do
    [ -z "$hopnum" ] && continue
    PER_HOP_LINES+="${hopnum}|${host}|${loss}|${avg}"$'\n'
    hop_line="$(printf 'hop %2d  %-15s  %5s%% loss  %7s ms avg' "$hopnum" "$host" "$loss" "$avg")"
    if awk -v l="$loss" 'BEGIN{exit !(l+0 > 2)}'; then
      warn "$hop_line"
      if [ -z "$MTR_FIRST_LOSSY_HOP" ] && awk -v p="$prev_loss" 'BEGIN{exit !(p+0 <= 2)}'; then
        MTR_FIRST_LOSSY_HOP="hop $hopnum ($host)"
      fi
    else
      info "$hop_line"
    fi
    prev_loss="$loss"
  done
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
    [ -n "$MTR_FIRST_LOSSY_HOP" ] && warn "First lossy hop (culprit): $MTR_FIRST_LOSSY_HOP"
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
