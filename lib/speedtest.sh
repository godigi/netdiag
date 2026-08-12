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
#         SPEEDTEST_JITTER_MS, SPEEDTEST_SERVER; `speed` events on fd 3
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

# ── Ookla's stream, translated ───────────────────────────────────────────
# `speedtest --format=jsonl --progress=yes` emits one object per update:
#
#   {"type":"ping","timestamp":"…","ping":{"jitter":0.0,"latency":27.9,"progress":0.2}}
#   {"type":"download","timestamp":"…","download":{"bandwidth":1343097,"bytes":12288,"elapsed":9,"progress":0.001}}
#
# 266 of them in a 30 s test, which is the only reason a speed test can
# show real motion instead of a spinner.
#
# ── This function is a security boundary ─────────────────────────────────
# The first line of that stream is `testStart`, and it carries
# `interface.internalIp` — on a dual-stack machine that is the host's
# **public IPv6 address**, which identifies a household the way a NATed v4
# address does not. `externalIp`, `macAddr` and the server's IP are on the
# same line.
#
# So this is deny-by-default: four values are extracted **by name** and a
# new object is built from them. Nothing is passed through and nothing is
# filtered out — a filter has to enumerate what is dangerous, and it is
# wrong the day Ookla adds a field.
#
# Both extractions are also shape-constrained, which is the second half of
# the guarantee. The numeric one matches `"key":<number>` only, so a
# string-valued field can never satisfy it no matter what it is named:
# `"latency":{"iqm":…}` on a result line is an object and is skipped, while
# `"latency":29.4` on a ping line is taken. The stage extraction accepts
# only [A-Za-z], so no value it produces can carry a quote, a backslash or
# a control character into the emitted JSON.
_speedtest_number() {
  [[ "$1" =~ \"$2\"[[:space:]]*:[[:space:]]*(-?[0-9]+(\.[0-9]+)?) ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

speedtest_translate_line() {
  local line="$1" stage progress bandwidth latency mbps tenths
  [[ "$line" =~ \"type\"[[:space:]]*:[[:space:]]*\"([A-Za-z]{1,32})\" ]] || return 0
  stage="${BASH_REMATCH[1]}"
  progress="$(_speedtest_number "$line" progress || true)"
  bandwidth="$(_speedtest_number "$line" bandwidth || true)"
  latency="$(_speedtest_number "$line" latency || true)"

  # Ookla reports bytes/s; ×8/1e6 is Mbps. Done in bash arithmetic rather
  # than awk because this runs a few hundred times per test and a fork per
  # progress update would cost more than the measurement it is reporting.
  # Tenths, so the shift never loses the leading digits: 1.25 GB/s (100
  # Gbps) is 1e11 tenths, well inside int64. The half-unit added before the
  # divide rounds rather than truncates, because the final figure below is
  # rounded by awk and a live reading that lands 0.1 Mbps under the number
  # it settles on reads as a bug in whichever of the two you trust less.
  mbps=""
  if [ -n "$bandwidth" ]; then
    tenths=$(( (${bandwidth%.*} * 80 + 500000) / 1000000 ))
    mbps="$(( tenths / 10 )).$(( tenths % 10 ))"
  fi
  progress_speed "$stage" "$progress" "$mbps" "$latency"
}

speedtest_run() {
  [ "$SPEED" -eq 1 ]     || { progress_skip "speed test not requested"; return 0; }
  [ "$NO_SPEED" -eq 0 ]  || { progress_skip "--no-speed"; return 0; }
  [ "$PUBLIC_OK" -eq 1 ] || { progress_skip "no internet to test against"; return 0; }
  if [ "$QUICK" -eq 1 ] && [ "${SPEED_EXPLICIT:-0}" -eq 0 ]; then
    progress_skip "--quick"
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
    progress_skip "no speedtest CLI installed"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    info "Speed test skipped: parsing its JSON needs jq (brew install jq)."
    progress_skip "jq not installed"
    return 0
  fi

  case "$flavor" in
    ookla)
      info "Running Ookla speedtest..."
      # jsonl rather than json, and one code path rather than two: the
      # final `{"type":"result",…}` line carries exactly the object
      # --format=json would have printed on its own, so the parsing below
      # is unchanged and the streaming case is the case that gets tested.
      #
      # The loop reads from a process substitution rather than a pipe so it
      # stays in this shell — through a pipe, $st_out would be assigned in
      # a subshell and the result would be gone by the time it was parsed.
      local st_line
      st_out=""
      while IFS= read -r st_line; do
        speedtest_translate_line "$st_line"
        case "$st_line" in *'"type":"result"'*) st_out="$st_line" ;; esac
      done < <("$bin" --format=jsonl --progress=yes --accept-license --accept-gdpr 2>/dev/null || true)
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
      # No stream to translate: the Python tool prints one object when it
      # is finished. So the stage is announced with no progress fraction
      # and the result arrives at the end. A synthesised fraction here
      # would be the UI's only source of motion and it would be a lie —
      # nothing in this branch knows how far along the test is.
      progress_speed running
      st_out="$("$bin" --json 2>/dev/null || true)"
      if [ -n "$st_out" ] && printf '%s' "$st_out" | jq -e .download >/dev/null 2>&1; then
        # speedtest-cli reports bits/s already; only the scale changes.
        SPEEDTEST_DOWN_MBPS="$(printf '%s' "$st_out" | jq -r '.download / 1000000' | awk '{printf "%.1f", $1}')"
        SPEEDTEST_UP_MBPS="$(  printf '%s' "$st_out" | jq -r '.upload   / 1000000' | awk '{printf "%.1f", $1}')"
        SPEEDTEST_LATENCY_MS="$(printf '%s' "$st_out" | jq -r '.ping')"
        SPEEDTEST_SERVER="$(   printf '%s' "$st_out" | jq -r '.server.host')"
        ok "Down ${SPEEDTEST_DOWN_MBPS} Mbps · Up ${SPEEDTEST_UP_MBPS} Mbps · ${SPEEDTEST_LATENCY_MS} ms"
        info "Server: $SPEEDTEST_SERVER"
        # Still no progress fraction — the number is final, but it never
        # counted up to get here.
        progress_speed result "" "$SPEEDTEST_DOWN_MBPS" "$SPEEDTEST_LATENCY_MS"
      else
        warn "speedtest-cli failed or returned unparseable output."
      fi
      ;;
  esac
}
