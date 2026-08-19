#!/usr/bin/env bats
#
# netdiag --signal-scale — the word a GUI shows next to a raw RSSI number
# instead of inventing its own scale in Swift. Same family as
# test_rules_catalog.bats: an early exit, no probing, no log file, no
# network, and the boundaries have to be the live values in
# lib/thresholds.sh, not a second copy of them.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/netdiag"
  HELPERS="$REPO/helpers"
  VERSION="$(grep -m1 '^NETDIAG_VERSION=' "$REPO/bin/netdiag" \
    | sed -E 's/^NETDIAG_VERSION="([^"]*)"/\1/')"
  [ -n "$VERSION" ]
}

# ── Shape ─────────────────────────────────────────────────────────────

@test "--signal-scale exits 0 and prints one parseable JSON object" {
  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
  # One compact line, like --rules-catalog and every other machine-consumed
  # sibling output.
  [[ "$output" != *$'\n'* ]]
}

@test "--signal-scale writes nothing under HOME — no log, no history append" {
  run bash -c "HOME='$BATS_TEST_TMPDIR' '$NETDIAG' --signal-scale"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/net-diag" ]
}

@test "--signal-scale is documented in --help" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--signal-scale"* ]]
}

@test "--signal-scale appears in --capabilities features" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert 'signal-scale' in json.load(sys.stdin)['features']
"
}

@test "schema is 1" {
  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['schema'] == 1
"
}

# ── Bands ─────────────────────────────────────────────────────────────

@test "exactly four bands, each with the four documented fields" {
  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bands = d['bands']
assert len(bands) == 4, len(bands)
fields = {'min_dbm', 'label', 'tone', 'blurb'}
for b in bands:
    assert set(b.keys()) == fields, sorted(b.keys())
"
}

@test "labels are exactly Excellent, Good, Fair, Weak, strongest first" {
  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
labels = [b['label'] for b in d['bands']]
assert labels == ['Excellent', 'Good', 'Fair', 'Weak'], labels
"
}

@test "tones are good, ok, warn, bad in that order" {
  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
tones = [b['tone'] for b in d['bands']]
assert tones == ['good', 'ok', 'warn', 'bad'], tones
"
}

@test "only the weakest band has a null min_dbm — every other band is a real integer" {
  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bands = d['bands']
for b in bands[:-1]:
    assert isinstance(b['min_dbm'], int), b
assert bands[-1]['min_dbm'] is None, bands[-1]
"
}

@test "min_dbm strictly decreases band over band" {
  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
vals = [b['min_dbm'] for b in d['bands'] if b['min_dbm'] is not None]
assert vals == sorted(vals, reverse=True) and len(set(vals)) == len(vals), vals
"
}

@test "blurbs are non-empty prose" {
  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for b in d['bands']:
    assert isinstance(b['blurb'], str) and len(b['blurb'].strip()) > 10, b
"
}

# ── Boundaries come from lib/thresholds.sh, not a second copy ───────────
# bin/netdiag re-sources lib/thresholds.sh on every invocation, so an
# env override made *before* calling the CLI would just be clobbered —
# these two call the helper directly, the same way test_show.bats drives
# helpers/history.py's THRESH_COMPARE_* to prove the wiring is live.

@test "bands are the live values in lib/thresholds.sh" {
  local excellent good fair
  excellent="$(grep -m1 '^THRESH_WIFI_RSSI_EXCELLENT_DBM=' "$REPO/lib/thresholds.sh" | cut -d= -f2)"
  good="$(grep -m1 '^THRESH_WIFI_RSSI_G1_DBM=' "$REPO/lib/thresholds.sh" | cut -d= -f2)"
  fair="$(grep -m1 '^THRESH_WIFI_RSSI_WEAK_DBM=' "$REPO/lib/thresholds.sh" | cut -d= -f2)"
  [ -n "$excellent" ]; [ -n "$good" ]; [ -n "$fair" ]

  run "$NETDIAG" --signal-scale
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
by_label = {b['label']: b['min_dbm'] for b in d['bands']}
assert by_label['Excellent'] == int(sys.argv[1]), by_label
assert by_label['Good'] == int(sys.argv[2]), by_label
assert by_label['Fair'] == int(sys.argv[3]), by_label
" "$excellent" "$good" "$fair"
}

@test "changing a threshold moves the matching boundary" {
  # Proves the helper reads the environment live rather than carrying its
  # own copy — the regression this guards against is a hardcoded -55/-70/
  # -75 sitting next to the real constants and silently drifting from them.
  run env THRESH_WIFI_RSSI_EXCELLENT_DBM=-40 THRESH_WIFI_RSSI_G1_DBM=-70 \
      THRESH_WIFI_RSSI_WEAK_DBM=-75 python3 "$HELPERS/signal_scale.py"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
by_label = {b['label']: b['min_dbm'] for b in d['bands']}
assert by_label['Excellent'] == -40, by_label
"
}

@test "helper refuses to run without THRESH_WIFI_RSSI_EXCELLENT_DBM" {
  run env -u THRESH_WIFI_RSSI_EXCELLENT_DBM THRESH_WIFI_RSSI_G1_DBM=-70 \
      THRESH_WIFI_RSSI_WEAK_DBM=-75 python3 "$HELPERS/signal_scale.py"
  [ "$status" -eq 3 ]
  [[ "$output" == *"THRESH_WIFI_RSSI_EXCELLENT_DBM"* ]]
  [[ "$output" == *"lib/thresholds.sh"* ]]
}

@test "helper refuses to run without THRESH_WIFI_RSSI_G1_DBM" {
  # -u has to precede the name=value assignments: BSD env (macOS) parses
  # options before assignments, not interleaved.
  run env -u THRESH_WIFI_RSSI_G1_DBM THRESH_WIFI_RSSI_EXCELLENT_DBM=-55 \
      THRESH_WIFI_RSSI_WEAK_DBM=-75 python3 "$HELPERS/signal_scale.py"
  [ "$status" -eq 3 ]
  [[ "$output" == *"THRESH_WIFI_RSSI_G1_DBM"* ]]
}

@test "helper refuses to run without THRESH_WIFI_RSSI_WEAK_DBM" {
  run env -u THRESH_WIFI_RSSI_WEAK_DBM THRESH_WIFI_RSSI_EXCELLENT_DBM=-55 \
      THRESH_WIFI_RSSI_G1_DBM=-70 python3 "$HELPERS/signal_scale.py"
  [ "$status" -eq 3 ]
  [[ "$output" == *"THRESH_WIFI_RSSI_WEAK_DBM"* ]]
}

@test "a non-numeric threshold is refused, not silently coerced" {
  run env THRESH_WIFI_RSSI_EXCELLENT_DBM=not-a-number \
      THRESH_WIFI_RSSI_G1_DBM=-70 THRESH_WIFI_RSSI_WEAK_DBM=-75 \
      python3 "$HELPERS/signal_scale.py"
  [ "$status" -eq 3 ]
  [[ "$output" == *"THRESH_WIFI_RSSI_EXCELLENT_DBM"* ]]
}

# ── Unknown-flag behavior is unaffected ──────────────────────────────────

@test "an unrelated unknown flag still exits 3, not 0 or 2" {
  run "$NETDIAG" --this-flag-does-not-exist
  [ "$status" -eq 3 ]
}
