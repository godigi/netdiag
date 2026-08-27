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
  [[ "$output" == *"unknown flag"* ]] || return 1
}

@test "two positional TARGETs exit 3" {
  run "$NETDIAG" example.com example.net
  [ "$status" -eq 3 ]
  [[ "$output" == *"only one TARGET"* ]] || return 1
}

@test "--log without a path exits 3" {
  run "$NETDIAG" --log
  [ "$status" -eq 3 ]
  [[ "$output" == *"expects a path"* ]] || return 1
}

@test "--watch rejects a non-numeric interval before starting a loop" {
  run "$NETDIAG" --watch=abc
  [ "$status" -eq 3 ]
  [[ "$output" == *"--watch expects"* ]] || return 1
}

@test "--watch rejects a zero interval before starting a loop" {
  run "$NETDIAG" --watch=0
  [ "$status" -eq 3 ]
  [[ "$output" == *"--watch expects"* ]] || return 1
}

@test "--summary rejects a non-numeric window with the script-error status" {
  run env HOME="$BATS_TEST_TMPDIR" "$NETDIAG" --summary=abc
  [ "$status" -eq 3 ]
  [[ "$output" == *"--summary expects"* ]] || return 1
}

@test "--mtu-only with --quick is rejected as a conflict" {
  run "$NETDIAG" --mtu-only --quick
  [ "$status" -eq 3 ]
  [[ "$output" == *"conflict"* ]] || return 1
}

@test "stacking two --*-only flags is rejected as mutually exclusive" {
  run "$NETDIAG" --wifi-only --dns-only
  [ "$status" -eq 3 ]
  [[ "$output" == *"mutually exclusive"* ]] || return 1
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

@test "--help is organised into labelled sections" {
  # A 110-line wall of flags in no particular order made a user scroll
  # past --progress's file-descriptor protocol to reach --wifi-only.
  # The sections are the navigation; this asserts they exist and stay.
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  for section in "Common:" "Sharing and output:" "Just one check:" \
                 "Modes" "Advanced:"; do
    [[ "$output" == *"$section"* ]] || {
      echo "missing section from --help: $section"
      return 1
    }
  done
}

@test "--quick's own description admits it skips the MTU probe" {
  # lib/mtu.sh:13 returns early under --quick, but --help listed the
  # skips as "bufferbloat, per-hop loss, speed test, internet
  # packet-loss probe, WiFi scan" and never said so. A user reading
  # only --help would expect an MTU number and get "not measured".
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  local quick_block
  quick_block="$(printf '%s\n' "$output" | awk '
      /^  --quick( |$)/ { inblock = 1; print; next }
      inblock && /^  --/ { exit }
      inblock           { print }
  ')"
  [[ "$quick_block" == *"MTU"* ]] || {
    echo "--quick's help text does not mention MTU:"
    echo "$quick_block"
    return 1
  }
}
