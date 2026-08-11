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
#   is_numeric <value>           — guard before [ -lt ] / $(( )) / awk math
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
# Stdout gating per mode:
#   --json       : nothing on stdout (JSON object is emitted separately)
#   --quiet      : only the diagnoses (no Report card, no section bodies)
#   --expert     : every section body, plus Report card + diagnoses
#   default      : Report card + diagnoses; section bodies silent
# The log file gets ANSI-stripped raw text in every mode.
#
# DIAGNOSIS_REACHED flips to 1 when hdr() sees one of the "punchline"
# section names (Report / Summary / Diagnosis / What we found). After that,
# all say() calls reach stdout regardless of mode (except --json).
DIAGNOSIS_REACHED=0
_should_print_stdout() {
  [ "$JSON_MODE" -eq 0 ] || return 1
  # Past the punchline → always print (unless JSON).
  [ "$DIAGNOSIS_REACHED" -eq 1 ] && return 0
  # Before the punchline: --quiet wins (silent), then --expert (verbose),
  # then default (silent).
  [ "$QUIET" -eq 1 ]  && return 1
  [ "$EXPERT" -eq 1 ] && return 0
  return 1
}
# ── Redaction ────────────────────────────────────────────────────────────
# A netdiag report is something people paste into forum threads and support
# tickets, and it carries their public IP, SSID, BSSID, city and IPv6
# prefix. --redact masks those on the way to stdout and in --json.
#
# The local log deliberately keeps full detail: it lives on the user's own
# machine and is the thing they'd want when debugging later. stdout and
# JSON are what get shared, so that's what gets masked.
#
# Substring replacement over the known values, rather than field-by-field
# rewriting, so a value is masked wherever it appears — including inside a
# diagnosis sentence that interpolated it. ASN and ISP are deliberately
# kept: they're needed to reason about the fault and identify a provider,
# not a person. Country code and private RFC1918 addresses are kept too —
# the former is too short to replace safely, the latter isn't identifying.
_redact_line() {
  local s="$1" v
  # IPV6_GATEWAY is masked even though it is link-local and unroutable: a
  # fe80:: address is EUI-64-derived from the router's MAC, so publishing
  # it leaks the very GW_MAC listed on the line below.
  for v in "${PUB_IP:-}" "${LOCAL_IP:-}" "${WIFI_SSID:-}" "${WIFI_BSSID:-}" \
           "${IPV6_GLOBAL_ADDR:-}" "${IPV6_GATEWAY:-}" "${GW_MAC:-}" \
           "${PUB_CITY:-}"; do
    # Skip empties (would match everywhere) and 1-2 char values (too short
    # to replace without corrupting unrelated text).
    [ "${#v}" -ge 3 ] || continue
    s="${s//"$v"/[redacted]}"
  done
  printf '%s' "$s"
}

say() {
  if _should_print_stdout; then
    if [ "${REDACT:-0}" -eq 1 ]; then
      printf '%s\n' "$(_redact_line "$*")"
    else
      printf '%s\n' "$*"
    fi
  fi
  printf '%s\n' "$*" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOG"
}
# tell() prints regardless of EXPERT/QUIET — used for the "netdiag" header
# and other always-visible lines that should appear even in compact-default
# output. JSON_MODE still suppresses stdout.
tell() {
  if [ "$JSON_MODE" -eq 0 ]; then
    if [ "${REDACT:-0}" -eq 1 ]; then
      printf '%s\n' "$(_redact_line "$*")"
    else
      printf '%s\n' "$*"
    fi
  fi
  printf '%s\n' "$*" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOG"
}
hdr() {
  # The "punchline" section names flip the QUIET / default gate so the
  # Report card and diagnoses always show even when section bodies were
  # suppressed. Non-punchline sections start an animated spinner on
  # stderr so the user has something to watch during the long wait
  # (bufferbloat: 10 s, mtr-under-sudo: 12 s, etc.). Each hdr stops the
  # previous spinner before starting a new one.
  progress_spin_stop
  case "$*" in
    Diagnosis*|Summary*|Report*|"What we found"*)
      DIAGNOSIS_REACHED=1
      progress_clear
      ;;
    *)
      progress_spin_start "$*"
      ;;
  esac
  say ""
  say "${C_BOLD}${C_BLU}── $* ──${C_RESET}"
}

# ── Progress indicator (stderr) ──────────────────────────────────────────
# Writes an overwriting status line to stderr so the user sees activity
# during the 25-40 s wait that the default-compact mode would otherwise
# show as silence. Stays out of stdout so JSON / piped consumers aren't
# affected. Suppressed under --json, --watch-child, or non-TTY stderr.
_progress_active() {
  [ -t 2 ] || return 1
  [ "$JSON_MODE" -eq 0 ] || return 1
  [ "${WATCH_CHILD:-0}" -eq 0 ] || return 1
  return 0
}
progress() {
  _progress_active || return 0
  # \r returns to column 1; \e[K clears to end of line.
  printf '\r\e[K%s⟳ %s…%s' "${C_DIM}" "$*" "${C_RESET}" >&2
}
progress_clear() {
  _progress_active || return 0
  printf '\r\e[K' >&2
}

# Animated spinner for the parallel batch — fork a background process
# that overwrites the progress line every 100 ms. Caller is responsible
# for calling progress_spin_stop before returning.
_progress_spinner_pid=""
progress_spin_start() {
  _progress_active || return 0
  # Idempotent by design. _progress_spinner_pid holds exactly one pid, so
  # starting a spinner while another is running used to overwrite the only
  # handle we had on the old one: it was never killed, kept repainting its
  # own label every 100 ms, and the terminal flickered between two captions
  # at 10 Hz. Because nothing else tracked it, the orphan also outlived the
  # run and went on writing to the user's shell after netdiag had exited.
  # hdr() already stops the previous spinner; the direct callers in
  # bin/netdiag (the parallel batch, --wifi-only) did not.
  progress_spin_stop
  local label="$1"
  (
    local frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local i=0
    while true; do
      printf '\r\e[K%s%s %s…%s' "${C_DIM}" "${frames[$((i % 10))]}" "$label" "${C_RESET}" >&2
      sleep 0.1
      i=$((i + 1))
    done
  ) &
  _progress_spinner_pid=$!
}
progress_spin_stop() {
  if [ -n "$_progress_spinner_pid" ]; then
    kill "$_progress_spinner_pid" 2>/dev/null || true
    wait "$_progress_spinner_pid" 2>/dev/null || true
    _progress_spinner_pid=""
  fi
  progress_clear
}
ok()   { say "  ${C_GRN}✓${C_RESET} $*"; }
warn() { say "  ${C_YEL}⚠${C_RESET} $*"; }
bad()  { say "  ${C_RED}✗${C_RESET} $*"; }
info() { say "  ${C_DIM}·${C_RESET} $*"; }

# ── DHCP-vs-system DNS comparison ────────────────────────────────────────
# Lives here rather than in lib/dns.sh because lib/diagnosis.sh needs the
# same predicate and must not depend on the DNS module being sourced.
#
# A link-local resolver is always the router's own RA/RDNSS advertisement:
# macOS won't accept a scoped fe80::…%en0 address typed into System
# Settings, so such an entry can never be a user override. Strip them
# before reporting or comparing.
dns_routable_resolvers() {
  local s out=""
  local -a sys_arr=()
  read -r -a sys_arr <<<"${1//,/ }"
  for s in "${sys_arr[@]:-}"; do
    case "$s" in
      ""|fe80:*|FE80:*) continue ;;
    esac
    out+="${out:+ }$s"
  done
  printf '%s' "$out"
}

# True (exit 0) only when the system resolver list is a genuine *manual*
# replacement of what DHCP handed out — i.e. not one of the DHCP-supplied
# servers is actually in use. Three ways the original test (is nameserver[0]
# a substring of the DHCP list?) got this wrong on an ordinary dual-stack
# home network:
#   - macOS configures several resolvers. Where the router sends IPv6 RAs,
#     its link-local lands at nameserver[0] and the DHCP-handed v4 server
#     at nameserver[1], so reading only [0] reported an override that had
#     never happened — the router's own DNS was in use the whole time.
#   - DHCPv4 option 6 cannot carry IPv6 addresses, so a v6 resolver can
#     never match it. Comparing the two families is a category error.
#   - grep -F matches substrings: a system resolver of 192.168.15.1
#     "matched" a DHCP list of 192.168.15.10 and hid a real override.
# Args: $1 = DHCP-handed server list, $2 = full system resolver list.
#       Either may be space- and/or comma-separated.
dns_is_manual_override() {
  local s d routable
  local -a dhcp_arr=() sys_arr=()
  read -r -a dhcp_arr <<<"${1//,/ }"
  routable="$(dns_routable_resolvers "$2")"
  read -r -a sys_arr <<<"$routable"
  # No DHCP offer or no routable resolver means no evidence either way.
  # Silence beats a confident guess about the user's own configuration.
  [ "${#dhcp_arr[@]}" -gt 0 ] && [ -n "${dhcp_arr[0]:-}" ] || return 1
  [ "${#sys_arr[@]}" -gt 0 ] || return 1
  for s in "${sys_arr[@]}"; do
    for d in "${dhcp_arr[@]}"; do
      [ "$s" = "$d" ] && return 1
    done
  done
  return 0
}

# Pipeline-target replacement for `tee -a "$LOG"`. Writes to log unconditionally;
# also writes to stdout iff _should_print_stdout would.
#
# Under --redact the stdout copy is filtered line by line, same rule as
# say(): the log keeps the real values, stdout does not.
log_pipe() {
  if _should_print_stdout; then
    if [ "${REDACT:-0}" -eq 1 ]; then
      local line
      while IFS= read -r line; do
        printf '%s\n' "$line" >> "$LOG"
        printf '%s\n' "$(_redact_line "$line")"
      done
    else
      tee -a "$LOG"
    fi
  else
    cat >> "$LOG"
  fi
}

# ── Diagnosis accumulator ────────────────────────────────────────────────
DIAG=()
DIAG_SEV=()
DIAG_RULE=()
MAX_SEVERITY=0  # exit code on a clean run: 0=healthy, 1=warn, 2=critical
# Severity tiers:
#   info     — heads-up only, doesn't bump exit code
#   warn     — exit 1 if nothing more severe was seen
#   critical — exit 2
#
# Usage: add_diag <severity> <rule-id> <message…>
#
# The rule ID (W1, NAT-1, BL-1, …) matches a section heading in
# docs/DIAGNOSIS-RULES.md. It rides along into the JSON so output is
# greppable and a user can look up why a threshold fired, instead of
# having to reverse-engineer it from the prose.
add_diag() {
  local sev="$1" rule="$2"; shift 2
  DIAG+=("$*")
  DIAG_SEV+=("$sev")
  DIAG_RULE+=("$rule")
  case "$sev" in
    critical) [ "$MAX_SEVERITY" -lt 2 ] && MAX_SEVERITY=2 ;;
    warn)     [ "$MAX_SEVERITY" -lt 1 ] && MAX_SEVERITY=1 ;;
  esac
  # The case arms above are `[ … ] && assign`, which evaluates false — and
  # so returns 1 — whenever the severity is already at or above the new
  # one. Adding a second critical therefore made add_diag report failure.
  # Nothing noticed because bin/netdiag runs under `set -u` alone, but any
  # caller with `set -e` (the bats suite, for one) aborted mid-rule-set and
  # silently truncated the diagnosis list. Recording a diagnosis always
  # succeeds; say so explicitly.
  return 0
}

# ── Loss-percentage predicates ───────────────────────────────────────────
# ping reports loss as a decimal ("12.5% packet loss"), so the obvious
# [ "$loss" -ge 20 ] is a syntax error on exactly the values that matter.
# The existing rules dodged that with ${loss%.*} truncation, which silently
# rounds 19.9 down to 19 — fine for a 20% floor, wrong for a 5% one where
# 5.0 is a legitimate single-packet reading. These compare as floats.
#
# Both predicates treat an unmeasured value (empty, or non-numeric because
# the probe failed) as "no". That distinction is the whole substance of the
# ping6 bug fixed in v0.5.2: a failed measurement rendered as 100% loss is
# a confident false statement about the user's network.

# True when $1 is a number we actually measured.
loss_measured() {
  [ -n "${1:-}" ] || return 1
  awk -v v="$1" 'BEGIN{exit !(v ~ /^[0-9]+(\.[0-9]+)?$/)}'
}

# True when $1 was measured AND is >= $2.
loss_at_least() {
  loss_measured "${1:-}" || return 1
  awk -v v="$1" -v t="$2" 'BEGIN{exit !(v + 0 >= t + 0)}'
}

# True when $1 was measured AND is < $2. Distinct from ! loss_at_least,
# which is also true for an unmeasured value — a rule that needs "the
# gateway is provably clean" must not fire when the gateway was never
# pinged at all.
loss_below() {
  loss_measured "${1:-}" || return 1
  awk -v v="$1" -v t="$2" 'BEGIN{exit !(v + 0 < t + 0)}'
}

# ── Timing instrumentation ───────────────────────────────────────────────
# The spec promises ≤ 30 s for a full run and ≤ 8 s for --quick, and until
# now nothing measured whether that held. Worst-case arithmetic says it
# doesn't: the MTU walk, traceroute (25 s cap) and mtr (20 s cap) alone can
# exceed the full-run budget on a bad path. Record per-phase elapsed time
# so the claim is checkable on real hardware instead of asserted.
#
# TIMING_LINES accumulates "phase|seconds" rows; emit_json turns them into
# the JSON `timings` object and --expert prints them as a closing section.
TIMING_LINES=""
RUN_STARTED_AT="$EPOCHREALTIME"

# run_timed <phase-name> <command…> — run it, record wall-clock, preserve
# the command's exit status so callers see no behavioural difference.
run_timed() {
  local name="$1"; shift
  local t0 rc
  t0="$EPOCHREALTIME"
  "$@"
  rc=$?
  TIMING_LINES+="${name}|$(awk -v a="$t0" -v b="$EPOCHREALTIME" \
    'BEGIN{printf "%.2f", b-a}')"$'\n'
  return "$rc"
}

# Total wall-clock since the run began, as a decimal string.
run_elapsed_s() {
  awk -v a="$RUN_STARTED_AT" -v b="$EPOCHREALTIME" 'BEGIN{printf "%.2f", b-a}'
}

# ── Numeric guard ────────────────────────────────────────────────────────
# Succeeds iff the argument is a plain signed decimal number.
#
# Every metric in this script is scraped out of another tool's text output,
# and those formats drift between macOS releases. Without a guard, a parse
# that lands on the wrong field feeds a string into `[ -lt ]` ("integer
# expression expected" on stderr), into `$(( ))` (a syntax error), or into
# an awk comparison — where it silently degrades to a *string* compare and
# produces a confidently wrong diagnosis. Parsers should gate on this and
# blank the variable instead, so the section reports "unknown" rather than
# a fabricated number.
is_numeric() {
  [[ "${1:-}" =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]]
}

# ── Bufferbloat grading ──────────────────────────────────────────────────
# Waveform/DSLReports thresholds, held in lib/thresholds.sh alongside every
# other cutoff a diagnosis rule fires on: A < +5ms, B < +30ms, C < +60ms,
# D < +200ms, F ≥ +200ms. B1/B2 warn at C and go critical at D or F.
grade_bufferbloat() {
  awk -v d="$1" -v a="$THRESH_BUFFERBLOAT_A_MS" -v b="$THRESH_BUFFERBLOAT_B_MS" \
      -v c="$THRESH_BUFFERBLOAT_C_MS" -v e="$THRESH_BUFFERBLOAT_D_MS" 'BEGIN{
    if (d+0 < a) { print "A"; exit }
    if (d+0 < b) { print "B"; exit }
    if (d+0 < c) { print "C"; exit }
    if (d+0 < e) { print "D"; exit }
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
PAR_PIDS=()
PAR_TMP=""
launch_parallel() {
  local name="$1" fn="$2"
  if [ -z "$PAR_TMP" ]; then
    PAR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/netdiag-par.XXXXXX")"
  fi
  PAR_NAMES+=("$name")
  # The subshell below intentionally redefines say/hdr/etc. The launched
  # function $fn invokes them via name resolution at call time, so SC2329
  # ("function never invoked") and SC2317 ("command unreachable") are both
  # false positives — shellcheck can't see the indirect "$fn" dispatch.
  # SC2030 / SC2031 on NETDIAG_PAR_OUT/PAR_VARS are by design: they're
  # scoped to the subshell on purpose so each check writes its own files.
  # shellcheck disable=SC2030
  (
    NETDIAG_PAR_OUT="$PAR_TMP/$name.out"
    NETDIAG_PAR_VARS="$PAR_TMP/$name.vars"
    : >"$NETDIAG_PAR_OUT"
    : >"$NETDIAG_PAR_VARS"
    exec 1>"$NETDIAG_PAR_OUT" 2>&1
    # shellcheck disable=SC2329,SC2317
    say()  { printf '%s\n' "$*"; }
    # shellcheck disable=SC2329,SC2317
    hdr()  { say ""; say "${C_BOLD}${C_BLU}── $* ──${C_RESET}"; }
    # shellcheck disable=SC2329,SC2317
    ok()   { say "  ${C_GRN}✓${C_RESET} $*"; }
    # shellcheck disable=SC2329,SC2317
    warn() { say "  ${C_YEL}⚠${C_RESET} $*"; }
    # shellcheck disable=SC2329,SC2317
    bad()  { say "  ${C_RED}✗${C_RESET} $*"; }
    # shellcheck disable=SC2329,SC2317
    info() { say "  ${C_DIM}·${C_RESET} $*"; }
    # shellcheck disable=SC2329,SC2317
    log_pipe() { cat; }
    "$fn"
  ) &
  PAR_PIDS+=("$!")
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
# section's stdout buffer to terminal+LOG and source its vars file. The
# stdout replay uses _should_print_stdout so section bodies stay hidden
# in default-compact mode while expert mode shows everything.
collect_parallel() {
  # Wait only on the section PIDs, not on every background job — the
  # progress spinner is a separate child process that runs concurrently
  # and would otherwise pin `wait` indefinitely.
  local pid
  for pid in "${PAR_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  PAR_PIDS=()
  local name out vars
  for name in "${PAR_NAMES[@]}"; do
    out="$PAR_TMP/$name.out"
    vars="$PAR_TMP/$name.vars"
    if [ -s "$out" ]; then
      if _should_print_stdout; then
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
