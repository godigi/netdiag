# shellcheck shell=bash
# lib/speedtest.sh — throughput test via Ookla's `speedtest`, falling back
# to the Python `speedtest-cli`. Sequenced after bufferbloat so the two
# don't compete for the link.
#
# On by default since v0.6.0 — "is my internet slow?" is the question most
# runs are opened to settle. --no-speed opts out; --quick skips it unless
# --speed was passed explicitly.
#
# Reads:  SPEED, SPEED_EXPLICIT, NO_SPEED, QUICK, PUBLIC_OK
# Writes: SPEEDTEST_DOWN_MBPS, SPEEDTEST_UP_MBPS, SPEEDTEST_LATENCY_MS,
#         SPEEDTEST_JITTER_MS, SPEEDTEST_SERVER
# Entry:  speedtest_run

# Which speedtest implementation is on PATH, as "<flavor>:<binary>".
#
# Detection reads --version rather than trusting the filename, because the
# Python speedtest-cli package installs BOTH `speedtest-cli` and a
# `speedtest` shim. The old code took `command -v speedtest` to mean Ookla
# and passed it --format=json --accept-license --accept-gdpr, which
# speedtest-cli rejects as unrecognized arguments. Worse, the fallback sat
# in an elif on the same `command -v speedtest` test, so it could never be
# reached: every machine with only the Python tool installed reported
# "test ran but returned no result". Latent while the test was opt-in;
# a guaranteed failure on every default run once it wasn't.
#
# Ookla's banner contains "Speedtest by Ookla"; the Python tool's is
# "speedtest-cli <version>".
speedtest_flavor() {
  local v
  if command -v speedtest >/dev/null 2>&1; then
    v="$(speedtest --version 2>&1 | head -3)"
    case "$v" in
      *[Oo]okla*) printf 'ookla:speedtest' ;;
      *)          printf 'cli:speedtest' ;;
    esac
    return 0
  fi
  if command -v speedtest-cli >/dev/null 2>&1; then
    printf 'cli:speedtest-cli'
    return 0
  fi
  printf 'none:'
}

# Whether a speed test is going to happen this run. Shared with
# lib/headline.sh so the Report card can promise the result rather than
# reporting "not measured" for a test that is about to run — the card is
# printed before the test now, so it cannot simply read the result.
speedtest_will_run() {
  [ "$SPEED" -eq 1 ]     || return 1
  [ "$NO_SPEED" -eq 0 ]  || return 1
  [ "$PUBLIC_OK" -eq 1 ] || return 1
  # On by default, so --quick has to be the thing that skips it — the test
  # alone costs more wall-clock than --quick's entire budget. An explicit
  # --speed still wins, for "quick, but tell me the speed".
  if [ "$QUICK" -eq 1 ] && [ "${SPEED_EXPLICIT:-0}" -eq 0 ]; then
    return 1
  fi
  [ "$(speedtest_flavor)" != "none:" ] || return 1
  command -v jq >/dev/null 2>&1        || return 1
  return 0
}

speedtest_run() {
  [ "$SPEED" -eq 1 ]     || return 0
  [ "$NO_SPEED" -eq 0 ]  || return 0
  [ "$PUBLIC_OK" -eq 1 ] || return 0
  if [ "$QUICK" -eq 1 ] && [ "${SPEED_EXPLICIT:-0}" -eq 0 ]; then
    return 0
  fi

  hdr "Speed test"

  local flavor bin spec st_out
  spec="$(speedtest_flavor)"
  flavor="${spec%%:*}"
  bin="${spec#*:}"

  if [ "$flavor" = none ]; then
    # Missing optional dependency degrades to a hint, never a fault — it
    # says nothing about the user's network, and this now runs by default.
    info "No speedtest CLI installed, so throughput wasn't measured. Install one with: brew install speedtest (Ookla) or brew install speedtest-cli."
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    info "Speed test skipped: parsing its JSON needs jq (brew install jq)."
    return 0
  fi

  case "$flavor" in
    ookla)
      info "Running Ookla speedtest..."
      st_out="$("$bin" --format=json --accept-license --accept-gdpr 2>/dev/null || true)"
      if [ -n "$st_out" ] && printf '%s' "$st_out" | jq -e .download.bandwidth >/dev/null 2>&1; then
        # Ookla reports bytes/s; ×8/1e6 gives Mbps.
        SPEEDTEST_DOWN_MBPS="$(printf '%s' "$st_out" | jq -r '.download.bandwidth * 8 / 1000000' | awk '{printf "%.1f", $1}')"
        SPEEDTEST_UP_MBPS="$(  printf '%s' "$st_out" | jq -r '.upload.bandwidth   * 8 / 1000000' | awk '{printf "%.1f", $1}')"
        SPEEDTEST_LATENCY_MS="$(printf '%s' "$st_out" | jq -r '.ping.latency')"
        SPEEDTEST_JITTER_MS="$( printf '%s' "$st_out" | jq -r '.ping.jitter')"
        SPEEDTEST_SERVER="$(    printf '%s' "$st_out" | jq -r '.server.name')"
        ok "Down ${SPEEDTEST_DOWN_MBPS} Mbps · Up ${SPEEDTEST_UP_MBPS} Mbps · ${SPEEDTEST_LATENCY_MS} ms (jitter ${SPEEDTEST_JITTER_MS} ms)"
        info "Server: $SPEEDTEST_SERVER"
      else
        warn "Ookla speedtest failed or returned unparseable output."
      fi
      ;;
    cli)
      info "Running speedtest-cli..."
      st_out="$("$bin" --json 2>/dev/null || true)"
      if [ -n "$st_out" ] && printf '%s' "$st_out" | jq -e .download >/dev/null 2>&1; then
        # speedtest-cli reports bits/s already; only the scale changes.
        SPEEDTEST_DOWN_MBPS="$(printf '%s' "$st_out" | jq -r '.download / 1000000' | awk '{printf "%.1f", $1}')"
        SPEEDTEST_UP_MBPS="$(  printf '%s' "$st_out" | jq -r '.upload   / 1000000' | awk '{printf "%.1f", $1}')"
        SPEEDTEST_LATENCY_MS="$(printf '%s' "$st_out" | jq -r '.ping')"
        SPEEDTEST_SERVER="$(   printf '%s' "$st_out" | jq -r '.server.host')"
        ok "Down ${SPEEDTEST_DOWN_MBPS} Mbps · Up ${SPEEDTEST_UP_MBPS} Mbps · ${SPEEDTEST_LATENCY_MS} ms"
        info "Server: $SPEEDTEST_SERVER"
      else
        warn "speedtest-cli failed or returned unparseable output."
      fi
      ;;
  esac
}
