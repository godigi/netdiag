# shellcheck shell=bash
# lib/gping.sh — launch gping against gateway + traceroute hops + 1.1.1.1
# + 8.8.8.8 once the report is done. Uses `exec` to replace the netdiag
# process — anything after this never runs.
#
# Reads:  NO_GPING, GATEWAY, HOPS
# Entry:  gping_run

gping_run() {
  [ "$NO_GPING" -eq 0 ]              || return 0
  command -v gping >/dev/null 2>&1   || return 0
  # gping renders a live TUI and dies with "Device not configured (os error 6)"
  # if stdout isn't a terminal (e.g. piped through `tee`, captured to a file,
  # or run under nohup). Skip the exec in that case — the report is already done.
  [ -t 1 ]                           || return 0
  local targets=()
  [ -n "$GATEWAY" ] && targets+=("$GATEWAY")
  local h
  for h in "${HOPS[@]}"; do targets+=("$h"); done
  targets+=(1.1.1.1 8.8.8.8)
  if [ "${#targets[@]}" -gt 0 ]; then
    say ""
    say "${C_BOLD}Launching gping on ${#targets[@]} targets (Ctrl-C to exit)…${C_RESET}"
    sleep 1
    exec gping "${targets[@]}"
  fi
}
