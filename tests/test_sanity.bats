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
