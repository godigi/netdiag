# shellcheck shell=bash
# lib/watch.sh — --watch mode: re-run netdiag --quick on a fixed interval
# until Ctrl-C. Each iteration is just the Diagnosis section (--quiet) plus
# a short header. SIGINT prints a summary line so users see how many runs
# they captured.
#
# Reads:  WATCH_INTERVAL_S, LOG_DIR, SCRIPT_PATH
# Entry:  watch_run (exits when interrupted; never returns)

watch_run() {
  printf 'netdiag --watch: every %ds, Ctrl-C to stop.\n' "$WATCH_INTERVAL_S"
  printf 'history appended to %s/baseline.jsonl\n\n' "$LOG_DIR"
  WATCH_ITER=0
  # shellcheck disable=SC2329 # invoked via the trap below
  watch_stop() {
    printf '\nnetdiag --watch stopped after %d iteration(s).\n' "$WATCH_ITER"
    printf 'See %s/baseline.jsonl or run: netdiag --summary\n' "$LOG_DIR"
    exit 0
  }
  trap watch_stop INT TERM
  while true; do
    WATCH_ITER=$((WATCH_ITER + 1))
    printf -- '----- iter %d  %s -----\n' "$WATCH_ITER" "$(date '+%Y-%m-%d %H:%M:%S')"
    # --watch-child suppresses the trailing "Report saved to" line so each
    # iteration is just header + Diagnosis.
    "$SCRIPT_PATH" --quick --no-gping --no-bufferbloat --quiet --watch-child
    sleep "$WATCH_INTERVAL_S"
  done
}
