#!/usr/bin/env bats
#
# Retention, archiving, and the redaction boundary — the three things that
# decide whether ~/net-diag/baseline.jsonl is still worth reading in six
# months. All network-free: prune_history and build_json_private are pure
# given their inputs.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  TMP="$BATS_TEST_TMPDIR"
  JSON_MODE=0 QUIET=0 QUICK=0 EXPERT=0 REDACT=0 LOG=/dev/null
  # shellcheck source=../lib/thresholds.sh
  . "$REPO/lib/thresholds.sh"
  # shellcheck source=../lib/common.sh
  . "$REPO/lib/common.sh"
  # shellcheck source=../lib/globals.sh
  . "$REPO/lib/globals.sh"
  # shellcheck source=../lib/output.sh
  . "$REPO/lib/output.sh"
}

# Write N JSONL records whose timestamps count up, so a test can tell which
# end of the file survived a prune.
seed_history() {
  local file="$1" n="$2" i
  : > "$file"
  for ((i = 1; i <= n; i++)); do
    printf '{"timestamp":"2026-01-%02dT00:00:00Z","n":%d}\n' "$((i % 28 + 1))" "$i" >> "$file"
  done
}

# ── Retention rolls over instead of deleting ─────────────────────────────
# Before this, prune_history ran `tail -n keep` over the file and threw the
# head away. At the launchd watcher's 96 runs/day the 2000-line cap is
# about three weeks, and the lines it dropped were always the oldest — the
# only ones a multi-month history chart is made of.

@test "prune_history moves the truncated head to the archive, not to /dev/null" {
  local live="$TMP/baseline.jsonl"
  seed_history "$live" 100
  prune_history "$live" 50
  [ "$(wc -l < "$live")" -eq 50 ]
  [ "$(wc -l < "$TMP/baseline-archive.jsonl")" -eq 50 ]
}

@test "no record is lost across a prune: archive + live == the original" {
  local live="$TMP/baseline.jsonl"
  seed_history "$live" 100
  cp "$live" "$TMP/original.jsonl"
  prune_history "$live" 50
  cat "$TMP/baseline-archive.jsonl" "$live" > "$TMP/rejoined.jsonl"
  run diff "$TMP/original.jsonl" "$TMP/rejoined.jsonl"
  [ "$status" -eq 0 ]
}

@test "the archive keeps the OLDEST runs and the live file the newest" {
  local live="$TMP/baseline.jsonl"
  seed_history "$live" 100
  prune_history "$live" 50
  # Records are numbered in write order, so record 1 is the oldest.
  [ "$(head -1 "$TMP/baseline-archive.jsonl" | grep -o '"n":[0-9]*')" = '"n":1' ]
  [ "$(tail -1 "$live" | grep -o '"n":[0-9]*')" = '"n":100' ]
}

@test "prune_history appends across successive rollovers rather than overwriting" {
  local live="$TMP/baseline.jsonl"
  seed_history "$live" 100
  prune_history "$live" 50
  seed_history "$live" 100
  prune_history "$live" 50
  [ "$(wc -l < "$TMP/baseline-archive.jsonl")" -eq 100 ]
}

@test "prune_history is a no-op until the file is meaningfully over the cap" {
  local live="$TMP/baseline.jsonl"
  # 52 lines against a cap of 50 is inside the 10% hysteresis: rewriting
  # the file on every run past the cap would be pure churn.
  seed_history "$live" 52
  prune_history "$live" 50
  [ "$(wc -l < "$live")" -eq 52 ]
  [ ! -e "$TMP/baseline-archive.jsonl" ]
}

@test "NETDIAG_KEEP_HISTORY=0 disables pruning entirely" {
  local live="$TMP/baseline.jsonl"
  seed_history "$live" 100
  prune_history "$live" 0
  [ "$(wc -l < "$live")" -eq 100 ]
  [ ! -e "$TMP/baseline-archive.jsonl" ]
}

@test "an unwritable archive leaves the live history intact rather than truncating it" {
  # The failure this guards: losing the head to a truncate whose archive
  # append had already failed. Over-cap costs parse time; deleted history
  # costs the history.
  local live="$TMP/baseline.jsonl"
  seed_history "$live" 100
  mkdir -p "$TMP/baseline-archive.jsonl"   # a directory: append cannot succeed
  prune_history "$live" 50
  [ "$(wc -l < "$live")" -eq 100 ]
}

@test "history_archive_path derives the archive from the live file" {
  [ "$(history_archive_path /x/baseline.jsonl)" = "/x/baseline-archive.jsonl" ]
}

# ── The redaction boundary ───────────────────────────────────────────────
# output_run appended the emitted JSON to baseline.jsonl *after* redaction,
# so every --redact run wrote a record whose network.id was the literal
# string "wifi:mac=[redacted]". That id is the join key helpers/baseline.py
# scopes history by, so such a record can never match a real one: it is
# dead weight that also consumes a slot under the retention cap. The GUI's
# "Copy shareable report" runs --redact, so this fired on every use.

@test "build_json_private builds with redaction off even when --redact is set" {
  REDACT=1
  build_json() { printf 'redact=%s\n' "$REDACT"; }
  run build_json_private
  [ "$output" = "redact=0" ]
}

@test "build_json_private restores --redact for the copy that leaves the machine" {
  REDACT=1
  build_json() { :; }
  build_json_private
  [ "$REDACT" -eq 1 ]
}

@test "build_json_private is a plain passthrough when --redact was not passed" {
  REDACT=0
  build_json() { printf 'redact=%s\n' "$REDACT"; }
  run build_json_private
  [ "$output" = "redact=0" ]
}

@test "output_run feeds the history the private build, never the redacted one" {
  # Structural guard: the three call sites that touch baseline.jsonl (the
  # initial build, the post-regression rebuild, and the append) must all go
  # through build_json_private. A future edit that reaches for build_json
  # there reintroduces the leak silently.
  run grep -c 'build_json_private > "$json_tmp"' "$REPO/lib/output.sh"
  [ "$output" -eq 2 ]
  run grep -n 'baseline.jsonl' "$REPO/lib/output.sh"
  [[ "$output" == *'$json_tmp'* ]] || [[ "$output" == *'json_tmp'* ]] || return 1
}
