# shellcheck shell=bash
# lib/traceroute.sh — traceroute to 1.1.1.1, plus an optional second
# traceroute to $TARGET when supplied.
#
# Reads:  TARGET, QUICK
# Writes: HOPS, TRACE_LINES, TARGET_TRACE_LINES
# Entry:  traceroute_run

_parse_trace_lines() {
  # Reads traceroute -n output on stdin, prints "n|ip|rtt_ms" per resolved hop.
  # macOS traceroute writes the "traceroute to ...," banner to stderr, so
  # when stderr is redirected (the common case) the banner doesn't appear
  # here. Skip it defensively anyway in case stderr is left attached.
  awk '
    $1 == "traceroute" { next }
    {
      ip = ""; rtt = ""
      for (i = 1; i <= NF; i++) {
        if (ip == "" && $i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip = $i
        else if (rtt == "" && $i ~ /^[0-9]+\.[0-9]+$/) rtt = $i
      }
      if (ip != "") {
        n++
        print n "|" ip "|" rtt
      }
    }'
}

traceroute_run() {
  hdr "Traceroute to 1.1.1.1"
  local trace_out parsed line ip
  trace_out="$(with_timeout 25 traceroute -n -q 1 -w 2 -m 18 1.1.1.1 2>/dev/null)"
  printf '%s\n' "$trace_out" | log_pipe | sed 's/^/  /'
  parsed="$(printf '%s\n' "$trace_out" | _parse_trace_lines)"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ip="${line#*|}"; ip="${ip%%|*}"
    HOPS+=("$ip")
    TRACE_LINES+="${line}"$'\n'
  done <<<"$parsed"

  # Second traceroute to TARGET when supplied. Skipped under --quick because an
  # 18-hop traceroute with -w 2 can take ~15 s in the worst case.
  if [ -n "$TARGET" ] && [ "$QUICK" -eq 0 ]; then
    hdr "Traceroute to $TARGET"
    local tt_out
    tt_out="$(with_timeout 25 traceroute -n -q 1 -w 2 -m 18 "$TARGET" 2>/dev/null)"
    printf '%s\n' "$tt_out" | log_pipe | sed 's/^/  /'
    parsed="$(printf '%s\n' "$tt_out" | _parse_trace_lines)"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      TARGET_TRACE_LINES+="${line}"$'\n'
    done <<<"$parsed"
  fi
}
