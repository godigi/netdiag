#!/usr/bin/env bats
#
# Smoke tests that never touch the network. Anything that requires real
# network state belongs in a separate file driven by fixtures under
# tests/fixtures/.

setup() {
  NETDIAG="${BATS_TEST_DIRNAME}/../bin/netdiag"
}

@test "bin/netdiag is executable" {
  [ -x "$NETDIAG" ]
}

@test "bin/netdiag --help exits 0" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
}

# ── Exit-code contract: 0 healthy · 1 warn · 2 critical · 3 script error ──
# Usage errors must NOT exit 2 — that status is reserved for "a critical
# diagnosis was found", and a wrapper can't tell a typo from a dead link.

@test "unknown flag exits 3 (script error), not 2" {
  run "$NETDIAG" --definitely-not-a-flag
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "two positional TARGETs exit 3" {
  run "$NETDIAG" example.com example.net
  [ "$status" -eq 3 ]
  [[ "$output" == *"only one TARGET"* ]]
}

@test "--log without a path exits 3" {
  run "$NETDIAG" --log
  [ "$status" -eq 3 ]
  [[ "$output" == *"expects a path"* ]]
}

@test "--mtu-only with --quick is rejected as a conflict" {
  run "$NETDIAG" --mtu-only --quick
  [ "$status" -eq 3 ]
  [[ "$output" == *"conflict"* ]]
}

# ── CLI surface matches the documented contract ──────────────────────────

@test "--help documents every flag in the CLAUDE.md CLI surface" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  for flag in --quick --quiet --json --no-gping --speed --no-speed \
              --mtu-only --wifi-only --baseline --no-baseline --log; do
    [[ "$output" == *"$flag"* ]] || {
      echo "missing from --help: $flag"
      return 1
    }
  done
}
