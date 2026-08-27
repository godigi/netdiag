# shellcheck shell=bash
# lib/public.sh — public reach via ifconfig.co, captive-portal sniff,
# optional TARGET-specific ping.
#
# Reads:  TARGET
# Writes: PUBLIC_OK, PUB_IP, PUB_ASN, PUB_ISP, PUB_CITY, PUB_CC,
#         CAPTIVE_PORTAL, CAPTIVE_PORTAL_CODE, TARGET_PING_LOSS,
#         TARGET_PING_RTT
# Entry:  public_run

# Writes PUBLIC_OK, PUB_*, CAPTIVE_PORTAL, TARGET_PING_* — all read in
# diagnosis.sh / output.sh / emit_json.py.
# shellcheck disable=SC2034
public_run() {
  hdr "Public reachability"
  PUBLIC_CHECKED=1
  local pub_out
  pub_out="$(curl -4 -s -m 4 https://ifconfig.co/json 2>/dev/null || curl -s -m 4 https://ifconfig.co/json 2>/dev/null)"
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

  # Captive portal sniff. The body is captured, not discarded: a portal
  # answering 200 with its login page is the common case and is invisible
  # in the status alone — see captive_portal_classify in lib/common.sh.
  # No -L: a followed redirect lands on the portal's own 200 and erases
  # the evidence.
  local captive_raw captive_code captive_body
  captive_raw="$(curl -s -m 3 -w '\n%{http_code}' \
    http://captive.apple.com/hotspot-detect.html 2>/dev/null)"
  captive_code="${captive_raw##*$'\n'}"
  captive_body="${captive_raw%$'\n'*}"
  # One classifier shared with the live monitor — see lib/common.sh — so a
  # scan and a between-scans sample cannot disagree about what the answer
  # means. A probe that never answered classifies "unknown" and stays
  # silent here: silence beats a guess.
  case "$(captive_portal_classify "$captive_code" "$captive_body")" in
    ok)     ok "No captive portal." ;;
    portal)
      CAPTIVE_PORTAL=1
      CAPTIVE_PORTAL_CODE="$captive_code"
      warn "Captive portal detected (HTTP $captive_code) — log in via browser."
      ;;
  esac

  # TARGET-specific ping for "this site is slow" investigations.
  if [ -n "$TARGET" ]; then
    local tp_out
    # As elsewhere, macOS ping's -t is a deadline for the entire probe. Use
    # the shared outer timeout so the target probe sends all five packets.
    tp_out="$(with_timeout 8 ping -c 5 -i 0.2 "$TARGET" 2>/dev/null || true)"
    local tp_parsed
    tp_parsed="$(ping_parse_summary "$tp_out")"
    IFS='|' read -r TARGET_PING_LOSS TARGET_PING_RTT _ <<<"$tp_parsed"
    if [ -n "$TARGET_PING_RTT" ]; then
      ok "ping $TARGET: ${TARGET_PING_LOSS:-?}% loss, ${TARGET_PING_RTT} ms avg"
    else
      bad "ping $TARGET: no reply"
    fi
  fi
}
