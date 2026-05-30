# shellcheck shell=bash
# lib/tcp_reach.sh — TCP/443 reachability to a fixed set of well-known
# hosts. Some networks block ICMP outright but allow TCP — a green TCP
# panel with a red ping panel means "the network is up, ICMP is just
# filtered."
#
# Reads:  TARGET
# Writes: TCP_REACH_ANY_OK, TCP_REACH_LINES
# Entry:  tcp_reach_run
#
# Safe to run in parallel — internally fans out per-target probes.

tcp_reach_run() {
  hdr "TCP reach"
  local tcp_targets entry _dup _t host port out_file
  tcp_targets=( "1.1.1.1:443" "1.1.1.1:53" "8.8.8.8:443" "github.com:443" "apple.com:443" )
  if [ -n "$TARGET" ]; then
    _dup=0
    for _t in "${tcp_targets[@]}"; do [ "$_t" = "$TARGET:443" ] && _dup=1; done
    [ "$_dup" -eq 0 ] && tcp_targets+=( "$TARGET:443" )
  fi
  local tcp_tmp
  tcp_tmp="$(mktemp -d "${TMPDIR:-/tmp}/netdiag-tcp.XXXXXX")"
  for entry in "${tcp_targets[@]}"; do
    host="${entry%:*}"; port="${entry##*:}"
    out_file="$tcp_tmp/${host//[.:\/]/_}-${port}.out"
    {
      local t0 t1 elapsed_ms
      t0="$EPOCHREALTIME"
      if with_timeout 4 nc -G 3 -z "$host" "$port" 2>/dev/null; then
        t1="$EPOCHREALTIME"
        elapsed_ms="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.0f", (b-a)*1000}')"
        printf 'OK\t%s\n' "$elapsed_ms"
      else
        printf 'FAIL\n'
      fi
    } > "$out_file" &
  done
  wait
  local status elapsed
  for entry in "${tcp_targets[@]}"; do
    host="${entry%:*}"; port="${entry##*:}"
    out_file="$tcp_tmp/${host//[.:\/]/_}-${port}.out"
    if [ ! -f "$out_file" ]; then
      warn "$host:$port  (no result captured)"
      continue
    fi
    status="$(awk '{print $1; exit}' "$out_file")"
    elapsed="$(awk '{print $2; exit}' "$out_file")"
    if [ "$status" = "OK" ]; then
      TCP_REACH_ANY_OK=1
      TCP_REACH_LINES+="${entry}|OK|${elapsed}"$'\n'
      ok "$host:$port  (${elapsed} ms)"
    else
      TCP_REACH_LINES+="${entry}|FAIL"$'\n'
      bad "$host:$port  failed"
    fi
  done
  rm -rf "$tcp_tmp"

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar TCP_REACH_ANY_OK "$TCP_REACH_ANY_OK"
    setvar TCP_REACH_LINES "$TCP_REACH_LINES"
  fi
}
