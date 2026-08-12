# shellcheck shell=bash
# lib/traceroute.sh — traceroute to 1.1.1.1, plus an optional second
# traceroute to $TARGET when supplied.
#
# Reads:  TARGET, QUICK
# Writes: HOPS, TRACE_LINES, TARGET_TRACE_LINES
# Entry:  traceroute_run

_parse_trace_lines() {
  # Reads traceroute -n output on stdin, prints "n|ip|rtt_ms" per hop.
  #
  # `n` is traceroute's OWN hop number, not a running count of replies.
  # Counting replies renumbered every hop after a `* * *` timeout, so the
  # JSON disagreed with what the user sees running traceroute by hand —
  # and, worse, it closed the gap in the hop list, which made two private
  # hops separated by a timeout look adjacent and could trip the
  # double-NAT walker on an unknown hop.
  #
  # Non-responding hops are emitted with an empty ip ("7||") so the
  # sequence stays honest about where the gaps are. Callers must skip
  # empty-ip rows when they need a pingable address.
  #
  # macOS traceroute writes the "traceroute to ...," banner to stderr, so
  # when stderr is redirected (the common case) the banner doesn't appear
  # here. Skip it defensively anyway in case stderr is left attached.
  awk '
    $1 == "traceroute" { next }
    $1 ~ /^[0-9]+$/ {
      ip = ""; rtt = ""
      # Start at field 2: field 1 is the hop number and must never be
      # mistaken for an address or a timing.
      for (i = 2; i <= NF; i++) {
        if (ip == "" && $i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip = $i
        else if (ip != "" && rtt == "" && $i ~ /^[0-9]+\.[0-9]+$/) rtt = $i
      }
      print $1 "|" ip "|" rtt
    }'
}

traceroute_run() {
  # --quick budget can't accommodate the 18-hop default traceroute. The
  # side effect: NAT-1 (double-NAT) won't fire under --quick because it
  # needs TRACE_LINES. Acceptable trade for hitting the 8 s budget.
  [ "$QUICK" -eq 0 ] || { progress_skip "--quick"; return 0; }
  hdr "Traceroute to 1.1.1.1"
  local trace_out parsed line ip
  trace_out="$(with_timeout 25 traceroute -n -q 1 -w 2 -m 18 1.1.1.1 2>/dev/null)"
  # Indent BEFORE log_pipe: log_pipe is the terminal stage of the pipeline.
  # With the order reversed the log got un-indented text, and in compact
  # mode log_pipe swallows stdout entirely so `sed` ran on empty input.
  printf '%s\n' "$trace_out" | sed 's/^/  /' | log_pipe
  parsed="$(printf '%s\n' "$trace_out" | _parse_trace_lines)"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ip="${line#*|}"; ip="${ip%%|*}"
    # TRACE_LINES keeps every hop including the timeouts; HOPS is the
    # pingable subset (mtr fallback and gping both need real addresses).
    [ -n "$ip" ] && HOPS+=("$ip")
    TRACE_LINES+="${line}"$'\n'
  done <<<"$parsed"

  # Second traceroute to TARGET when supplied. Skipped under --quick because an
  # 18-hop traceroute with -w 2 can take ~15 s in the worst case.
  if [ -n "$TARGET" ] && [ "$QUICK" -eq 0 ]; then
    hdr "Traceroute to $TARGET"
    local tt_out
    tt_out="$(with_timeout 25 traceroute -n -q 1 -w 2 -m 18 "$TARGET" 2>/dev/null)"
    printf '%s\n' "$tt_out" | sed 's/^/  /' | log_pipe
    parsed="$(printf '%s\n' "$tt_out" | _parse_trace_lines)"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      TARGET_TRACE_LINES+="${line}"$'\n'
    done <<<"$parsed"
  fi
}
