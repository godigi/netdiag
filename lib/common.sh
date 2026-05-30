# shellcheck shell=bash
# lib/common.sh — shared infrastructure: globals, printing, diagnosis
# accumulator, timeout wrapper, parallel-launch helpers.
#
# Sourced once from bin/netdiag after argparse has set $JSON_MODE, $QUIET,
# $QUICK, $TARGET, $LOG, etc. Every module file expects these to be set.
#
# Entry points used elsewhere:
#   say/hdr/ok/warn/bad/info     — colour-aware printing (writes to $LOG too)
#   log_pipe                     — pipeline target equivalent to `tee -a $LOG`
#   add_diag <sev> <msg>         — append a diagnosis, update $MAX_SEVERITY
#   grade_bufferbloat <delta_ms> — A/B/C/D/F from the Waveform thresholds
#   with_timeout <secs> <cmd...> — kill cmd if it runs past secs; returns 124
#   launch_parallel <name> <fn>  — fan out a check; results collected later
#   collect_parallel             — fan in: print buffers, source variable files
#   setvar <name> <value>        — persist a var across the parallel boundary

# ── Colours ──────────────────────────────────────────────────────────────
# Suppressed under --json or --quiet (stdout consumers don't want them).
if [ "$JSON_MODE" -eq 0 ] && [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=; C_BOLD=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=
fi

# ── Printing ─────────────────────────────────────────────────────────────
# Stdout gating: print iff not JSON_MODE and (not QUIET OR past the Diagnosis
# header). The log gets ANSI-stripped raw text either way.
DIAGNOSIS_REACHED=0
say() {
  if [ "$JSON_MODE" -eq 0 ] && \
     { [ "$QUIET" -eq 0 ] || [ "$DIAGNOSIS_REACHED" -eq 1 ]; }; then
    printf '%s\n' "$*"
  fi
  printf '%s\n' "$*" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOG"
}
hdr() {
  # "Summary" and "Diagnosis" both count as having reached the
  # human-facing punchline — flip the QUIET gate so both show under --quiet.
  case "$*" in
    Diagnosis*|Summary*) DIAGNOSIS_REACHED=1 ;;
  esac
  say ""
  say "${C_BOLD}${C_BLU}── $* ──${C_RESET}"
}
ok()   { say "  ${C_GRN}✓${C_RESET} $*"; }
warn() { say "  ${C_YEL}⚠${C_RESET} $*"; }
bad()  { say "  ${C_RED}✗${C_RESET} $*"; }
info() { say "  ${C_DIM}·${C_RESET} $*"; }

# Pipeline-target replacement for `tee -a "$LOG"`. Writes to log unconditionally;
# also writes to stdout iff not JSON_MODE and not pre-diagnosis QUIET.
log_pipe() {
  if [ "$JSON_MODE" -eq 0 ] && \
     { [ "$QUIET" -eq 0 ] || [ "$DIAGNOSIS_REACHED" -eq 1 ]; }; then
    tee -a "$LOG"
  else
    cat >> "$LOG"
  fi
}

# ── Diagnosis accumulator ────────────────────────────────────────────────
DIAG=()
DIAG_SEV=()
MAX_SEVERITY=0  # exit code on a clean run: 0=healthy, 1=warn, 2=critical
# Severity tiers:
#   info     — heads-up only, doesn't bump exit code
#   warn     — exit 1 if nothing more severe was seen
#   critical — exit 2
add_diag() {
  local sev="$1"; shift
  DIAG+=("$*")
  DIAG_SEV+=("$sev")
  case "$sev" in
    critical) [ "$MAX_SEVERITY" -lt 2 ] && MAX_SEVERITY=2 ;;
    warn)     [ "$MAX_SEVERITY" -lt 1 ] && MAX_SEVERITY=1 ;;
  esac
}

# ── Bufferbloat grading ──────────────────────────────────────────────────
# Waveform/DSLReports thresholds: A < +5ms, B < +30ms, C < +60ms,
# D < +200ms, F ≥ +200ms.
grade_bufferbloat() {
  awk -v d="$1" 'BEGIN{
    if (d+0 < 5)   { print "A"; exit }
    if (d+0 < 30)  { print "B"; exit }
    if (d+0 < 60)  { print "C"; exit }
    if (d+0 < 200) { print "D"; exit }
    print "F";
  }'
}

# ── Timeout wrapper ──────────────────────────────────────────────────────
# Run a command with a wall-clock timeout. Returns the command's exit code,
# or 124 if killed by timeout (matches GNU timeout(1)). stdout/stderr pass
# through, so $(with_timeout 3 dig +short ...) works as a drop-in.
#
# Subtlety: the killer subshell's stdout/stderr are forced to /dev/null
# so its orphaned `sleep` child can't pin open the command-substitution
# pipe — otherwise $() would block for the full timeout duration even
# after the wrapped command completed.
with_timeout() {
  local secs="$1"; shift
  ( "$@" ) &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local killer_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  kill -TERM "$killer_pid" 2>/dev/null
  wait "$killer_pid" 2>/dev/null
  if [ "$rc" -gt 128 ]; then return 124; fi
  return "$rc"
}

# ── Parallel-launch helpers ──────────────────────────────────────────────
# Fan out: each parallel check runs as a subshell, with its stdout buffered
# to a per-check file and any variables it wants to persist appended to a
# per-check vars file. Fan in: collect_parallel iterates in launch order,
# printing the stdout buffer to terminal+LOG and sourcing the vars file.
#
# Inside a parallel-launched function, callers MUST:
#   - use say/hdr/ok/warn/info as usual (they're overridden to buffer-only)
#   - call setvar NAME "value" to persist a variable across the boundary
PAR_NAMES=()
PAR_TMP=""
launch_parallel() {
  local name="$1" fn="$2"
  if [ -z "$PAR_TMP" ]; then
    PAR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/netdiag-par.XXXXXX")"
  fi
  PAR_NAMES+=("$name")
  # The subshell below intentionally redefines say/hdr/etc. The launched
  # function $fn invokes them via name resolution at call time, so SC2329
  # ("function never invoked") is a false positive. SC2030 / SC2031 on
  # NETDIAG_PAR_OUT/PAR_VARS are by design — they're scoped to the
  # subshell on purpose so each parallel check writes its own files.
  # shellcheck disable=SC2030
  (
    NETDIAG_PAR_OUT="$PAR_TMP/$name.out"
    NETDIAG_PAR_VARS="$PAR_TMP/$name.vars"
    : >"$NETDIAG_PAR_OUT"
    : >"$NETDIAG_PAR_VARS"
    exec 1>"$NETDIAG_PAR_OUT" 2>&1
    # shellcheck disable=SC2329
    say()  { printf '%s\n' "$*"; }
    # shellcheck disable=SC2329
    hdr()  { say ""; say "${C_BOLD}${C_BLU}── $* ──${C_RESET}"; }
    # shellcheck disable=SC2329
    ok()   { say "  ${C_GRN}✓${C_RESET} $*"; }
    # shellcheck disable=SC2329
    warn() { say "  ${C_YEL}⚠${C_RESET} $*"; }
    # shellcheck disable=SC2329
    bad()  { say "  ${C_RED}✗${C_RESET} $*"; }
    # shellcheck disable=SC2329
    info() { say "  ${C_DIM}·${C_RESET} $*"; }
    # shellcheck disable=SC2329
    log_pipe() { cat; }
    "$fn"
  ) &
}

# Persist a variable across the parallel boundary. Appends `NAME=quoted-VALUE`
# to the vars file; the orchestrator sources it on collect. Also sets the
# variable in the current subshell so downstream code in the same function
# can read it. When called outside a parallel-launched subshell
# ($NETDIAG_PAR_VARS unset), the file write is skipped and only the local
# assignment runs — modules can call setvar unconditionally regardless of
# whether they're invoked sync or parallel.
setvar() {
  local name="$1" val="$2"
  # NETDIAG_PAR_VARS is set inside the launch_parallel subshell (SC2031
  # is the same false positive as in launch_parallel above).
  # shellcheck disable=SC2031
  if [ -n "${NETDIAG_PAR_VARS:-}" ]; then
    # shellcheck disable=SC2031
    printf '%s=%q\n' "$name" "$val" >>"$NETDIAG_PAR_VARS"
  fi
  printf -v "$name" '%s' "$val"
}

# Wait for all background launches, then in launch order: replay each
# section's stdout buffer to terminal+LOG and source its vars file.
collect_parallel() {
  wait
  local name out vars
  for name in "${PAR_NAMES[@]}"; do
    out="$PAR_TMP/$name.out"
    vars="$PAR_TMP/$name.vars"
    if [ -s "$out" ]; then
      if [ "$JSON_MODE" -eq 0 ] && \
         { [ "$QUIET" -eq 0 ] || [ "$DIAGNOSIS_REACHED" -eq 1 ]; }; then
        cat "$out"
      fi
      sed $'s/\033\\[[0-9;]*m//g' "$out" >> "$LOG"
    fi
    if [ -s "$vars" ]; then
      # shellcheck disable=SC1090
      . "$vars"
    fi
  done
  PAR_NAMES=()
  if [ -n "$PAR_TMP" ] && [ -d "$PAR_TMP" ]; then
    rm -rf "$PAR_TMP"
    PAR_TMP=""
  fi
}
