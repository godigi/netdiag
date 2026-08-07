# shellcheck shell=bash
# lib/arp.sh — duplicate-IP scan + gateway-incomplete check.
#
# Parses `arp -an` output, finds IPs that show up with > 1 distinct MAC
# (duplicate-IP collision), and flags the gateway if its ARP entry is
# (incomplete) — the L2 link to the router is broken in that case.
#
# Reads:  GATEWAY
# Writes: ARP_DUPLICATE_IPS, ARP_GW_INCOMPLETE
# Entry:  arp_run

# Writes ARP_DUPLICATE_IPS, ARP_GW_INCOMPLETE — declared in globals.sh,
# read by diagnosis.sh / output.sh. shellcheck can't see cross-file usage.
# shellcheck disable=SC2034
arp_run() {
  hdr "ARP / duplicate-IP scan"
  local arp_out arp_pairs
  arp_out="$(arp -an 2>/dev/null)"
  # Parse "? (IP) at MAC ..." lines, drop "(incomplete)" entries, find IPs that
  # show up with > 1 distinct MAC.
  arp_pairs="$(printf '%s\n' "$arp_out" \
    | awk '/ at / && $4 != "(incomplete)" {
        ip = $2; gsub(/[()]/, "", ip); print ip, $4
      }' | sort -u)"
  ARP_DUPLICATE_IPS="$(printf '%s\n' "$arp_pairs" | awk '{print $1}' | uniq -d | tr '\n' ' ')"
  # The gateway's MAC is the most stable identifier a network has: it
  # survives DHCP re-leases and SSID renames, and differs between two
  # networks that happen to share a private subnet. lib/netid.sh uses it
  # to scope baseline history so moving between networks stops looking
  # like a regression.
  if [ -n "$GATEWAY" ]; then
    GW_MAC="$(printf '%s\n' "$arp_pairs" | awk -v gw="$GATEWAY" '$1==gw{print $2; exit}')"
  fi
  if [ -n "$GATEWAY" ] && printf '%s\n' "$arp_out" | grep -qF "($GATEWAY) at (incomplete)"; then
    ARP_GW_INCOMPLETE=1
    bad "Gateway $GATEWAY is (incomplete) in the ARP table — L2 broken."
  fi
  if [ -n "${ARP_DUPLICATE_IPS//[[:space:]]/}" ]; then
    bad "Duplicate IP(s) seen:"
    local dup
    for dup in $ARP_DUPLICATE_IPS; do
      printf '%s\n' "$arp_pairs" | awk -v ip="$dup" '$1==ip{print "      "$0}' | log_pipe
    done
  else
    ok "No duplicate IPs in ARP table."
  fi
}
