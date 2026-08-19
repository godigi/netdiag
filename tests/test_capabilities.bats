#!/usr/bin/env bats
#
# netdiag --version / --capabilities — the handshake a GUI uses to find
# out what its CLI actually supports before it relies on a feature,
# rather than parsing --version's semver and guessing. Both are early
# exits: no probing, no log file, no network — and an unrelated unknown
# flag must still exit 3, so an old GUI's error handling keeps working
# against a new CLI.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/netdiag"
  HELPERS="$REPO/helpers"
  VERSION="$(grep -m1 '^NETDIAG_VERSION=' "$REPO/bin/netdiag" \
    | sed -E 's/^NETDIAG_VERSION="([^"]*)"/\1/')"
  [ -n "$VERSION" ]
}

# ── --version ──────────────────────────────────────────────────────────

@test "--version prints netdiag VERSION and exits 0" {
  run "$NETDIAG" --version
  [ "$status" -eq 0 ]
  [ "$output" = "netdiag $VERSION" ]
}

@test "--version is documented in --help" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--version"* ]]
}

# ── --capabilities: shape ────────────────────────────────────────────────

@test "--capabilities exits 0 and prints one parseable JSON object" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
  # One compact line, like every machine-consumed sibling output — a
  # pretty-printed document would also parse, so pin the actual contract.
  [[ "$output" != *$'\n'* ]]
}

@test "--capabilities writes nothing under HOME — no log, no history append" {
  run bash -c "HOME='$BATS_TEST_TMPDIR' '$NETDIAG' --capabilities"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/net-diag" ]
}

@test "--capabilities is documented in --help" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--capabilities"* ]]
}

# ── --capabilities: content ──────────────────────────────────────────────

@test "version equals the running NETDIAG_VERSION" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['version'] == sys.argv[1], d['version']
" "$VERSION"
}

@test "deps carries exactly the six documented keys" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)['deps']
assert set(d) == {'bash', 'python3', 'jq', 'speedtest', 'mtr', 'gping'}, sorted(d)
"
}

@test "deps.bash is a dotted major.minor.patch" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
v = json.load(sys.stdin)['deps']['bash']
parts = v.split('.')
assert len(parts) == 3 and all(p.isdigit() for p in parts), v
"
}

@test "deps.jq/mtr/gping are booleans, not strings" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)['deps']
for k in ('jq', 'mtr', 'gping'):
    assert isinstance(d[k], bool), (k, d[k])
"
}

@test "deps.speedtest is ookla, cli, or null — never any other string" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
v = json.load(sys.stdin)['deps']['speedtest']
assert v in ('ookla', 'cli', None), v
"
}

@test "deps reflect what is actually on PATH — not just well-typed defaults" {
  # A broken env-var wire between bash and the helper still emits a
  # well-formed document, just a wrong one (everything false/null). Gate
  # each assertion on the dep's real presence, so this stays green on a
  # bare CI runner while catching that wiring break on any machine that
  # has the tool installed.
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  local caps="$output" dep
  for dep in jq mtr gping; do
    if command -v "$dep" >/dev/null 2>&1; then
      printf '%s' "$caps" | python3 -c "
import json, sys
assert json.load(sys.stdin)['deps'][sys.argv[1]] is True, sys.argv[1]
" "$dep"
    fi
  done
  if command -v speedtest >/dev/null 2>&1 || command -v speedtest-cli >/dev/null 2>&1; then
    printf '%s' "$caps" | python3 -c "
import json, sys
assert json.load(sys.stdin)['deps']['speedtest'] in ('ookla', 'cli')
"
  fi
}

@test "features contains the modes this task documents" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
f = json.load(sys.stdin)['features']
for name in ('monitor', 'history', 'show', 'progress'):
    assert name in f, name
"
}

@test "every features entry maps to a real flag in --help" {
  # Ties the hand-maintained FEATURES list to actual CLI surface, so a
  # renamed or removed flag fails here instead of shipping a stale name
  # to the GUI. "watcher" is the one convention break: it stands for the
  # --install-watcher / --uninstall-watcher pair.
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  local features
  features="$(printf '%s' "$output" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["features"]))')"
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  local feat
  while IFS= read -r feat; do
    case "$feat" in
      watcher) [[ "$output" == *"--install-watcher"* ]] ;;
      *)       [[ "$output" == *"--$feat"* ]] ;;
    esac
  done <<< "$features"
}

@test "schemas has exactly the seven documented keys, all integers" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
s = json.load(sys.stdin)['schemas']
assert set(s) == {'run', 'monitor', 'history', 'show', 'rules_catalog',
                   'signal_scale', 'progress'}, sorted(s)
for v in s.values():
    assert isinstance(v, int), s
"
}

# ── schemas vs. live output — cheap, network-free anti-drift checks ──────
# Each compares the capabilities document against the *actual* value the
# corresponding mode emits today, read from the source of truth rather
# than hardcoded here, so a bump in one place that forgets the other
# fails this test instead of shipping silently.

@test "schemas.history matches what netdiag --history actually emits" {
  # An empty store still emits a complete object (test_history.bats), so
  # this touches no network.
  run bash -c "HOME='$BATS_TEST_TMPDIR' '$NETDIAG' --history"
  [ "$status" -eq 0 ]
  local hist_schema
  hist_schema="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')"
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert str(json.load(sys.stdin)['schemas']['history']) == sys.argv[1]
" "$hist_schema"
}

@test "schemas.show matches the constant build_detail() stamps on --show output" {
  # "schema": appears twice in helpers/history.py — build_detail() for
  # --show and main() for --history — so scope the read to build_detail's
  # body rather than grepping the whole file.
  local show_const
  show_const="$(python3 - "$HELPERS/history.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
body = src.split("def build_detail", 1)[1].split("\ndef ", 1)[0]
m = re.search(r'"schema":\s*(\d+)', body)
print(m.group(1) if m else "")
PY
)"
  [ -n "$show_const" ]
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert str(json.load(sys.stdin)['schemas']['show']) == sys.argv[1]
" "$show_const"
}

@test "schemas.rules_catalog matches the constant helpers/rules_catalog.py stamps on its output" {
  local const
  const="$(grep -m1 '^SCHEMA_RULES_CATALOG = ' "$HELPERS/rules_catalog.py" \
    | sed -E 's/^SCHEMA_RULES_CATALOG = ([0-9]+).*/\1/')"
  [ -n "$const" ]
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert str(json.load(sys.stdin)['schemas']['rules_catalog']) == sys.argv[1]
" "$const"
}

@test "schemas.signal_scale matches the constant helpers/signal_scale.py stamps on its output" {
  local const
  const="$(grep -m1 '^SCHEMA_SIGNAL_SCALE = ' "$HELPERS/signal_scale.py" \
    | sed -E 's/^SCHEMA_SIGNAL_SCALE = ([0-9]+).*/\1/')"
  [ -n "$const" ]
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert str(json.load(sys.stdin)['schemas']['signal_scale']) == sys.argv[1]
" "$const"
}

@test "schemas.monitor matches the constant lib/monitor.sh stamps on a sample" {
  # Network-free like tests/test_monitor.bats: read the constant from the
  # source rather than running --monitor, which pings the gateway.
  local mon_const
  mon_const="$(grep -m1 'NETDIAG_MON_SCHEMA=' "$REPO/lib/monitor.sh" \
    | sed -E 's/.*NETDIAG_MON_SCHEMA=([0-9]+).*/\1/')"
  [ -n "$mon_const" ]
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert str(json.load(sys.stdin)['schemas']['monitor']) == sys.argv[1]
" "$mon_const"
}

# ── Unknown-flag behavior is unaffected ──────────────────────────────────

@test "an unrelated unknown flag still exits 3, not 0 or 2" {
  run "$NETDIAG" --this-flag-does-not-exist
  [ "$status" -eq 3 ]
}

@test "--version short-circuits: a flag after it on the line is never reached" {
  # Same behavior --help already has: exit happens inside the parsing
  # loop, so nothing after --version is parsed.
  run "$NETDIAG" --version --this-flag-does-not-exist
  [ "$status" -eq 0 ]
  [ "$output" = "netdiag $VERSION" ]
}
