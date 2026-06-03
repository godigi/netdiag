# shellcheck shell=bash
# lib/hosts.sh — sanity-check /etc/hosts.
#
# macOS ships a default /etc/hosts containing only the standard loopback
# and broadcast entries. Anything beyond that is user / admin / installer
# additions. Most are benign (dev shortcuts, vagrant boxes, work intranet),
# but two patterns are worth flagging:
#   1. A well-known consumer service domain (facebook.com, google.com, etc.)
#      mapped to 127.0.0.1 or 0.0.0.0 — that's a parental-control tool, an
#      ad-blocker, or in rare cases malware redirecting traffic.
#   2. A well-known service domain mapped to a random non-loopback IP —
#      suspicious; could be a phishing redirect.
#
# Reads:  (nothing)
# Writes: HOSTS_CUSTOM_COUNT, HOSTS_SUSPICIOUS_LINES
# Entry:  hosts_run
#
# Cheap (file read + grep). Parallel-safe.

hosts_run() {
  hdr "Hosts file (/etc/hosts)"

  if [ ! -r /etc/hosts ]; then
    warn "/etc/hosts not readable."
    return 0
  fi

  # Lines that aren't comments, aren't blank, and aren't the standard
  # macOS-default entries. The default file maps 127.0.0.1/::1 to
  # localhost and 255.255.255.255 to broadcasthost.
  local custom_lines
  custom_lines="$(awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    /^127\.0\.0\.1[[:space:]]+localhost[[:space:]]*$/ {next}
    /^255\.255\.255\.255[[:space:]]+broadcasthost[[:space:]]*$/ {next}
    /^::1[[:space:]]+localhost[[:space:]]*$/ {next}
    /^fe80::1%lo0[[:space:]]+localhost[[:space:]]*$/ {next}
    {print}
  ' /etc/hosts 2>/dev/null)"

  HOSTS_CUSTOM_COUNT="$(printf '%s\n' "$custom_lines" | grep -c . || true)"
  HOSTS_CUSTOM_COUNT="${HOSTS_CUSTOM_COUNT:-0}"

  # Suspicious-redirect detector: a well-known consumer domain mapped to
  # loopback or a non-routable IP. Mostly catches ad-blockers / parental
  # controls; not an alarm by itself, but worth surfacing.
  local well_known_pattern='(facebook|instagram|tiktok|youtube|google|gmail|twitter|reddit|netflix|amazon|apple|microsoft|github)\.com'
  HOSTS_SUSPICIOUS_LINES="$(printf '%s\n' "$custom_lines" \
    | grep -Ei "^[[:space:]]*(127\.0\.0\.1|0\.0\.0\.0|::1)[[:space:]]+.*${well_known_pattern}" \
    || true)"

  if [ "$HOSTS_CUSTOM_COUNT" -eq 0 ]; then
    ok "/etc/hosts is clean (only the macOS defaults)."
  else
    info "$HOSTS_CUSTOM_COUNT custom entries in /etc/hosts."
    # Show up to 5 entries in expert mode (info() honors the gating).
    printf '%s\n' "$custom_lines" | head -5 | sed 's/^/      /' | log_pipe
    if [ -n "$HOSTS_SUSPICIOUS_LINES" ]; then
      local n
      n="$(printf '%s\n' "$HOSTS_SUSPICIOUS_LINES" | grep -c .)"
      warn "$n entr$([ "$n" -eq 1 ] && echo "y" || echo "ies") redirect a well-known service to loopback — likely an ad-blocker or parental-control tool, but worth confirming."
    fi
  fi

  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    setvar HOSTS_CUSTOM_COUNT "$HOSTS_CUSTOM_COUNT"
    setvar HOSTS_SUSPICIOUS_LINES "$HOSTS_SUSPICIOUS_LINES"
  fi
}
