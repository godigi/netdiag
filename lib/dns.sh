# shellcheck shell=bash
# lib/dns.sh — DNS resolution checks against system resolver + 1.1.1.1 +
# 8.8.8.8 for apple.com, cloudflare.com, and (if set) $TARGET.
#
# Reads:  TARGET, DHCP_DNS_SERVERS
# Writes: DNS_OK, DNS_LINES, SYS_RES, SYS_RES_ALL, SYS_RES_MS, DNS_NXDOMAIN_HIJACK_IP, IPV6_DNS_FAIL
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
  # scutil prints one resolver block per scope, so the same nameserver shows
  # up several times — dedupe but keep configured order. SYS_RES stays the
  # first entry (the one dig is aimed at, scope suffix and all); SYS_RES_ALL
  # is what the DHCP comparison needs, because on a dual-stack network the
  # DHCP-handed server sits at index 1 behind the router's link-local.
  SYS_RES_ALL="$(scutil --dns 2>/dev/null \
    | awk '/nameserver\[[0-9]+\]/ && !seen[$3]++ { printf "%s%s", (n++ ? " " : ""), $3 }')"
  SYS_RES="${SYS_RES_ALL%% *}"
  [ -n "$SYS_RES_ALL" ] && info "System resolvers: $SYS_RES_ALL"
  if dns_is_manual_override "$DHCP_DNS_SERVERS" "$SYS_RES_ALL"; then
    warn "DHCP handed out '$DHCP_DNS_SERVERS' but the system is using $(dns_routable_resolvers "$SYS_RES_ALL") — manual DNS override?"
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

  # Latency check on primary system resolver
  if [ -n "$SYS_RES" ]; then
    local t0 t1 probe_ans
    t0="${EPOCHREALTIME:-}"
    probe_ans="$(with_timeout 3 dig +time=2 +tries=1 +short @"$SYS_RES" cloudflare.com 2>/dev/null | head -1 || true)"
    t1="${EPOCHREALTIME:-}"
    if [ -n "$t0" ] && [ -n "$t1" ] && [ -n "$probe_ans" ]; then
      SYS_RES_MS="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.0f", (b-a)*1000}')"
    fi
  fi

  # NXDOMAIN hijacking probe against SYS_RES
  if [ -n "$SYS_RES" ]; then
    local nx_probe="probe-nx-$$-$RANDOM-$RANDOM.example.invalid"
    local nx_ans
    nx_ans="$(with_timeout 3 dig +time=2 +tries=1 +short @"$SYS_RES" "$nx_probe" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [ -n "$nx_ans" ]; then
      DNS_NXDOMAIN_HIJACK_IP="$nx_ans"
      warn "DNS hijacking detected: $SYS_RES resolved non-existent domain $nx_probe to $nx_ans"
    fi
  fi

  # IPv6 nameserver check
  if [ -n "$SYS_RES_ALL" ]; then
    for r in $SYS_RES_ALL; do
      if [[ "$r" == *":"* ]]; then
        local v6_ans
        v6_ans="$(with_timeout 3 dig +time=2 +tries=1 +short @"$r" apple.com 2>/dev/null | head -1 || true)"
        if [ -z "$v6_ans" ]; then
          IPV6_DNS_FAIL="$r"
          warn "IPv6 DNS resolver $r is configured but not responding"
          break
        fi
      fi
    done
  fi

  # If launched via launch_parallel, persist the writes back across the
  # subshell boundary. setvar is a no-op when called from a normal sync
  # function (no NETDIAG_PAR_VARS), so this is safe either way.
  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar DNS_OK "$DNS_OK"
    setvar DNS_LINES "$DNS_LINES"
    setvar SYS_RES "$SYS_RES"
    setvar SYS_RES_ALL "$SYS_RES_ALL"
    setvar SYS_RES_MS "$SYS_RES_MS"
    setvar DNS_NXDOMAIN_HIJACK_IP "$DNS_NXDOMAIN_HIJACK_IP"
    setvar IPV6_DNS_FAIL "$IPV6_DNS_FAIL"
  fi
}
