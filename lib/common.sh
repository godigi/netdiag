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
#   progress_*                   — the --progress event stream on fd 3

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
  printf '%s\n' "$*" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOG" 2>/dev/null || true
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
  printf '%s\n' "$*" | sed $'s/\033\\[[0-9;]*m//g' >> "$LOG" 2>/dev/null || true
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

# ── Progress events (fd 3) ───────────────────────────────────────────────
# A second progress channel, and deliberately not a second spinner: the
# block above paints a caption for a person on stderr, this one emits one
# JSON object per line for a program (the menu-bar app, a wrapper script).
#
# It goes on fd 3 rather than stderr because launch_parallel runs each
# parallel check in a subshell that does `exec 1>"$out" 2>&1`. A parallel
# check's progress written to stderr lands inside that per-check buffer,
# where nobody reads it until the check finishes — which is the exact
# moment progress stops being worth having. fd 3 survives that redirect.
# It cannot go on stdout either: --json promises exactly one object there.
#
# bin/netdiag points fd 3 at stderr under --progress and at /dev/null
# otherwise. The PROGRESS guard below is not redundant with that: the bats
# suite sources this file directly, without bin/netdiag, and there fd 3 was
# never opened at all — an unguarded write would print "Bad file
# descriptor" for every phase of every test.
#
# Every event is emitted with a single printf of a short line. A write to a
# pipe is atomic only up to PIPE_BUF (512 bytes on macOS) and all the
# parallel subshells share this one fd, so an event assembled from two
# writes could interleave with another check's and produce a line that
# parses as neither.
PROGRESS="${PROGRESS:-0}"
progress_emit() {
  [ "${PROGRESS:-0}" -eq 1 ] || return 0
  printf '%s\n' "$1" >&3
}

# A bash string as a JSON string literal: clamp first, then escape.
#
# Clamping is the PIPE_BUF rule — a `why` carrying a diagnosis-length
# sentence would push its event past the atomic-write limit and let it
# interleave with a parallel check's. Clamping *after* escaping would be
# worse than not clamping at all: the cut can land between a backslash and
# the character it escapes, and the line stops being JSON.
PROGRESS_TEXT_MAX=120
progress_json_str() {
  local s="${1:0:$PROGRESS_TEXT_MAX}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # A raw control character is not legal inside a JSON string, and a raw
  # newline would additionally split one event into two unparseable lines.
  s="${s//[[:cntrl:]]/ }"
  printf '"%s"' "$s"
}

# The phases each mode will attempt, in the order it attempts them.
#
# A declared list drifts from the code the first time a check is added, so
# tests/test_progress.bats asserts both directions: every name bin/netdiag
# passes to run_timed or launch_parallel appears in some mode's plan, and
# every name in a plan is one bin/netdiag actually passes.
#
# full and quick declare the same phases on purpose. --quick does not skip
# a *call site*: bufferbloat_run, mtr_run and the rest are invoked either
# way and return early, so they report `skip` with a reason. Dropping them
# from the plan would hide that they were considered, and "17 of 25" would
# stop adding up.
progress_plan_phases() {
  case "$1" in
    full|quick)
      printf '%s\n' iface vpn wifi gateway arp netid dhcp public \
        dns ipv6 tcp_reach ntp hosts wifi_scan wifi_disconnect \
        wan_lb wan_upnp path traffic parallel_batch internet_ping bufferbloat mtu \
        traceroute nat mtr watchdog availability speedtest ;;
    mtu-only)   printf '%s\n' iface netid public mtu ;;
    wifi-only)  printf '%s\n' iface wifi netid wifi_scan wifi_disconnect ;;
    speed-only) printf '%s\n' iface gateway arp wifi netid public speedtest ;;
    dns-only)   printf '%s\n' iface dhcp netid dns ;;
    ping-only)  printf '%s\n' iface gateway arp wifi netid internet_ping ;;
    bufferbloat-only) printf '%s\n' iface gateway arp wifi netid public bufferbloat ;;
  esac
}

# A plan, not a percentage — on this side of the wire. --json produces
# nothing until the very end, so this stream has no quantity to offer a
# percentage *of*; a named list of phases lets a consumer say "17 of 25,
# testing under load", which is true.
#
# A consumer that keeps its own history can go further, and netdiag.app
# now does: the `ms` on each `done` event below is what it accumulates,
# per phase per mode, to weight a real progress bar. That is a fact this
# stream supplies rather than one it asserts — the CLI still never emits
# a percentage. See gui/Sources/NetdiagGUI/Support/PhaseWeights.swift and
# docs/design/watching-it-happen.md.
progress_plan() {
  local mode="$1" phases="" p
  # Phase names are internal identifiers ([a-z_]), so they need no
  # escaping — progress_json_str is for free text like a skip reason.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    phases+="${phases:+,}\"$p\""
  done < <(progress_plan_phases "$mode")
  progress_emit "{\"t\":\"plan\",\"phases\":[$phases],\"mode\":\"$mode\"}"
}

progress_phase_start() {
  progress_emit "{\"t\":\"phase\",\"name\":\"$1\",\"state\":\"start\"}"
}
progress_phase_done() {
  progress_emit "{\"t\":\"phase\",\"name\":\"$1\",\"state\":\"done\",\"rc\":$2,\"ms\":$3}"
}
progress_phase_skip() {
  progress_emit "{\"t\":\"phase\",\"name\":\"$1\",\"state\":\"skip\",\"why\":$(progress_json_str "$2")}"
}
progress_run_done() {
  progress_emit "{\"t\":\"run\",\"state\":\"done\",\"exit\":$1}"
}

# Sub-progress inside one phase. Every field is nullable and an unmeasured
# one is null, never 0 — a speed test that has not reached the download
# stage has no throughput, which is a different fact from 0 Mbps.
progress_speed() {
  progress_emit "{\"t\":\"speed\",\"stage\":$(progress_json_str "$1"),\"progress\":${2:-null},\"mbps\":${3:-null},\"ms\":${4:-null}}"
}

# Called by a check that decided not to do any work, so its phase resolves
# as `skip` with a reason instead of a `done` in 0 ms — which reads as
# "measured, instantly" rather than "never ran".
#
# It records only the reason. The name belongs to whichever wrapper is
# running the check, and having the check name itself would be a second
# copy of a string that already has an owner, free to drift from it.
NETDIAG_PHASE_SKIP=""
progress_skip() {
  NETDIAG_PHASE_SKIP="${1:-skipped}"
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
        printf '%s\n' "$line" >> "$LOG" 2>/dev/null || true
        printf '%s\n' "$(_redact_line "$line")"
      done
    else
      tee -a "$LOG" 2>/dev/null || cat
    fi
  else
    cat >> "$LOG" 2>/dev/null || cat
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

# ── Captive-portal classification ────────────────────────────────────────
# One classifier for the same probe run in two places (lib/public.sh in a
# scan, lib/monitor.sh between scans) so they cannot disagree about what
# the answer means. $1 is curl's %{http_code}; prints ok | portal | unknown.
# A failed probe is unknown, never "no portal" — silence beats a guess.
# Classify a captive-portal canary probe. $1 = HTTP status, $2 = response
# body. Prints "ok" | "portal" | "unknown".
#
# The body is load-bearing, not decorative. This used to classify on the
# status alone — 3xx portal, 2xx ok — and both callers passed
# `curl -o /dev/null`, so a portal that answers 200 OK with its own login
# page (a hotel splash, a terms-of-service checkbox: the common case, not
# an edge case) was reported to the user as "No captive portal."
#
# Apple's own captive check works the same way this now does: request the
# canary, and treat anything that is not the literal success page as an
# interception. The marker below is the whole of that page's title element
# and is stable across every macOS release netdiag supports.
#
# "unknown" on an unreadable body is deliberate: a 200 with nothing
# captured means the probe failed to read a body, not that the network is
# clean, and silence beats a confident wrong answer. Callers already treat
# unknown as "say nothing".
CAPTIVE_CANARY_MARKER='<TITLE>Success</TITLE>'
captive_portal_classify() {
  local http_status="${1:-}" body="${2:-}"
  case "$http_status" in
    511)                printf 'portal'; return ;;
    3[0-9][0-9])        printf 'portal'; return ;;
    2[0-9][0-9])        ;;
    *)                  printf 'unknown'; return ;;
  esac
  if [ -z "$body" ]; then
    printf 'unknown'
  elif printf '%s' "$body" | grep -qiF "$CAPTIVE_CANARY_MARKER"; then
    printf 'ok'
  else
    printf 'portal'
  fi
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

# True when $1 is at least $3 percent of $2. All three may be floats.
#
# Kept here rather than inline so the arithmetic exists once: the 100 is
# the percent scale, not a cutoff, and the cutoff itself always arrives
# as $3 from lib/thresholds.sh. Returns false unless all three are real
# numbers and $2 is positive — an unmeasured value must never satisfy a
# comparison, and dividing by a zero PHY rate would.
pct_at_least() {
  is_numeric "${1:-}" || return 1
  is_numeric "${2:-}" || return 1
  is_numeric "${3:-}" || return 1
  awk -v v="$1" -v total="$2" -v pct="$3" \
    'BEGIN{ if (total + 0 <= 0) exit 1; exit !(v + 0 >= (total + 0) * (pct + 0) / 100) }'
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

# Wall-clock since $1, as "<seconds to 2dp> <whole milliseconds>". One awk
# for both because the callers want both and a second fork per phase would
# be pure overhead: the log wants seconds, the progress stream wants ms.
_elapsed_pair() {
  awk -v a="$1" -v b="$EPOCHREALTIME" 'BEGIN{d=b-a; printf "%.2f %d", d, d*1000+0.5}'
}

# run_timed <phase-name> <command…> — run it, record wall-clock, preserve
# the command's exit status so callers see no behavioural difference.
#
# Also the first of the two places the --progress stream comes from.
# Instrumenting the wrapper rather than the checks covers every check at
# once, including the ones added after this was written, which is the
# failure it exists to prevent: a new check that nobody remembers to
# instrument shows up as a gap the UI renders as "didn't run".
run_timed() {
  local name="$1"; shift
  local t0 rc secs ms
  NETDIAG_PHASE_SKIP=""
  progress_phase_start "$name"
  t0="$EPOCHREALTIME"
  "$@"
  rc=$?
  read -r secs ms < <(_elapsed_pair "$t0")
  TIMING_LINES+="${name}|${secs}"$'\n'
  if [ -n "$NETDIAG_PHASE_SKIP" ]; then
    progress_phase_skip "$name" "$NETDIAG_PHASE_SKIP"
  else
    progress_phase_done "$name" "$rc" "$ms"
  fi
  NETDIAG_PHASE_SKIP=""
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

# Parse the common macOS ping summary once for every caller. The output is
# loss percentage, average RTT, and standard deviation separated by pipes;
# each field is intentionally empty when that part of the summary is absent.
# An absent summary means "not measured", not 100% loss.
ping_parse_summary() {
  local out="${1:-}" loss avg jitter
  loss="$(printf '%s\n' "$out" \
    | awk -F'[ %]' '/packet loss/{for(j=1;j<=NF;j++)if($j=="packet")print $(j-2)}' | head -1)"
  avg="$(printf '%s\n' "$out" \
    | awk -F'[ /]' '/round-trip|rtt/{print $(NF-3); exit}')"
  jitter="$(printf '%s\n' "$out" \
    | awk -F'[ /]' '/round-trip|rtt/{print $(NF-1); exit}')"
  printf '%s|%s|%s' "$loss" "$avg" "$jitter"
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
#
# Second subtlety: `wait` can return >128 for two different reasons. The
# ordinary one is the killer's TERM landing on the command (timeout —
# report 124). The other is a trapped signal (INT/TERM under --monitor)
# interrupting the wait while the command is still running. In that case
# the command must be reaped before returning, or a probe outlives the
# cycle that spawned it and keeps sampling a link this tool promised was
# quiet. Either way anything above 128 reports as 124: the caller only
# needs "it did not finish in its budget".
#
# Known limit: TERM goes to the direct child only. A wrapper that doesn't
# relay signals can leave grandchildren alive; every probe this repo wraps
# is a single self-bounded binary, so no process-group kill is attempted
# (the subshell shares the script's process group — killing it would take
# netdiag down with it).
with_timeout() {
  local secs="$1"; shift
  ( "$@" ) &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local killer_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  if [ "$rc" -gt 128 ]; then
    # The wait ended without the command ending it: reap the command and
    # the pending killer before reporting the timeout.
    kill -TERM "$cmd_pid" 2>/dev/null
    wait "$cmd_pid" 2>/dev/null
    kill -TERM "$killer_pid" 2>/dev/null
    wait "$killer_pid" 2>/dev/null
    return 124
  fi
  kill -TERM "$killer_pid" 2>/dev/null
  wait "$killer_pid" 2>/dev/null
  return "$rc"
}

# ── Temp-dir registry ────────────────────────────────────────────────────
# The orchestrator owns the parallel scratch directory. On an abort
# (Ctrl-C, SIGHUP, or a killed parallel check) collect_parallel never gets
# to its normal cleanup, so register that directory for bin/netdiag's EXIT
# trap. A directory created inside a parallel child cannot update the
# parent's shell variables; those modules still clean up on their success
# path, while this registry covers the long-lived parent-owned directory.
_NETDIAG_TMP_DIRS=""
NETDIAG_TMP_DIR=""
netdiag_mktemp_dir() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/${1:-netdiag}.XXXXXX")" || return 1
  NETDIAG_TMP_DIR="$d"
  _NETDIAG_TMP_DIRS+="$d"$'\n'
}
netdiag_tmp_forget() {
  local target="$1" d kept=""
  while IFS= read -r d; do
    [ -n "$d" ] && [ "$d" != "$target" ] && kept+="$d"$'\n'
  done <<<"$_NETDIAG_TMP_DIRS"
  _NETDIAG_TMP_DIRS="$kept"
  [ "$NETDIAG_TMP_DIR" = "$target" ] && NETDIAG_TMP_DIR=""
}
_netdiag_tmp_cleanup() {
  local d
  # shellcheck disable=SC2034
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done <<<"$_NETDIAG_TMP_DIRS"
  _NETDIAG_TMP_DIRS=""
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
    netdiag_mktemp_dir netdiag-par || return 1
    PAR_TMP="$NETDIAG_TMP_DIR"
  fi
  PAR_NAMES+=("$name")
  # The subshell below intentionally redefines say/hdr/etc. The launched
  # function $fn invokes them via name resolution at call time, so SC2329
  # ("function never invoked") and SC2317 ("command unreachable") are both
  # false positives — shellcheck can't see the indirect "$fn" dispatch.
  # SC2030 / SC2031 on NETDIAG_PAR_OUT/PAR_VARS are by design: they're
  # scoped to the subshell on purpose so each check writes its own files.
  progress_phase_start "$name"
  # shellcheck disable=SC2030
  (
    NETDIAG_PAR_OUT="$PAR_TMP/$name.out"
    NETDIAG_PAR_VARS="$PAR_TMP/$name.vars"
    : >"$NETDIAG_PAR_OUT"
    : >"$NETDIAG_PAR_VARS"
    exec 1>"$NETDIAG_PAR_OUT" 2>&1
    # The parent registry contains PAR_TMP itself. Give this child a fresh
    # registry so its module scratch dirs can be removed on SIGTERM/abort
    # without deleting the files collect_parallel still needs to read.
    _NETDIAG_TMP_DIRS=""
    NETDIAG_TMP_DIR=""
    trap _netdiag_tmp_cleanup EXIT
    # fd 3 is deliberately NOT part of the redirect above, which is the
    # whole reason the progress stream is on it: this check's result is
    # announced the moment it lands, not when collect_parallel gets round
    # to replaying its buffer.
    NETDIAG_PHASE_SKIP=""
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
    _par_t0="$EPOCHREALTIME"
    "$fn"
    _par_rc=$?
    # Seconds are discarded here. TIMING_LINES lives in the orchestrator
    # and this is a subshell, so a row appended here would vanish; the
    # parallel_batch phase already accounts for this check's wall-clock.
    read -r _ _par_ms < <(_elapsed_pair "$_par_t0")
    if [ -n "$NETDIAG_PHASE_SKIP" ]; then
      progress_phase_skip "$name" "$NETDIAG_PHASE_SKIP"
    else
      progress_phase_done "$name" "$_par_rc" "$_par_ms"
    fi
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
      sed $'s/\033\\[[0-9;]*m//g' "$out" >> "$LOG" 2>/dev/null || true
    fi
    if [ -s "$vars" ]; then
      # shellcheck disable=SC1090
      . "$vars"
    fi
  done
  PAR_NAMES=()
  if [ -n "$PAR_TMP" ] && [ -d "$PAR_TMP" ]; then
    rm -rf "$PAR_TMP"
    netdiag_tmp_forget "$PAR_TMP"
    PAR_TMP=""
  fi
}
