# shellcheck shell=bash
# lib/dns.sh — DNS resolution checks against system resolver + 1.1.1.1 +
# 8.8.8.8 for apple.com, cloudflare.com, and (if set) $TARGET.
#
# Reads:  TARGET, DHCP_DNS_SERVERS
# Writes: DNS_OK, DNS_LINES, SYS_RES
# Entry:  dns_run
#
# Safe to run in parallel — does not contend on the WAN link.

dns_run() {
  hdr "DNS"
  local name dns_fail=0 dns_names
  dns_check() {
    local r="$1" n="$2" o
    o="$(with_timeout 3 dig +time=2 +tries=1 +short @"$r" "$n" 2>/dev/null | head -1)"
    if [ -n "$o" ]; then
      ok "$r → $n = $o"
      DNS_LINES+="${r}|${n}|${o}|OK"$'\n'
      return 0
    fi
    bad "$r → $n FAILED"
    DNS_LINES+="${r}|${n}||FAIL"$'\n'
    return 1
  }
  SYS_RES="$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}')"
  [ -n "$SYS_RES" ] && info "System resolver: $SYS_RES"
  if [ -n "$DHCP_DNS_SERVERS" ] && [ -n "$SYS_RES" ] \
     && ! printf '%s' "$DHCP_DNS_SERVERS" | grep -qF "$SYS_RES"; then
    warn "DHCP handed out '$DHCP_DNS_SERVERS' but the system resolver is $SYS_RES — manual DNS override?"
  fi
  dns_names=( apple.com cloudflare.com )
  [ -n "$TARGET" ] && dns_names+=( "$TARGET" )
  for name in "${dns_names[@]}"; do
    if [ -n "$SYS_RES" ]; then
      dns_check "$SYS_RES" "$name" || dns_fail=$((dns_fail+1))
    fi
    dns_check 1.1.1.1 "$name" || dns_fail=$((dns_fail+1))
    dns_check 8.8.8.8 "$name" || dns_fail=$((dns_fail+1))
  done
  [ "$dns_fail" -eq 0 ] && DNS_OK=1

  # If launched via launch_parallel, persist the writes back across the
  # subshell boundary. setvar is a no-op when called from a normal sync
  # function (no NETDIAG_PAR_VARS), so this is safe either way.
  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar DNS_OK "$DNS_OK"
    setvar DNS_LINES "$DNS_LINES"
    setvar SYS_RES "$SYS_RES"
  fi
}
