# Dropdown Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the menu-bar dropdown as an adaptive stage over fixed instruments and a 24-hour change timeline, fed by a new CLI-authored `changes` array on `--monitor` samples.

**Architecture:** The CLI grows change detection: `lib/monitor.sh` snapshots the previous sample's identity fields and passes them to `helpers/monitor_sample.py`, which emits a `changes` array (id, field, from, to, CLI-authored summary) and bumps the monitor schema to 2. The GUI grows an `EventStore` (persisted, pruned) fed from `changes` and fired alerts, and `DropdownView` is rewritten as stage → instrument grid → heartbeat → timeline → CTA → footer.

**Tech Stack:** bash 5 + python3 (CLI), bats-core (CLI tests), SwiftUI/SwiftPM macOS 14 (GUI), swift-testing via XCTest (new GUI test target).

**Spec:** `docs/superpowers/specs/2026-08-17-dropdown-redesign-design.md`

---

## Preconditions and cautions

1. **The main worktree is dirty with unrelated in-flight work** (L1/L2/ICMP-1 loss rules: `lib/monitor.sh`, `lib/diagnosis.sh`, `AlertDefinitions.swift`, `NetdiagCoordinator.swift`, `DropdownView.swift`, `HistoryStore.swift`, and untracked `LocationPermissionStore.swift`). This plan was written against that **working-tree state** — e.g. it relies on `HistoryStore.latestSpeedTest(for:)`, which only exists uncommitted. **Land or commit the in-flight work before starting.** If you must use a fresh worktree from HEAD instead, Tasks 4–7 will not apply cleanly.
2. **Commits must stage named files only** (`git add <paths>`, never `git add -A`) so unrelated in-flight edits are not swept in.
3. Line numbers below are from the working tree at plan time; treat them as anchors, not gospel — locate by the quoted code.
4. All bash must stay shellcheck-clean at default severity. No new numeric comparisons like `[ "$x" -gt 5 ]` in `lib/monitor.sh` — `tests/test_monitor.bats` greps for inline cutoffs and fails CI. (Equality string comparisons are fine, and are all this feature needs.)
5. Run CLI tests with: `bats tests/test_monitor.bats` (and others as named). Build the GUI with `cd gui && swift build`. Never launch `.build/release/NetdiagGUI` directly — use `make -C gui run` (unbundled binaries can't use UNUserNotificationCenter).

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `helpers/monitor_sample.py` | modify | Compute `changes` from `NETDIAG_MON_PREV_*` env; phrase summaries; emit key only when non-empty |
| `lib/monitor.sh` | modify | Hold `MON_PREV_*` globals, snapshot after each emit, pass prev env vars; bump `NETDIAG_MON_SCHEMA` to 2 |
| `helpers/capabilities.py` | modify | `SCHEMA_MONITOR = 2` |
| `tests/test_monitor.bats` | modify | Change-detection tests (helper-direct `emit()` style) + snapshot-function tests |
| `docs/JSON-SCHEMA.md` | modify | Monitor sample v2 (`changes`), conventions, capabilities literal |
| `docs/superpowers/specs/2026-08-17-dropdown-redesign-design.md` | modify | Amend gating mechanism (schemas.monitor ≥ 2, not a feature string) |
| `gui/Sources/NetdiagGUI/Models/MonitorSample.swift` | modify | Decode `changes` leniently |
| `gui/Sources/NetdiagGUI/Models/NetworkEvent.swift` | create | Event value type + pure prune/derive helpers |
| `gui/Sources/NetdiagGUI/Services/EventStore.swift` | create | Persisted, pruned event log (Application Support) |
| `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift` | modify | Own `EventStore`; feed it from `handleSample` and `handleAlertFired` |
| `gui/Sources/NetdiagGUI/Views/DropdownComponents.swift` | create | InstrumentCell, LocationCell, HeartbeatStrip, TimelineBand, EventRow |
| `gui/Sources/NetdiagGUI/Views/DropdownView.swift` | rewrite | Stage machine + fixed sections |
| `gui/Package.swift` | modify | Add test target |
| `gui/Tests/NetdiagGUITests/NetworkEventTests.swift` | create | Prune + time-since-last-change tests |
| `CHANGELOG.md` | modify | v2 monitor schema + dropdown redesign entries |

---

### Task 1: `changes` computation in `helpers/monitor_sample.py`

**Files:**
- Modify: `helpers/monitor_sample.py` (main() ~line 104-182; conventions `_env` ~32, `_tri` ~57)
- Test: `tests/test_monitor.bats` (helper-direct style; `emit()` helper is at ~line 225-227)

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_monitor.bats`, after the existing `monitor_sample:` block (the `emit()` helper `env -i PATH="$PATH" "$@" python3 "$HELPERS/monitor_sample.py"` is already defined at ~225):

```bash
# ── monitor_sample: changes (schema 2) ──────────────────────────────────

@test "monitor_sample: no previous sample, no changes key" {
  run emit NETDIAG_MON_HAVE_PREV=0 \
           NETDIAG_MON_PUB_IP=203.0.113.42 NETDIAG_MON_PREV_PUB_IP=198.51.100.7
  printf '%s' "$output" | python3 -c "
import json,sys
assert 'changes' not in json.load(sys.stdin)
"
}

@test "monitor_sample: identical samples emit no changes key" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_PUB_IP=203.0.113.42 NETDIAG_MON_PREV_PUB_IP=203.0.113.42 \
           NETDIAG_MON_RULES='G2 ' NETDIAG_MON_PREV_RULES='G2 '
  printf '%s' "$output" | python3 -c "
import json,sys
assert 'changes' not in json.load(sys.stdin)
"
}

@test "monitor_sample: public IP change is phrased by the CLI" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_PUB_IP=203.0.113.42 NETDIAG_MON_PREV_PUB_IP=198.51.100.7
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert len(ch) == 1, ch
assert ch[0]['id'] == 'public-ip-changed'
assert ch[0]['field'] == 'public.ip'
assert ch[0]['from'] == '198.51.100.7' and ch[0]['to'] == '203.0.113.42'
assert ch[0]['summary'] == 'Public IP changed: 198.51.100.7 → 203.0.113.42'
"
}

@test "monitor_sample: unmeasured side suppresses the change" {
  # null means "not measured", not a value — first slow-tier result is
  # not a change (stream convention, docs/JSON-SCHEMA.md).
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_PUB_IP=203.0.113.42 NETDIAG_MON_PREV_PUB_IP=
  printf '%s' "$output" | python3 -c "
import json,sys
assert 'changes' not in json.load(sys.stdin)
"
}

@test "monitor_sample: country move phrased as VPN exit when VPN is up" {
  run emit NETDIAG_MON_HAVE_PREV=1 NETDIAG_MON_VPN_ACTIVE=1 \
           NETDIAG_MON_PREV_VPN_ACTIVE=1 \
           NETDIAG_MON_PUB_CC=Brazil NETDIAG_MON_PREV_PUB_CC=Germany
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert ch[0]['id'] == 'country-changed'
assert ch[0]['summary'] == 'VPN exit moved: Germany → Brazil'
"
}

@test "monitor_sample: vpn drop and reconnect phrase both directions" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_VPN_ACTIVE=0 NETDIAG_MON_PREV_VPN_ACTIVE=1 \
           NETDIAG_MON_PREV_VPN_NAME=Mullvad
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert ch[0]['id'] == 'vpn-disconnected'
assert ch[0]['summary'] == 'VPN disconnected (Mullvad)'
"
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_VPN_ACTIVE=1 NETDIAG_MON_PREV_VPN_ACTIVE=0 \
           NETDIAG_MON_VPN_NAME=Mullvad
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert ch[0]['id'] == 'vpn-connected'
assert ch[0]['summary'] == 'VPN connected (Mullvad)'
"
}

@test "monitor_sample: ssid with a double quote survives the changes array" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_SSID='Cafe "Sunset" 5G' NETDIAG_MON_PREV_SSID=HomeNet
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
assert ch[0]['id'] == 'wifi-network-changed'
assert ch[0]['to'] == 'Cafe \"Sunset\" 5G'
"
}

@test "monitor_sample: rule transitions emit fired and cleared entries" {
  run emit NETDIAG_MON_HAVE_PREV=1 \
           NETDIAG_MON_RULES='G2 TCP-1 ' NETDIAG_MON_PREV_RULES='VPN-1 TCP-1 '
  printf '%s' "$output" | python3 -c "
import json,sys
ch = json.load(sys.stdin)['changes']
ids = [(c['id'], c.get('from'), c.get('to')) for c in ch]
assert ('rule-fired', None, 'G2') in ids, ids
assert ('rule-cleared', 'VPN-1', None) in ids, ids
assert len(ch) == 2, ch
"
}
```

- [ ] **Step 2: Run the tests, confirm they fail**

Run: `bats tests/test_monitor.bats -f "changes\|no previous\|identical samples\|phrased\|unmeasured\|survives\|transitions"`
Expected: the new tests FAIL (`'changes' not in` ones may pass vacuously — the assertion ones must fail with KeyError on `'changes'`).

- [ ] **Step 3: Implement `_changes()` in `helpers/monitor_sample.py`**

Add above `main()` (match the module's existing helper style — it already has `_env`, `_i`, `_f`, `_tri`):

```python
def _changes() -> list:
    """Field-level diff against the previous sample (NETDIAG_MON_PREV_*).

    None on either side means "not measured" on that side, and an
    unmeasured→measured transition is not a change — same convention as
    the rest of the stream, where null is absence of measurement.
    Rules are the exception: they are always evaluated, so set
    difference is safe. Summaries are user-facing prose; the GUI
    renders them verbatim (CLAUDE.md: no verdict strings in Swift).
    """
    if _env("HAVE_PREV") != "1":
        return []
    out = []

    def diff(now_key, prev_key, cid, field, phrase):
        now, prev = _env(now_key), _env(prev_key)
        if now is None or prev is None or now == prev:
            return
        out.append({"id": cid, "field": field, "from": prev, "to": now,
                    "summary": phrase(prev, now)})

    vpn_now = _env("VPN_ACTIVE") == "1"
    vpn_prev_raw = _env("PREV_VPN_ACTIVE")
    vpn_prev = vpn_prev_raw == "1"
    if vpn_prev_raw is not None and vpn_now != vpn_prev:
        name = _env("VPN_NAME") or _env("PREV_VPN_NAME")
        suffix = f" ({name})" if name else ""
        out.append({
            "id": "vpn-connected" if vpn_now else "vpn-disconnected",
            "field": "vpn.active",
            "from": "1" if vpn_prev else "0",
            "to": "1" if vpn_now else "0",
            "summary": (f"VPN connected{suffix}" if vpn_now
                        else f"VPN disconnected{suffix}"),
        })
    elif vpn_now:
        diff("VPN_NAME", "PREV_VPN_NAME", "vpn-name-changed", "vpn.name",
             lambda a, b: f"VPN changed: {a} → {b}")

    def exit_phrase(a, b):
        return (f"VPN exit moved: {a} → {b}" if vpn_now
                else f"Location changed: {a} → {b}")

    diff("PUB_CC", "PREV_PUB_CC", "country-changed", "public.country",
         exit_phrase)
    diff("PUB_IP", "PREV_PUB_IP", "public-ip-changed", "public.ip",
         lambda a, b: f"Public IP changed: {a} → {b}")
    diff("PUB_ISP", "PREV_PUB_ISP", "isp-changed", "public.isp",
         lambda a, b: f"Internet provider changed: {a} → {b}")
    diff("SSID", "PREV_SSID", "wifi-network-changed", "link.ssid",
         lambda a, b: f"Wi-Fi network changed: {a} → {b}")
    if _env("SSID") == _env("PREV_SSID"):
        diff("BSSID", "PREV_BSSID", "wifi-roamed", "link.bssid",
             lambda a, b: "Roamed to a different Wi-Fi access point")
    diff("INTERFACE", "PREV_INTERFACE", "interface-changed",
         "link.interface",
         lambda a, b: f"Network interface changed: {a} → {b}")

    rules_now = set((_env("RULES") or "").split())
    rules_prev = set((_env("PREV_RULES") or "").split())
    for rid in sorted(rules_now - rules_prev):
        out.append({"id": "rule-fired", "field": "status.rules",
                    "from": None, "to": rid,
                    "summary": f"Issue {rid} detected"})
    for rid in sorted(rules_prev - rules_now):
        out.append({"id": "rule-cleared", "field": "status.rules",
                    "from": rid, "to": None,
                    "summary": f"Issue {rid} cleared"})
    return out
```

In `main()`, after the `doc = {...}` literal and before the `json.dump` call, add:

```python
    changes = _changes()
    if changes:
        doc["changes"] = changes
```

(Key omitted when empty — the "documented top-level keys" test at ~240-249 pins always-present keys and must NOT gain `changes`.)

- [ ] **Step 4: Run the tests, confirm they pass**

Run: `bats tests/test_monitor.bats`
Expected: ALL tests pass (new and pre-existing).

- [ ] **Step 5: Commit**

```bash
git add helpers/monitor_sample.py tests/test_monitor.bats
git commit -m "feat: monitor samples can carry a CLI-phrased changes array

Diff against NETDIAG_MON_PREV_* env; null on either side is 'not
measured' and suppresses the entry; key omitted when nothing changed.
Groundwork for the dropdown change timeline — bash plumbing follows."
```

---

### Task 2: Previous-sample state in `lib/monitor.sh`

**Files:**
- Modify: `lib/monitor.sh` (globals block ~82-131; `_mon_emit` ~449-501; `monitor_run` pause emit ~543-560 and main emit ~605-615)
- Test: `tests/test_monitor.bats` (sourced-function style; `setup()`/`reset_state()` at top of file)

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_monitor.bats` (sourced-function style — `setup()` already sources `lib/monitor.sh`):

```bash
# ── previous-sample snapshot ────────────────────────────────────────────

@test "_mon_snapshot_prev copies identity fields and arms HAVE_PREV" {
  MON_PUB_IP="203.0.113.42"; MON_PUB_CC="Brazil"; MON_PUB_ISP="ExampleNet"
  MON_VPN_ACTIVE=1; MON_VPN_NAME="Mullvad"
  MON_SSID="HomeNet"; MON_BSSID="aa:bb:cc:dd:ee:ff"; MON_INTERFACE="en0"
  MON_RULES="G2 "
  MON_HAVE_PREV=0
  _mon_snapshot_prev
  [ "$MON_HAVE_PREV" = "1" ]
  [ "$MON_PREV_PUB_IP" = "203.0.113.42" ]
  [ "$MON_PREV_PUB_CC" = "Brazil" ]
  [ "$MON_PREV_VPN_ACTIVE" = "1" ]
  [ "$MON_PREV_VPN_NAME" = "Mullvad" ]
  [ "$MON_PREV_SSID" = "HomeNet" ]
  [ "$MON_PREV_BSSID" = "aa:bb:cc:dd:ee:ff" ]
  [ "$MON_PREV_INTERFACE" = "en0" ]
  [ "$MON_PREV_RULES" = "G2 " ]
}

@test "_mon_snapshot_prev keeps last-known identity across an empty sample" {
  # The diff in monitor_sample.py suppresses comparisons where either
  # side is null. If a link-down sample (empty interface/SSID) clobbered
  # the snapshot, en0 → "" → en5 would never report interface-changed.
  # Identity fields keep their last known value; rules and the VPN flag
  # snapshot unconditionally (their empties are meaningful — that is
  # what lets rule-cleared fire).
  MON_PUB_IP="203.0.113.42"; MON_PUB_CC="Brazil"; MON_PUB_ISP="ExampleNet"
  MON_VPN_ACTIVE=1; MON_VPN_NAME="Mullvad"
  MON_SSID="HomeNet"; MON_BSSID="aa:bb:cc:dd:ee:ff"; MON_INTERFACE="en0"
  MON_RULES="G2 "
  _mon_snapshot_prev
  MON_INTERFACE=""; MON_SSID=""; MON_BSSID=""; MON_VPN_NAME=""
  MON_RULES=""; MON_VPN_ACTIVE=0
  _mon_snapshot_prev
  [ "$MON_PREV_INTERFACE" = "en0" ]
  [ "$MON_PREV_SSID" = "HomeNet" ]
  [ "$MON_PREV_BSSID" = "aa:bb:cc:dd:ee:ff" ]
  [ "$MON_PREV_VPN_NAME" = "Mullvad" ]
  [ "$MON_PREV_RULES" = "" ]
  [ "$MON_PREV_VPN_ACTIVE" = "0" ]
}

@test "monitor state block initializes every MON_PREV_ variable" {
  # bin/netdiag runs set -u: an uninitialized MON_PREV_* would abort the
  # first emit. Every var _mon_emit forwards must be declared.
  for v in MON_HAVE_PREV MON_PREV_PUB_IP MON_PREV_PUB_CC MON_PREV_PUB_ISP \
           MON_PREV_VPN_ACTIVE MON_PREV_VPN_NAME MON_PREV_SSID \
           MON_PREV_BSSID MON_PREV_INTERFACE MON_PREV_RULES; do
    grep -qE "^${v}=" "$REPO/lib/monitor.sh" || {
      echo "missing init: $v"; return 1; }
  done
}

@test "_mon_emit forwards prev state to the sample helper" {
  for v in HAVE_PREV PREV_PUB_IP PREV_PUB_CC PREV_PUB_ISP PREV_VPN_ACTIVE \
           PREV_VPN_NAME PREV_SSID PREV_BSSID PREV_INTERFACE PREV_RULES; do
    grep -q "NETDIAG_MON_${v}=" "$REPO/lib/monitor.sh" || {
      echo "not forwarded: $v"; return 1; }
  done
}
```

(If the file's sourced-function tests use a different variable than `$REPO` for the repo root — check `setup()` — match it.)

- [ ] **Step 2: Run, confirm the new tests fail**

Run: `bats tests/test_monitor.bats -f "snapshot\|initializes\|forwards prev"`
Expected: FAIL (`_mon_snapshot_prev: command not found`, missing inits).

- [ ] **Step 3: Implement**

(a) In the globals block (`lib/monitor.sh` ~82-131), append after the existing `MON_*` declarations:

```bash
# Previous-sample identity, for the schema-2 changes array. Snapshotted
# by _mon_snapshot_prev after every successful emit; MON_HAVE_PREV=0
# suppresses a spurious "everything changed" on the first sample.
MON_HAVE_PREV=0
MON_PREV_PUB_IP=""
MON_PREV_PUB_CC=""
MON_PREV_PUB_ISP=""
MON_PREV_VPN_ACTIVE=""
MON_PREV_VPN_NAME=""
MON_PREV_SSID=""
MON_PREV_BSSID=""
MON_PREV_INTERFACE=""
MON_PREV_RULES=""
```

(b) Add the snapshot function directly above `_mon_emit` (~line 449):

```bash
# ── Previous-sample snapshot ─────────────────────────────────────────────
# Called after each successful emit, so the next sample diffs against
# what the consumer actually saw.
#
# Identity fields keep their last KNOWN value: the diff in
# monitor_sample.py suppresses comparisons where either side is null,
# so an empty value here (a link-down sample, a fetch that failed)
# must not erase the baseline — otherwise en0 → "" → en5 never
# reports interface-changed. Rules and the VPN flag are always
# evaluated, so they snapshot unconditionally; their empties are
# meaningful (that is what lets rule-cleared and vpn-disconnected
# fire).
_mon_snapshot_prev() {
  [ -n "$MON_PUB_IP" ]    && MON_PREV_PUB_IP="$MON_PUB_IP"
  [ -n "$MON_PUB_CC" ]    && MON_PREV_PUB_CC="$MON_PUB_CC"
  [ -n "$MON_PUB_ISP" ]   && MON_PREV_PUB_ISP="$MON_PUB_ISP"
  [ -n "$MON_VPN_NAME" ]  && MON_PREV_VPN_NAME="$MON_VPN_NAME"
  [ -n "$MON_SSID" ]      && MON_PREV_SSID="$MON_SSID"
  [ -n "$MON_BSSID" ]     && MON_PREV_BSSID="$MON_BSSID"
  [ -n "$MON_INTERFACE" ] && MON_PREV_INTERFACE="$MON_INTERFACE"
  MON_PREV_VPN_ACTIVE="$MON_VPN_ACTIVE"
  MON_PREV_RULES="$MON_RULES"
  MON_HAVE_PREV=1
  return 0
}
```

(c) In `_mon_emit`, add to the env-prefix list (anywhere before the `python3` line, alongside the other `NETDIAG_MON_*` assignments):

```bash
  NETDIAG_MON_HAVE_PREV="$MON_HAVE_PREV" \
  NETDIAG_MON_PREV_PUB_IP="$MON_PREV_PUB_IP" \
  NETDIAG_MON_PREV_PUB_CC="$MON_PREV_PUB_CC" \
  NETDIAG_MON_PREV_PUB_ISP="$MON_PREV_PUB_ISP" \
  NETDIAG_MON_PREV_VPN_ACTIVE="$MON_PREV_VPN_ACTIVE" \
  NETDIAG_MON_PREV_VPN_NAME="$MON_PREV_VPN_NAME" \
  NETDIAG_MON_PREV_SSID="$MON_PREV_SSID" \
  NETDIAG_MON_PREV_BSSID="$MON_PREV_BSSID" \
  NETDIAG_MON_PREV_INTERFACE="$MON_PREV_INTERFACE" \
  NETDIAG_MON_PREV_RULES="$MON_PREV_RULES" \
```

(d) In `monitor_run`, after **both** emit sites, add the snapshot call:

The pause path (~543-560):
```bash
        _mon_emit "$MONITOR_FAST_INTERVAL" || break
        _mon_snapshot_prev
```
The main path (~612):
```bash
    _mon_emit "$cadence" || break
    _mon_snapshot_prev
```

- [ ] **Step 4: Run tests + shellcheck, confirm clean**

Run: `bats tests/test_monitor.bats && shellcheck bin/netdiag install.sh lib/*.sh`
Expected: all tests pass; shellcheck silent.

- [ ] **Step 5: Smoke the real stream**

Run: `bin/netdiag --monitor --monitor-count 2 --monitor-fast-interval 1 | python3 -c "import json,sys; [json.loads(l) for l in sys.stdin]; print('ok')"`
Expected: `ok` (two parseable samples; a `changes` key may or may not appear depending on live conditions — both are valid).

- [ ] **Step 6: Commit**

```bash
git add lib/monitor.sh tests/test_monitor.bats
git commit -m "feat: monitor snapshots the previous sample for change detection

MON_PREV_* globals (set -u safe), snapshot after every successful emit,
forwarded to monitor_sample.py as NETDIAG_MON_PREV_*."
```

---

### Task 3: Schema 2, capabilities, and docs

**Files:**
- Modify: `lib/monitor.sh:455` (`NETDIAG_MON_SCHEMA=1`)
- Modify: `helpers/capabilities.py:48` (`SCHEMA_MONITOR = 1`)
- Modify: `docs/JSON-SCHEMA.md` (~353-376 sample, ~378-401 conventions, ~745-747 capabilities literal)
- Modify: `docs/superpowers/specs/2026-08-17-dropdown-redesign-design.md`
- Test: `tests/test_capabilities.bats` (~234-247 cross-check — needs no edit, verifies the pair)

- [ ] **Step 1: Bump both schema constants**

In `lib/monitor.sh` `_mon_emit`: `NETDIAG_MON_SCHEMA=1` → `NETDIAG_MON_SCHEMA=2`.
In `helpers/capabilities.py`: `SCHEMA_MONITOR = 1` → `SCHEMA_MONITOR = 2` (keep the trailing comment pointing at `lib/monitor.sh: NETDIAG_MON_SCHEMA`).

- [ ] **Step 2: Run the cross-check tests**

Run: `bats tests/test_capabilities.bats tests/test_monitor.bats`
Expected: PASS — `test_capabilities.bats` greps `NETDIAG_MON_SCHEMA=([0-9]+)` and asserts equality with `schemas.monitor`; if only one side was bumped it fails.

- [ ] **Step 3: Update `docs/JSON-SCHEMA.md`**

In the monitor sample block (~353): change `"schema": 1` → `"schema": 2` and add after the `"status"` line:

```jsonc
  "changes": [                    // schema 2+; ABSENT when nothing changed
    {"id": "vpn-disconnected", "field": "vpn.active",
     "from": "1", "to": "0", "summary": "VPN disconnected (Mullvad)"}
  ]
```

Add a bullet to "Conventions specific to the stream" (~378-401):

```markdown
- **`changes`** (schema 2+) lists field-level differences from the
  *previous emitted sample*, phrased by the CLI: `id` is a stable kind
  (`public-ip-changed`, `country-changed`, `isp-changed`,
  `vpn-connected`, `vpn-disconnected`, `vpn-name-changed`,
  `wifi-network-changed`, `wifi-roamed`, `interface-changed`,
  `rule-fired`, `rule-cleared`), `summary` is display prose consumers
  render verbatim. A null on either side of a comparison means "not
  measured" and suppresses the entry, so a first slow-tier result is
  not a "change"; to keep that sound, the previous-sample snapshot
  retains the last *known* value of every null-suppressed field
  (a link-down sample must not erase the baseline). Rules are the
  deliberate exception — they are always evaluated, so `rule-fired`/
  `rule-cleared` come from plain set difference; do not "fix" the
  rules path to match the null rule. A flapping condition emits one
  fired/cleared pair per transition; consumers that display events
  should be prepared to coalesce repeats. The key is omitted entirely
  when nothing changed — including on every first sample of a run.
  Consumers gate on `--capabilities` `schemas.monitor >= 2`.
```

In the capabilities literal (~745): `"monitor": 1` → `"monitor": 2`.

- [ ] **Step 4: Amend the spec's gating sentence**

In `docs/superpowers/specs/2026-08-17-dropdown-redesign-design.md`, replace the sentence fragment

`Schema: `monitor` bumps 1 → 2; a `monitor_changes` entry joins `--capabilities` features so an older CLI degrades the GUI to a tickless timeline rather than breaking it.`

with

`Schema: `monitor` bumps 1 → 2; the GUI gates the event feed on `--capabilities` `schemas.monitor >= 2`, so an older CLI degrades the GUI to a tickless timeline rather than breaking it. (Not a `features` entry: that list is CI-checked against literal `--help` flags, and this is a schema property, which `schemas` already expresses.)`

- [ ] **Step 5: Run the full CLI suite**

Run: `bats tests/`
Expected: PASS. (If the in-flight L1/L2 work left `MONITOR_VOCABULARY` failing, that failure predates this plan — note it, don't fix it here.)

- [ ] **Step 6: Commit**

```bash
git add lib/monitor.sh helpers/capabilities.py docs/JSON-SCHEMA.md \
        docs/superpowers/specs/2026-08-17-dropdown-redesign-design.md
git commit -m "feat: monitor schema 2 — the stream now describes its own changes

Docs the changes array and its null-suppression rule; consumers gate on
schemas.monitor >= 2 rather than a features flag."
```

---

### Task 4: GUI decodes `changes`

**Files:**
- Modify: `gui/Sources/NetdiagGUI/Models/MonitorSample.swift` (struct ~16-40, CodingKeys, lenient `init(from:)` extension ~205-335)

- [ ] **Step 1: Add the nested type and property**

Inside `struct MonitorSample`, after `var status: Status = .init()`:

```swift
    /// Field-level differences from the previous sample, phrased by the
    /// CLI (schema 2+). Absent — and therefore empty — when nothing
    /// changed. `kind` is the stream's stable `id` string.
    var changes: [Change] = []

    struct Change: Decodable, Sendable, Equatable {
        var kind: String = ""
        var field: String?
        var from: String?
        var to: String?
        var summary: String = ""

        enum CodingKeys: String, CodingKey {
            case kind = "id"
            case field, from, to, summary
        }
    }
```

Add `changes` to the top-level `CodingKeys` (`case gateway, internet, wifi, dns, tcp, status` line → append `, changes`).

- [ ] **Step 2: Extend the lenient decode**

In the hand-written `init(from:)` for `MonitorSample` (in the extensions block ~205+), alongside the other fields:

```swift
        changes = (try? container.decodeIfPresent([Change].self, forKey: .changes)) ?? []
```

Give `Change` a lenient init in the same extensions block, matching the file's house pattern:

```swift
extension MonitorSample.Change {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        field = try? c.decodeIfPresent(String.self, forKey: .field)
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        to = try? c.decodeIfPresent(String.self, forKey: .to)
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
    }
}
```

- [ ] **Step 3: Build**

Run: `cd gui && swift build`
Expected: succeeds, no warnings about MonitorSample.

- [ ] **Step 4: Commit**

```bash
git add gui/Sources/NetdiagGUI/Models/MonitorSample.swift
git commit -m "feat: GUI decodes the monitor stream's changes array"
```

---

### Task 5: `EventStore` + coordinator wiring + first GUI test target

**Files:**
- Create: `gui/Sources/NetdiagGUI/Models/NetworkEvent.swift`
- Create: `gui/Sources/NetdiagGUI/Services/EventStore.swift`
- Modify: `gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift` (property block ~14-52; `handleSample` ~184-205; `handleAlertFired` ~73-75 hookup and its body)
- Modify: `gui/Package.swift`
- Create: `gui/Tests/NetdiagGUITests/NetworkEventTests.swift`

- [ ] **Step 1: Create the value type with pure, testable helpers**

`gui/Sources/NetdiagGUI/Models/NetworkEvent.swift`:

```swift
import Foundation

/// One thing that changed, as told by the CLI — a monitor `changes`
/// entry or a fired alert. The GUI stores and renders these; it never
/// authors the summary text.
struct NetworkEvent: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let date: Date
    /// Stream change kind ("vpn-disconnected", "rule-fired", …) or
    /// "alert" for alert-engine events. Drives icon/tint mapping only.
    let kind: String
    let summary: String
    let ruleID: String?

    init(id: UUID = UUID(), date: Date, kind: String,
         summary: String, ruleID: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.summary = summary
        self.ruleID = ruleID
    }
}

extension NetworkEvent {
    /// Newest-first, capped. Pure so the test target can hit it.
    static func trimmed(_ events: [NetworkEvent], cap: Int) -> [NetworkEvent] {
        Array(events.sorted { $0.date > $1.date }.prefix(cap))
    }

    /// Interval since the newest event, or nil when there is none.
    static func timeSinceLast(_ events: [NetworkEvent],
                              now: Date) -> TimeInterval? {
        guard let newest = events.map(\.date).max() else { return nil }
        return now.timeIntervalSince(newest)
    }

    static func within(_ events: [NetworkEvent], hours: Double,
                       now: Date) -> [NetworkEvent] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        return events.filter { $0.date >= cutoff }
    }
}
```

- [ ] **Step 2: Create the store**

`gui/Sources/NetdiagGUI/Services/EventStore.swift` (persistence pattern copied from `RulesCatalogStore.swift:126-157` — Application Support/<bundle id>, atomic write):

```swift
import Foundation
import OSLog

/// The dropdown's change timeline and the "nothing has changed in N"
/// headline both read from here. Events come from the monitor stream's
/// `changes` array and from fired alerts; the monitor itself writes
/// nothing to disk (its contract), so durable memory lives GUI-side.
@MainActor
@Observable
final class EventStore {
    static let cap = 500

    private(set) var events: [NetworkEvent] = []

    private let log = Logger(subsystem: "me.brianfreeman.netdiag",
                             category: "events")
    private let url: URL?

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Bundle.main.bundleIdentifier
                                    ?? "me.brianfreeman.netdiag",
                                    isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("events.json")
        } else {
            url = nil
        }
        load()
    }

    func record(kind: String, summary: String, ruleID: String? = nil,
                date: Date = .now) {
        guard !summary.isEmpty else { return }
        events = NetworkEvent.trimmed(
            events + [NetworkEvent(date: date, kind: kind,
                                   summary: summary, ruleID: ruleID)],
            cap: Self.cap)
        save()
    }

    func within(hours: Double, now: Date = .now) -> [NetworkEvent] {
        NetworkEvent.within(events, hours: hours, now: now)
    }

    var lastEventDate: Date? { events.first?.date }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([NetworkEvent].self,
                                                     from: data)
        else { return }
        events = NetworkEvent.trimmed(stored, cap: Self.cap)
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(events)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 3: Wire the coordinator**

In `NetdiagCoordinator.swift`, alongside `let progress = ScanProgress()` (~36):

```swift
    let events = EventStore()
```

In `handleSample(_:)` (~184-205), after `alerts.evaluate(sample:)`:

```swift
        for change in sample.changes {
            events.record(
                kind: change.kind,
                summary: change.summary,
                ruleID: change.field == "status.rules"
                    ? (change.to ?? change.from) : nil,
                date: sample.timestamp)
        }
```

In `handleAlertFired(_ def: AlertDefinition)` (hooked at ~73-75), append:

```swift
        events.record(kind: "alert", summary: def.title,
                      ruleID: def.rules.first)
```

- [ ] **Step 4: Add the test target**

`gui/Package.swift` — add to `targets:`:

```swift
        .testTarget(
            name: "NetdiagGUITests",
            dependencies: ["NetdiagGUI"],
            path: "Tests/NetdiagGUITests"
        )
```

`gui/Tests/NetdiagGUITests/NetworkEventTests.swift`:

```swift
import XCTest
@testable import NetdiagGUI

final class NetworkEventTests: XCTestCase {
    private func event(minutesAgo: Double, kind: String = "public-ip-changed",
                       now: Date) -> NetworkEvent {
        NetworkEvent(date: now.addingTimeInterval(-minutesAgo * 60),
                     kind: kind, summary: "s")
    }

    func testTrimKeepsNewestFirstAndCaps() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let events = (0..<10).map { event(minutesAgo: Double($0), now: now) }
        let trimmed = NetworkEvent.trimmed(events.shuffled(), cap: 3)
        XCTAssertEqual(trimmed.count, 3)
        XCTAssertEqual(trimmed.map(\.date),
                       events.prefix(3).map(\.date))
    }

    func testTimeSinceLastUsesNewestEvent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let events = [event(minutesAgo: 30, now: now),
                      event(minutesAgo: 5, now: now)]
        XCTAssertEqual(NetworkEvent.timeSinceLast(events, now: now), 300)
        XCTAssertNil(NetworkEvent.timeSinceLast([], now: now))
    }

    func testWithinFiltersByCutoff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let events = [event(minutesAgo: 30, now: now),
                      event(minutesAgo: 25 * 60, now: now)]
        XCTAssertEqual(NetworkEvent.within(events, hours: 24, now: now).count, 1)
    }
}
```

- [ ] **Step 5: Build and test**

Run: `cd gui && swift build && swift test`
Expected: build succeeds; 3 tests pass.
**Contingency:** if `swift test` fails to link against the executable target (duplicate `main`), move `NetworkEvent.swift`'s pure helpers into the test file's scope is NOT acceptable — instead split a tiny `.target(name: "NetdiagGUICore", path: "Sources/NetdiagGUICore")` holding only `NetworkEvent.swift`, make `NetdiagGUI` depend on it, and point the test target at it. Record which path was taken in the commit body.

- [ ] **Step 6: Commit**

```bash
git add gui/Sources/NetdiagGUI/Models/NetworkEvent.swift \
        gui/Sources/NetdiagGUI/Services/EventStore.swift \
        gui/Sources/NetdiagGUI/Services/NetdiagCoordinator.swift \
        gui/Package.swift gui/Tests/NetdiagGUITests/NetworkEventTests.swift
git commit -m "feat: GUI keeps a durable event log of CLI-reported changes

EventStore persists monitor changes and fired alerts to Application
Support (cap 500), giving the dropdown its timeline and its
time-since-last-change headline. First GUI test target covers the
pure prune/derive helpers."
```

---

### Task 6: Dropdown components

**Files:**
- Create: `gui/Sources/NetdiagGUI/Views/DropdownComponents.swift`

All components are dumb views over CLI-sourced values — no thresholds, no verdict strings. Icon/tint mapping keys off event `kind` (identity, not judgment).

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import AppKit

/// Building blocks for the dropdown's fixed sections. Dumb views over
/// CLI-sourced values: anything resembling a verdict arrived here as a
/// rule ID, a severity, or CLI prose.

// MARK: - Instrument grid cell

struct InstrumentCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let unit {
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Location cell (flag; hover reveals IP; click copies)

struct LocationCell: View {
    let countryISO: String?
    let publicIP: String?

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 2) {
            Text("Location")
                .font(.system(size: 9))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(Flag.emoji(forISOCode: countryISO) ?? "🌐")
                .font(.system(size: 15))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard let publicIP else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(publicIP, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        }
        .overlay(alignment: .top) {
            if hovering, let publicIP {
                Text(copied ? "Copied" : "\(publicIP) · click to copy")
                    .font(Theme.Font.compactMonospace)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                    .offset(y: -26)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .help(publicIP == nil ? "Location unknown" : "")
    }
}

// MARK: - Heartbeat strip

/// A thin live sparkline of fast-tier gateway RTT. Its job is to prove
/// monitoring is alive, not to be read precisely — Live has the real
/// charts.
struct HeartbeatStrip: View {
    let samples: [MonitorSample]
    var flatlined = false

    private var points: [Double] {
        samples.suffix(60).compactMap { $0.gateway.rttAvgMs }
    }

    var body: some View {
        Canvas { context, size in
            let values = flatlined ? [] : points
            guard values.count > 1 else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(.secondary.opacity(0.4)),
                               lineWidth: 1)
                return
            }
            let maxV = max(values.max() ?? 1, 1)
            let minV = values.min() ?? 0
            let span = max(maxV - minV, 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height - size.height *
                    CGFloat((v - minV) / span) * 0.8 - size.height * 0.1
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.green.opacity(0.7)),
                           lineWidth: 1)
        }
        .frame(height: 12)
        .background(.quaternary.opacity(Theme.cardOpacity),
                    in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Timeline band

struct TimelineBand: View {
    let events: [NetworkEvent]
    let hours: Double
    var now: Date = .now

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.green.opacity(0.15))
                    ForEach(events) { event in
                        let age = now.timeIntervalSince(event.date)
                        let x = geo.size.width *
                            CGFloat(1 - age / (hours * 3600))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(EventStyle.tint(for: event.kind))
                            .frame(width: 3)
                            .offset(x: max(0, min(x, geo.size.width - 3)))
                    }
                }
            }
            .frame(height: 20)
            HStack {
                Text("24 h ago")
                Spacer()
                Text("now")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Event row

struct EventRow: View {
    let event: NetworkEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: EventStyle.symbol(for: event.kind))
                .font(.system(size: 10))
                .foregroundStyle(EventStyle.tint(for: event.kind))
                .frame(width: 18, height: 18)
                .background(EventStyle.tint(for: event.kind).opacity(0.12),
                            in: Circle())
            Text(event.summary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(RelativeTime.string(from: event.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
        }
    }
}

// MARK: - Kind → presentation mapping (identity, not judgment)

enum EventStyle {
    static func symbol(for kind: String) -> String {
        switch kind {
        case "vpn-connected", "vpn-disconnected", "vpn-name-changed":
            return "lock.fill"
        case "public-ip-changed", "country-changed", "isp-changed":
            return "globe"
        case "wifi-network-changed", "wifi-roamed":
            return "wifi"
        case "interface-changed":
            return "cable.connector"
        case "rule-fired", "alert":
            return "exclamationmark.triangle.fill"
        case "rule-cleared":
            return "checkmark.circle.fill"
        default:
            return "circle.fill"
        }
    }

    static func tint(for kind: String) -> Color {
        switch kind {
        case "rule-fired", "alert": return .red
        case "rule-cleared": return .green
        case "vpn-disconnected": return .orange
        default: return .yellow
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd gui && swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/DropdownComponents.swift
git commit -m "feat: dropdown building blocks — instruments, heartbeat, timeline

Dumb views over CLI-sourced values; event icon/tint maps on the
stream's change kinds, never on measurements."
```

---

### Task 7: Rewrite `DropdownView`

**Files:**
- Rewrite: `gui/Sources/NetdiagGUI/Views/DropdownView.swift` (934 lines → ~420)

**Keep** (move unchanged into the new file): the `@Environment`/`@State` header (drop `copiedSummary`); computed vars `cleanNetworkName`, `publicIP`, `countryISO`, `routerInfo`, `vpnActive`, `vpnName`, `lastCheckLine`, `statusDetail`, `scanningRow`; `HighlightingButtonStyle`; the `.task` history hydration; `openActivity()`.

**Delete:** `heroSection`, `alertStrip`, `contextualRemedy`, `linkPathSection` + `pathNode`/`pathConnector` + all path color/label vars, `networkGlancePanel`, `quickActionBar`, `copyDiagnosticSummary()`, `wifiGlanceInfo` (and with it this file's `CoreWLAN` import — the Wi-Fi cell reads `MonitorSample.wifi.rssi`), `internetPing`, `speedString`, `hasSpeedMeasurement`.

- [ ] **Step 1: Replace `body` and add the stage machine**

New `body` and stage logic (verbatim; helpers in following steps):

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stageSection
                .padding(.horizontal, Theme.Spacing.md)

            instrumentSection
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)

            heartbeatSection
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)

            Divider().padding(.vertical, Theme.Spacing.xs)

            timelineSection
                .padding(.horizontal, Theme.Spacing.md)

            checkButton
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)

            Divider().padding(.vertical, Theme.Spacing.xs)

            controlsSection
        }
        .padding(.vertical, Theme.Spacing.sm)
        .task {
            if coordinator.history.document.runs.isEmpty {
                await coordinator.history.load()
            }
        }
    }

    // MARK: - Stage

    private enum Stage {
        case skewed(String)
        case testing
        case paused(String?)
        case alerted(AlertEngine.ActiveAlert)
        case healthy
    }

    private var stage: Stage {
        if let error = coordinator.monitor.lastError,
           !coordinator.monitor.isRunning {
            return .skewed(error)
        }
        if coordinator.isScanning { return .testing }
        if !appSettings.monitoringEnabled {
            return .paused(nil)
        }
        if coordinator.monitor.isPausedForAnyReason {
            return .paused(coordinator.monitor.pauseReason)
        }
        if let alert = coordinator.alerts.activeSorted.first {
            return .alerted(alert)
        }
        return .healthy
    }

    @ViewBuilder
    private var stageSection: some View {
        switch stage {
        case .healthy: healthyStage
        case .alerted(let alert): alertStage(alert)
        case .testing: testingStage
        case .paused(let reason): pausedStage(reason)
        case .skewed(let message): skewedStage(message)
        }
    }
```

- [ ] **Step 2: Implement the five stage views**

```swift
    private var healthyStage: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("All good — watching")
                    .font(.callout).fontWeight(.semibold)
            }
            Text(quietLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lastCheck = lastCheckLine {
                Text("Last check \(lastCheck.relative)\(lastCheck.badge.map { " · \($0)" } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    /// "Nothing has changed in 3 h 12 m · on HomeNet 5G" — the headline
    /// reassurance metric. Time comes from the event store, name from
    /// the CLI-derived network identity.
    private var quietLine: String {
        var parts: [String] = []
        if let since = NetworkEvent.timeSinceLast(coordinator.events.events,
                                                  now: .now) {
            let f = DateComponentsFormatter()
            f.allowedUnits = since >= 3600 ? [.hour, .minute] : [.minute]
            f.unitsStyle = .abbreviated
            if let s = f.string(from: since) {
                parts.append("Nothing has changed in \(s)")
            }
        } else {
            parts.append("Watching for changes")
        }
        if let name = cleanNetworkName { parts.append("on \(name)") }
        return parts.joined(separator: " · ")
    }

    private func alertStage(_ alert: AlertEngine.ActiveAlert) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(alert.title)
                    .font(.callout).fontWeight(.semibold)
                    .lineLimit(2)
            }
            // CLI prose verbatim — the interim body until a scan
            // enriches it, then diagnosis[].summary.
            Text(alert.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(RelativeTime.string(from: alert.raisedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("See full report") { openActivity() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var testingStage: some View {
        VStack(alignment: .leading, spacing: 4) {
            scanningRow
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func pausedStage(_ reason: String?) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Monitoring paused")
                    .font(.callout).fontWeight(.semibold)
            }
            if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if !appSettings.monitoringEnabled {
                Button("Resume monitoring") {
                    appSettings.monitoringEnabled = true
                    coordinator.setMonitoring(enabled: true)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    private func skewedStage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text("The netdiag command needs attention")
                    .font(.callout).fontWeight(.semibold)
            }
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { openWindow(id: WindowID.settings) }
                .controlSize(.small)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
```

(Adjust `WindowID.settings` / `coordinator.setMonitoring(enabled:)` to the exact names already used in the old `controlsSection` — both exist there today.)

- [ ] **Step 3: Implement instruments, heartbeat, timeline, CTA**

```swift
    // MARK: - Instruments (fixed; never move between states)

    private var instrumentSection: some View {
        VStack(spacing: Theme.Spacing.xs) {
            HStack(spacing: 0) {
                InstrumentCell(label: "Ping", value: pingValue.text,
                               tint: pingValue.tint)
                InstrumentCell(label: "Loss", value: lossValue.text,
                               tint: lossValue.tint)
                InstrumentCell(label: "Down", value: speedValues.down,
                               unit: "Mbps")
                InstrumentCell(label: "Up", value: speedValues.up,
                               unit: "Mbps")
            }
            Divider()
            HStack(spacing: 0) {
                InstrumentCell(label: "Router",
                               value: routerInfo?.ping ?? "—")
                InstrumentCell(label: "Wi-Fi", value: wifiValue)
                InstrumentCell(label: "VPN",
                               value: vpnActive ? (vpnName ?? "on") : "off",
                               tint: vpnActive ? .primary : .secondary)
                LocationCell(countryISO: countryISO, publicIP: publicIP)
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .cardStyle()
    }

    /// Cell tint keys off the CLI's fired rules, never off the number:
    /// the rule IDs are the verdict, the map below is only "which cell
    /// does this rule talk about".
    private static let latencyRules: Set<String> = ["G2", "G3"]
    private static let lossRules: Set<String> = ["G1", "P1", "P2", "L1", "L2"]

    private var firedRules: Set<String> {
        Set(coordinator.monitor.latest?.status.rules ?? [])
    }

    private var pingValue: (text: String, tint: Color) {
        guard let rtt = coordinator.monitor.latest?.gateway.rttAvgMs else {
            return ("—", .primary)
        }
        let bad = !firedRules.isDisjoint(with: Self.latencyRules)
        return ("\(Int(rtt.rounded())) ms", bad ? .red : .primary)
    }

    private var lossValue: (text: String, tint: Color) {
        guard let loss = coordinator.monitor.latest?.gateway.lossPct else {
            return ("—", .primary)
        }
        let bad = !firedRules.isDisjoint(with: Self.lossRules)
        return (String(format: "%.1f%%", loss), bad ? .red : .green)
    }

    private var wifiValue: String {
        guard coordinator.monitor.latest?.link.isWiFi == true else {
            return "wired"
        }
        guard let rssi = coordinator.monitor.latest?.wifi?.rssi else {
            return "—"
        }
        return "\(rssi) dBm"
    }

    private var speedValues: (down: String, up: String, age: String?) {
        if let speed = coordinator.latestSpeedTest {
            let age = coordinator.latestSpeedTestAt
                .map { RelativeTime.string(from: $0) }
            return (speed.downMbps.map { String(Int($0.rounded())) } ?? "—",
                    speed.upMbps.map { String(Int($0.rounded())) } ?? "—",
                    age)
        }
        if let stored = coordinator.history.latestSpeedTest(
            for: coordinator.monitor.latest?.network.id) {
            return (String(Int(stored.down.rounded())),
                    stored.up.map { String(Int($0.rounded())) } ?? "—",
                    RelativeTime.string(from: stored.date))
        }
        return ("—", "—", nil)
    }

    // MARK: - Heartbeat

    private var heartbeatSection: some View {
        VStack(spacing: 2) {
            HeartbeatStrip(samples: coordinator.monitor.recent,
                           flatlined: !coordinator.monitor.isRunning
                                      || coordinator.monitor.isPaused)
            HStack {
                Text(coordinator.monitor.isRunning && !coordinator.monitor.isPaused
                     ? "monitoring · live" : "monitoring off")
                Spacer()
                if let age = speedValues.age {
                    Text("speeds from test \(age)")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("LAST 24 HOURS")
                .font(.system(size: 9))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            TimelineBand(events: coordinator.events.within(hours: 24),
                         hours: 24)
            let recent = Array(coordinator.events.within(hours: 24).prefix(3))
            if recent.isEmpty {
                Text("No changes in the last 24 hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            } else {
                ForEach(recent) { EventRow(event: $0) }
            }
            Button("Open full history") { openActivity() }
                .buttonStyle(.link)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - The one CTA

    private var checkButton: some View {
        Button {
            coordinator.runScan(depth: .full, reason: "you asked")
        } label: {
            HStack {
                Image(systemName: "stethoscope")
                Text("Check My Connection")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(coordinator.isScanning)
    }
```

- [ ] **Step 4: Trim `controlsSection` to the footer**

Reduce the kept `controlsSection` to: Settings button, Quit button, version footer, and the update-available row (keep the existing `coordinator.updateChecker` code as is). Remove the Live-Latency and Pause-monitoring rows (pause now lives in Settings; the stage communicates paused state). Keep `dropdownButton(_:icon:action:)` and `HighlightingButtonStyle` for these rows.

- [ ] **Step 5: Build and run**

Run: `cd gui && swift build && make run`
Expected: builds; the dropdown opens showing stage + instruments + heartbeat + timeline. Verify by hand: (1) hovering the flag reveals the IP, clicking copies it; (2) "Run Speed Test" no longer exists as a peer CTA; (3) toggling monitoring off in Settings switches the stage to paused while instruments keep their last values.

- [ ] **Step 6: Run the GUI tests + full CLI suite**

Run: `cd gui && swift test && cd .. && bats tests/`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add gui/Sources/NetdiagGUI/Views/DropdownView.swift
git commit -m "feat: dropdown rebuilt — adaptive stage over fixed instruments

One swappable stage (healthy/alert/testing/paused/skew) above a 4x2
instrument grid, live heartbeat strip, and 24-hour change timeline.
Location is flag-only with hover-to-reveal IP. Link path bar, glance
panel, and quick-action grid retired; one CTA remains."
```

---

### Task 8: Changelog + final verification

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the changelog entry**

Under a new `## Unreleased` heading (or the project's current pattern — match the file):

```markdown
### Added
- `--monitor` schema 2: samples carry a `changes` array describing
  field-level differences from the previous sample (public IP, country,
  ISP, VPN, Wi-Fi network/roam, interface, rule transitions), phrased
  by the CLI. Absent when nothing changed; gate on `--capabilities`
  `schemas.monitor >= 2`.

### Changed
- Menu-bar dropdown rebuilt: an adaptive stage (healthy / alert /
  testing / paused / version-skew) over a fixed instrument grid, a
  live heartbeat strip, and a 24-hour change timeline. Public IP is
  flag-only with hover-to-reveal. The app now keeps a persistent
  event log of CLI-reported changes.
```

- [ ] **Step 2: Full verification pass**

```bash
shellcheck bin/netdiag install.sh lib/*.sh
bats tests/
cd gui && swift build && swift test && cd ..
bin/netdiag --capabilities | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['schemas']['monitor']==2; print('ok')"
```
Expected: all clean; `ok`.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for monitor schema 2 and the dropdown rebuild"
```

---

## Self-review checklist (run before handoff)

- Spec coverage: stage states ✓ (Task 7 step 2 — five cases), instruments ✓ (Task 7 step 3), heartbeat ✓, timeline + events ✓ (Tasks 5–7), CLI `changes` ✓ (Tasks 1–3), schema gating ✓ (Task 3; the GUI-side degrade is implicit — an old CLI emits no `changes`, so the timeline is simply tickless), privacy flag/hover ✓ (Task 6), edge cases: cold launch uses existing hydration ✓, no-speed shows `—` ✓, unknown flag shows 🌐 ✓, malformed lines already skipped ✓.
- Out of scope honored: no Activity/dashboard redesign, no eye-mask toggle, no `--watch` changes.
- Thresholds: zero new numeric comparisons in `lib/monitor.sh`/`lib/diagnosis.sh`; `helpers/monitor_sample.py` uses only equality.
