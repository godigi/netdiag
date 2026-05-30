# shellcheck shell=bash
# lib/mtu.sh — path MTU black-hole probe via DF-set pings.
#
# Walks payload sizes downward with the DF bit set, looking for the largest
# packet that gets a reply. An MTU below 1500 with otherwise healthy
# connectivity is the classic cause of "some sites work, others hang."
#
# Reads:  QUICK, PUBLIC_OK
# Writes: MTU_PATH_SIZE, MTU_EFFECTIVE
# Entry:  mtu_run

mtu_run() {
  [ "$QUICK" -eq 0 ]     || return 0
  [ "$PUBLIC_OK" -eq 1 ] || return 0

  hdr "Path MTU (DF-set probe to 1.1.1.1)"
  local size
  for size in 1472 1452 1432 1412 1392 1372 1352 1300 1200; do
    if ping -D -c 1 -t 2 -s "$size" 1.1.1.1 >/dev/null 2>&1; then
      MTU_PATH_SIZE="$size"
      break
    fi
  done
  if [ -n "$MTU_PATH_SIZE" ]; then
    MTU_EFFECTIVE=$((MTU_PATH_SIZE + 28))
    if [ "$MTU_EFFECTIVE" -ge 1500 ]; then
      ok "Effective path MTU: ${MTU_EFFECTIVE} (full ethernet frames pass DF)"
    else
      warn "Effective path MTU: ${MTU_EFFECTIVE} (< 1500) — likely PPPoE / VPN / tunnel clamp."
    fi
  else
    bad "PMTU probe: even 1228-byte frames fail with DF. Severe MTU issue or DF stripped."
  fi
}
