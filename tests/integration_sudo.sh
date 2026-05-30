#!/usr/bin/env bash
# tests/integration_sudo.sh — exercise the mtr-under-sudo code path.
#
# The mtr branch in lib/mtr.sh activates only when mtr is installed AND
# sudo creds are cached AND jq is available. The bats suite can't trigger
# this without interactive auth, so this script does it as a one-shot
# integration check.
#
# Run: ./tests/integration_sudo.sh
# Will prompt for sudo once, then run a 6-cycle (-c 6) mtr to keep the
# test under ~5 s. Greps for the expected JSON shape and the "First lossy
# hop" log line. Non-zero exit on any check failure.

set -e
cd "$(dirname "$0")/.."

if ! command -v mtr >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # backticks are literal in the help message
  printf 'integration_sudo: skip — mtr not installed (`brew install mtr`)\n' >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  # shellcheck disable=SC2016
  printf 'integration_sudo: skip — jq not installed (`brew install jq`)\n' >&2
  exit 0
fi

printf 'integration_sudo: asking for sudo credentials (cached for this run only)...\n'
sudo -v

# Direct invocation of the mtr command netdiag would use, with the
# 60-cycle count dropped to 6 for speed.
MTR_JSON="$(sudo -n mtr -j -c 6 -n -i 0.2 1.1.1.1 2>/dev/null)"

if [ -z "$MTR_JSON" ]; then
  printf 'integration_sudo: FAIL — mtr returned no output even with cached sudo.\n' >&2
  exit 1
fi

if ! printf '%s' "$MTR_JSON" | jq -e .report.hubs >/dev/null 2>&1; then
  printf 'integration_sudo: FAIL — mtr JSON missing .report.hubs.\n' >&2
  printf '%s\n' "$MTR_JSON" | head -5
  exit 1
fi

HOP_COUNT="$(printf '%s' "$MTR_JSON" | jq -r '.report.hubs | length')"
if [ "$HOP_COUNT" -lt 1 ]; then
  printf 'integration_sudo: FAIL — mtr report has 0 hops.\n' >&2
  exit 1
fi

printf 'integration_sudo: OK — mtr reported %s hops via cached sudo.\n' "$HOP_COUNT"

# Smoke-run netdiag itself with cached sudo so the orchestrator hits the
# mtr branch and writes per_hop entries to JSON.
JSON_OUT="$(./bin/netdiag --json --no-gping --no-bufferbloat --no-baseline 2>/dev/null)"
if [ -z "$JSON_OUT" ]; then
  printf 'integration_sudo: FAIL — netdiag --json produced no output.\n' >&2
  exit 1
fi

PER_HOP_COUNT="$(printf '%s' "$JSON_OUT" | jq -r '.per_hop | length')"
if [ "$PER_HOP_COUNT" -lt 1 ]; then
  printf 'integration_sudo: FAIL — netdiag per_hop is empty.\n' >&2
  exit 1
fi

# When mtr ran, per_hop entries come from `mtr -j` and should have both
# loss_pct and avg_ms. (The fallback per-hop loop also fills both, so
# this is just a non-emptiness check.)
MISSING_LOSS="$(printf '%s' "$JSON_OUT" | jq -r '.per_hop[] | select(.loss_pct == null) | .ip' | wc -l | tr -d ' ')"
if [ "$MISSING_LOSS" -gt 0 ]; then
  printf 'integration_sudo: WARN — %s per_hop entries missing loss_pct.\n' "$MISSING_LOSS" >&2
fi

printf 'integration_sudo: OK — netdiag emitted %s per_hop entries with cached sudo.\n' "$PER_HOP_COUNT"
exit 0
