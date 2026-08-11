# shellcheck shell=bash
# lib/public.sh — public reach via ifconfig.co, captive-portal sniff,
# optional TARGET-specific ping.
#
# Reads:  TARGET
# Writes: PUBLIC_OK, PUB_IP, PUB_ASN, PUB_ISP, PUB_CITY, PUB_CC,
#         CAPTIVE_PORTAL, TARGET_PING_LOSS, TARGET_PING_RTT
# Entry:  public_run

# Writes PUBLIC_OK, PUB_*, CAPTIVE_PORTAL, TARGET_PING_* — all read in
# diagnosis.sh / output.sh / emit_json.py.
# shellcheck disable=SC2034
public_run() {
  hdr "Public reachability"
  PUBLIC_CHECKED=1
  local pub_out captive
  pub_out="$(curl -s -m 4 https://ifconfig.co/json 2>/dev/null)"
  if [ -n "$pub_out" ]; then
    PUBLIC_OK=1
    PUB_IP="$(printf '%s' "$pub_out"   | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p')"
    PUB_ISP="$(printf '%s' "$pub_out"  | sed -n 's/.*"asn_org": *"\([^"]*\)".*/\1/p')"
    PUB_ASN="$(printf '%s' "$pub_out"  | sed -n 's/.*"asn": *"\([^"]*\)".*/\1/p')"
    PUB_CITY="$(printf '%s' "$pub_out" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p')"
    PUB_CC="$(printf '%s' "$pub_out"   | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p')"
    # ifconfig.co's "country" is the full name ("Brazil"); the ISO-3166
    # alpha-2 lives in a separate key. Both are kept because they answer
    # different questions: the name is what a report should read, the code
    # is what a consumer maps to a flag or a locale. Deriving one from the
    # other would mean shipping a country table in every consumer.
    PUB_CC_ISO="$(printf '%s' "$pub_out" | sed -n 's/.*"country_iso": *"\([^"]*\)".*/\1/p')"
    ok "Public IP: $PUB_IP  ($PUB_ISP, $PUB_CITY ${PUB_CC_ISO:-$PUB_CC})"
  else
    bad "Could not reach ifconfig.co — no internet, captive portal, or DNS broken."
  fi

  # Captive portal sniff
  captive="$(curl -s -m 3 -o /dev/null -w '%{http_code} %{redirect_url}' http://captive.apple.com/hotspot-detect.html 2>/dev/null)"
  if printf '%s' "$captive" | grep -q '^200'; then
    ok "No captive portal."
  elif printf '%s' "$captive" | grep -qE '^3[0-9][0-9]'; then
    CAPTIVE_PORTAL=1
    warn "Captive portal detected (HTTP $captive) — log in via browser."
  fi

  # TARGET-specific ping for "this site is slow" investigations.
  if [ -n "$TARGET" ]; then
    local tp_out
    tp_out="$(ping -c 5 -t 3 -i 0.2 "$TARGET" 2>/dev/null || true)"
    TARGET_PING_LOSS="$(printf '%s\n' "$tp_out" \
      | awk -F'[ %]' '/packet loss/{for(j=1;j<=NF;j++)if($j=="packet")print $(j-2)}' | head -1)"
    TARGET_PING_RTT="$(printf '%s\n' "$tp_out" \
      | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}')"
    if [ -n "$TARGET_PING_RTT" ]; then
      ok "ping $TARGET: ${TARGET_PING_LOSS:-?}% loss, ${TARGET_PING_RTT} ms avg"
    else
      bad "ping $TARGET: no reply"
    fi
  fi
}
