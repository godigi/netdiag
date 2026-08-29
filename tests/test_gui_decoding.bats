#!/usr/bin/env bats
#
# Every key RunSnapshot declares is a key RunSnapshot actually decodes.
#
# The bug this exists for: `wan` and `suitability` were declared in
# `CodingKeys`, declared as properties with defaults, and never assigned in
# the hand-written `init(from:)`. Swift's synthesised `Decodable` would have
# caught that; a hand-written init has no such check, so both silently held
# their defaults on every run since they were added — and the app's NAT
# topology row, which reads `s.wan.doubleNat.detected` and
# `s.wan.upnp.state`, could only ever appear because a *rule* fired, never
# because the topology itself said so.
#
# It is a bats test rather than a `--verify` check because it is a fact
# about the source text, not about runtime behaviour: `--verify` can only
# observe the decoded value, which is indistinguishable from a run where
# the field genuinely was absent. That indistinguishability is the whole
# reason the bug survived.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  SNAPSHOT="$REPO/gui/Sources/NetdiagGUI/Models/RunSnapshot.swift"
}

# The CodingKeys case names of RunSnapshot's own (outermost) enum — the one
# at four-space indentation. Nested types declare their own at eight.
outer_coding_keys() {
  python3 - "$SNAPSHOT" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = re.search(
    r'\n    enum CodingKeys: String, CodingKey \{\n(.*?)\n    \}', src, re.S)
assert block, "RunSnapshot's own CodingKeys block not found"
names = []
for line in block.group(1).splitlines():
    line = line.strip()
    if not line.startswith('case '):
        continue
    for part in line[len('case '):].split(','):
        names.append(part.split('=')[0].strip())
print('\n'.join(n for n in names if n))
PY
}

# The properties RunSnapshot's own init(from:) assigns.
outer_assignments() {
  python3 - "$SNAPSHOT" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = re.search(
    r'\n    init\(from decoder: Decoder\) throws \{\n(.*?)\n    \}', src, re.S)
assert block, "RunSnapshot's own init(from:) not found"
print('\n'.join(sorted(set(re.findall(r'^\s*(\w+) = c\.lenient',
                                      block.group(1), re.M)))))
PY
}

@test "every declared CodingKey is assigned in init(from:)" {
  keys="$(outer_coding_keys)"
  assigned="$(outer_assignments)"
  [ -n "$keys" ]
  [ -n "$assigned" ]
  missing=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    printf '%s\n' "$assigned" | grep -qx "$k" || missing="$missing $k"
  done <<< "$keys"
  [ -z "$missing" ] || { echo "declared but never decoded:$missing"; return 1; }
}

@test "every assignment corresponds to a declared CodingKey" {
  # The other direction. An assignment with no key cannot compile, so this
  # is cheap insurance against the parser above silently matching nothing
  # — a guard that finds no keys would pass the test above for free.
  keys="$(outer_coding_keys)"
  assigned="$(outer_assignments)"
  orphans=""
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf '%s\n' "$keys" | grep -qx "$a" || orphans="$orphans $a"
  done <<< "$assigned"
  [ -z "$orphans" ] || { echo "assigned but not declared:$orphans"; return 1; }
}

@test "the parity guard would catch a key that is only declared" {
  # A grep-shaped guard that matches nothing passes for the wrong reason.
  # Plant one and prove the comparison actually fails.
  # Insert the key by *structure*, not by matching one line's exact text:
  # the first version of this test sed'd for a specific `case ...` line and
  # silently stopped planting anything the moment a real key was added to
  # it — passing for the wrong reason, which is exactly the failure this
  # whole file exists to catch one level up. It has now been caught doing
  # that twice, on two different branches, which is why it inserts by
  # structure instead.
  planted="$BATS_TEST_TMPDIR/planted.swift"
  python3 - "$SNAPSHOT" "$planted" <<'PLANT'
import re, sys
src = open(sys.argv[1]).read()
patched, n = re.subn(r'(\n    enum CodingKeys: String, CodingKey \{\n)',
                     r'\1        case plantedKey\n', src, count=1)
assert n == 1, "could not find RunSnapshot's CodingKeys block to plant into"
open(sys.argv[2], 'w').write(patched)
PLANT
  run grep -c 'plantedKey' "$planted"
  [ "$output" = "1" ]
  # Re-run the real parsers against the planted file.
  keys="$(SNAPSHOT="$planted" outer_coding_keys)"
  assigned="$(SNAPSHOT="$planted" outer_assignments)"
  printf '%s\n' "$assigned" | grep -qx plantedKey && {
    echo "planted key was somehow assigned"; return 1; }
  printf '%s\n' "$keys" | grep -qx plantedKey || {
    echo "planted key was not even parsed out"; return 1; }
}

@test "the committed sample carries the keys the app decodes" {
  # End to end against examples/sample-output.json — the real capture the
  # README points at, so a schema change that silently stops emitting one
  # of these is caught by the same file a reader is told to trust.
  #
  # `suitability` is deliberately not in this list: no `suitability` key is
  # emitted anywhere in helpers/ or lib/, and no view reads the property.
  # It is decoded only so the parity guard above holds. Asserting it here
  # would be asserting a field this project does not have.
  [ -f "$REPO/examples/sample-output.json" ]
  run python3 -c "
import json
d = json.load(open('$REPO/examples/sample-output.json'))
for k in ('wan', 'watcher'):
    assert k in d, k
print(d['wan']['upnp']['state'])
"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
