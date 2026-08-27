#!/usr/bin/env bats
#
# netdiag --rules-catalog — the plain-English layer a GUI shows next to a
# rule-ID chip, because CLAUDE.md forbids diagnostic prose in gui/. Same
# family as test_capabilities.bats: an early exit, no probing, no log
# file, no network.
#
# THE LOAD-BEARING TEST is "catalog matches every add_diag / _mon_add_rule
# call site" below. Everything else here is shape-checking; that one is
# the thing that makes a forgotten rule fail CI instead of shipping a
# GUI that can't explain it.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  NETDIAG="$REPO/bin/netdiag"
  HELPERS="$REPO/helpers"
  VERSION="$(grep -m1 '^NETDIAG_VERSION=' "$REPO/bin/netdiag" \
    | sed -E 's/^NETDIAG_VERSION="([^"]*)"/\1/')"
  [ -n "$VERSION" ]
}

# ── Shape ─────────────────────────────────────────────────────────────

@test "--rules-catalog exits 0 and prints one parseable JSON object" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -m json.tool >/dev/null
  # One compact line, like --capabilities and every other machine-consumed
  # sibling output.
  [[ "$output" != *$'\n'* ]] || return 1
}

@test "--rules-catalog writes nothing under HOME — no log, no history append" {
  run bash -c "HOME='$BATS_TEST_TMPDIR' '$NETDIAG' --rules-catalog"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/net-diag" ]
}

@test "--rules-catalog is documented in --help" {
  run "$NETDIAG" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--rules-catalog"* ]] || return 1
}

@test "--rules-catalog appears in --capabilities features" {
  run "$NETDIAG" --capabilities
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert 'rules-catalog' in json.load(sys.stdin)['features']
"
}

@test "version equals the running NETDIAG_VERSION" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['version'] == sys.argv[1], d['version']
" "$VERSION"
}

@test "schema is 2" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
assert json.load(sys.stdin)['schema'] == 2
"
}

# ── metrics glossary ──────────────────────────────────────────────────

@test "metrics glossary covers at least the terms the report card shows" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
keys = {m['key'] for m in d['metrics']}
required = {'router', 'internet', 'dns', 'wifi_signal', 'bufferbloat',
            'mtu', 'speed', 'clock', 'packet_loss', 'latency', 'jitter'}
missing = required - keys
assert not missing, missing
"
}

@test "every metrics entry has exactly key/label/help, all non-empty" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
fields = {'key', 'label', 'help'}
for m in d['metrics']:
    assert set(m.keys()) == fields, (m.get('key'), sorted(m.keys()))
    for k, v in m.items():
        assert isinstance(v, str) and v.strip(), (m.get('key'), k, v)
"
}

@test "metrics keys are unique" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
keys = [m['key'] for m in d['metrics']]
assert len(keys) == len(set(keys)), sorted(set(k for k in keys if keys.count(k) > 1))
"
}

@test "glossary help text embeds no numeric threshold — dBm, %, ms, or bare digits" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
pattern = re.compile(r'[0-9](?:\s?(?:dbm|db|ms|%|seconds?|bytes?))', re.IGNORECASE)
bad = [(m['key'], pattern.findall(m['help'])) for m in d['metrics'] if pattern.search(m['help'])]
assert not bad, bad
"
}

# ── Every entry: complete, well-typed, closed-set fields ────────────────

@test "every entry has all 7 fields, non-empty" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
fields = {'id', 'title', 'category', 'severity', 'scope', 'blurb', 'doc'}
for r in d['rules']:
    assert set(r.keys()) == fields, (r.get('id'), sorted(r.keys()))
    for k, v in r.items():
        assert isinstance(v, str) and v.strip(), (r.get('id'), k, v)
"
}

@test "every entry's category is from the closed set" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
allowed = {'router', 'internet', 'dns', 'wifi', 'load', 'mtu', 'speed',
           'clock', 'ipv6', 'vpn', 'lan', 'dhcp', 'topology', 'baseline'}
d = json.load(sys.stdin)
for r in d['rules']:
    assert r['category'] in allowed, (r['id'], r['category'])
"
}

@test "every entry's severity is from the closed set" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
allowed = {'info', 'warn', 'critical', 'varies'}
d = json.load(sys.stdin)
for r in d['rules']:
    assert r['severity'] in allowed, (r['id'], r['severity'])
"
}

@test "every entry's scope is from the closed set" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
allowed = {'scan', 'monitor', 'both'}
d = json.load(sys.stdin)
for r in d['rules']:
    assert r['scope'] in allowed, (r['id'], r['scope'])
"
}

@test "B1, B2, M1, NT-1 are severity 'varies' — they grade by magnitude" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
by_id = {r['id']: r for r in d['rules']}
for rid in ('B1', 'B2', 'M1', 'NT-1'):
    assert by_id[rid]['severity'] == 'varies', (rid, by_id[rid]['severity'])
"
}

@test "scope is derived from the call sites, not hand-maintained" {
  # A rule's scope must equal what the code actually does: an add_diag
  # call site makes it scan, a _mon_add_rule site makes it monitor, both
  # make it both. Derived with the same quote-tolerant extraction the
  # load-bearing test uses, so a rule newly wired into the monitor can't
  # keep claiming scope "scan" silently — that would tell the GUI a rule
  # it just received on the stream can't appear there.
  local q="['\"]"
  local scan_set mon_set
  scan_set="$(grep -ohE "add_diag[[:space:]]+${q}?(critical|warn|info)${q}?[[:space:]]+${q}?[A-Za-z0-9_-]+${q}?" \
    "$REPO/bin/netdiag" "$REPO"/lib/*.sh | awk '{print $NF}' | tr -d '"' | tr -d "'" | sort -u)"
  mon_set="$(grep -ohE "_mon_add_rule[[:space:]]+${q}?(critical|warn|info)${q}?[[:space:]]+${q}?[A-Za-z0-9_-]+${q}?" \
    "$REPO/bin/netdiag" "$REPO"/lib/*.sh | awk '{print $NF}' | tr -d '"' | tr -d "'" | sort -u)"
  [ -n "$scan_set" ]
  [ -n "$mon_set" ]
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
scan = set(sys.argv[1].split())
mon = set(sys.argv[2].split())
for r in json.load(sys.stdin)['rules']:
    rid = r['id']
    expect = 'both' if (rid in scan and rid in mon) else ('monitor' if rid in mon else 'scan')
    assert r['scope'] == expect, (rid, r['scope'], expect)
" "$scan_set" "$mon_set"
}

@test "blurbs embed no numeric threshold — dBm, %, ms, or bare digits" {
  # Thresholds live in exactly one place: lib/thresholds.sh. A number in a
  # blurb would be a second, driftable copy of a cutoff docs/DIAGNOSIS-RULES.md
  # already states precisely. Flags common unit-attached numbers; not a
  # full parser, but enough to catch a copy-pasted "-75 dBm" or "20%".
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
pattern = re.compile(r'[0-9](?:\s?(?:dbm|db|ms|%|seconds?|bytes?))', re.IGNORECASE)
bad = [(r['id'], pattern.findall(r['blurb'])) for r in d['rules'] if pattern.search(r['blurb'])]
assert not bad, bad
"
}

@test "doc anchors resolve to real headings in DIAGNOSIS-RULES.md" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  local catalog="$output"
  python3 -c "
import json, re, sys

def github_anchor(text):
    t = text.lower()
    t = re.sub(r'[^\w\s-]', '', t, flags=re.UNICODE)
    return t.replace(' ', '-')

headings = []
with open(sys.argv[1]) as f:
    for line in f:
        if line.startswith('### '):
            headings.append(github_anchor(line[4:].strip()))
anchors = set(headings)

d = json.loads(sys.argv[2])
bad = []
for r in d['rules']:
    doc = r['doc']
    assert doc.startswith('DIAGNOSIS-RULES.md#'), (r['id'], doc)
    anchor = doc.split('#', 1)[1]
    if anchor not in anchors:
        bad.append((r['id'], anchor))
assert not bad, bad
" "$REPO/docs/DIAGNOSIS-RULES.md" "$catalog"
}

@test "rule ids are unique" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ids = [r['id'] for r in d['rules']]
assert len(ids) == len(set(ids)), sorted(set(x for x in ids if ids.count(x) > 1))
"
}

# ── THE LOAD-BEARING TEST ────────────────────────────────────────────────
# The set of rule IDs the shell code can actually emit must equal the
# catalog's ID set, minus documented exclusions (UP-1: reserved in
# docs/DIAGNOSIS-RULES.md, never emitted — no add_diag call exists for it
# anywhere in the tree). A rule added to lib/*.sh or lib/monitor.sh
# without a matching catalog entry fails here, not silently in the GUI.
#
# The extraction pattern tolerates an optional single or double quote
# around both the severity and the rule-ID token — add_diag warn "XX-1"
# extracts the same ID as add_diag warn XX-1 — because a regex that only
# matched the unquoted form would silently drop a quoted call site from
# both sides of the comparison at once and this test would keep passing.
# The floor assertion below is the other half of that guard: a pattern
# that stops matching entirely degrades the extracted set toward empty,
# and an empty set can equal an empty catalog read just as easily as a
# real mismatch — the floor forces that failure to be loud instead.

@test "catalog's rule IDs exactly match every add_diag / _mon_add_rule call site" {
  # Every add_diag / _mon_add_rule call site in this tree passes its
  # severity and rule ID as literal tokens, optionally quoted (never a
  # variable) — verified by eye against lib/diagnosis.sh, lib/wan.sh,
  # lib/output.sh and lib/monitor.sh when this test was written. A future
  # call site that passes a variable would silently vanish from this
  # extraction rather than fail loud, which is why this comment exists:
  # check by eye again if this test ever needs updating for a new call
  # site.
  #
  # _mon_add_rule is grepped across lib/*.sh, not just lib/monitor.sh —
  # it is only defined and called there today, but grepping the whole
  # directory costs nothing and stays correct if that ever changes.
  local q="['\"]"
  local add_diag_re="add_diag[[:space:]]+${q}?(critical|warn|info)${q}?[[:space:]]+${q}?[A-Za-z0-9_-]+${q}?"
  local mon_add_rule_re="_mon_add_rule[[:space:]]+${q}?(critical|warn|info)${q}?[[:space:]]+${q}?[A-Za-z0-9_-]+${q}?"

  # bin/netdiag is included even though no call site lives there today:
  # an add_diag added to the entry point would otherwise vanish from both
  # sides of the comparison at once.
  local extracted
  extracted="$(
    { grep -ohE "$add_diag_re" "$REPO/bin/netdiag" "$REPO"/lib/*.sh
      grep -ohE "$mon_add_rule_re" "$REPO/bin/netdiag" "$REPO"/lib/*.sh
    } | awk '{print $NF}' | tr -d '"' | tr -d "'" | sort -u
  )"
  [ -n "$extracted" ]

  # Documented exclusion: UP-1 is reserved (docs/DIAGNOSIS-RULES.md) and
  # never emitted. Strip it defensively in case it's ever wired up without
  # updating this test — the assertion below would then simply start
  # failing on a real mismatch instead of masking one.
  extracted="$(printf '%s\n' "$extracted" | grep -v '^UP-1$' || true)"

  # Floor: today's tree extracts 33. A regex that stops matching (a typo
  # in this test, a call-site style the pattern didn't anticipate) would
  # otherwise degrade silently to "both sets are empty, so they're equal"
  # — see the comment above the @test block.
  local extracted_count
  extracted_count="$(printf '%s\n' "$extracted" | grep -c '.')"
  [ "$extracted_count" -ge 25 ]

  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  local catalog_ids
  catalog_ids="$(printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("\n".join(sorted(r["id"] for r in d["rules"])))
')"

  local extracted_sorted
  extracted_sorted="$(printf '%s\n' "$extracted" | sort -u)"

  [ "$extracted_sorted" = "$catalog_ids" ]
}

@test "UP-1 is not in the catalog — reserved, never emitted" {
  run "$NETDIAG" --rules-catalog
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ids = {r['id'] for r in d['rules']}
assert 'UP-1' not in ids
"
  # And confirm the premise: no add_diag call for UP-1 exists anywhere.
  run bash -c "grep -RhE 'add_diag[[:space:]]+(critical|warn|info)[[:space:]]+UP-1' '$REPO'/lib/*.sh"
  [ "$status" -ne 0 ]
}

# ── Unknown-flag behavior is unaffected ──────────────────────────────────

@test "an unrelated unknown flag still exits 3, not 0 or 2" {
  run "$NETDIAG" --this-flag-does-not-exist
  [ "$status" -eq 3 ]
}
