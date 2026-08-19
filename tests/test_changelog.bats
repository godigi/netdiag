#!/usr/bin/env bats
#
# CHANGELOG.md is the source of every GitHub Release's notes, so a defect
# in the file becomes a defect on the repo's front page. Two have already
# happened and both were invisible until someone went looking:
#
#   - a second `## [Unreleased]` heading sat mid-file between 0.5.2 and
#     0.5.1 for months, holding notes that had actually shipped in 0.6.0;
#   - 0.1.0, 0.4.1, 0.5.0 and 0.9.1 were documented here with no tag
#     anywhere, so their entries described a version no one could check out.
#
# Neither broke a build, which is exactly why they lasted. These tests
# make both loud, and cover helpers/changelog_section.py — the parser
# .github/workflows/release.yml depends on to generate notes.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  CHANGELOG="$REPO/CHANGELOG.md"
  SECTION="$REPO/helpers/changelog_section.py"
}

# Version headings, in file order, excluding [Unreleased].
released_versions() {
  python3 "$SECTION" --file "$CHANGELOG" --list | cut -f1 | grep -v '^Unreleased$'
}

# The two guards below compare the docs against the tag list, so they are
# meaningless in a checkout that has no tags — and worse than meaningless:
# every version reads as untagged and the build goes red on a repo that is
# entirely correct, which is exactly what `actions/checkout` (which fetches
# no tags by default) produced the first time these ran. CI now sets
# `fetch-tags: true`; this skip keeps a shallow or tagless clone honest
# rather than failing it for a defect it cannot see.
require_tags() {
  [ -n "$(git -C "$REPO" tag -l 2>/dev/null)" ] \
    || skip "checkout has no tags; nothing to check the docs against"
}

# ── The parser ───────────────────────────────────────────────────────────

@test "changelog_section extracts a known section's prose" {
  run python3 "$SECTION" --file "$CHANGELOG" --version 0.6.1
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "changelog_section accepts a version with or without a leading v" {
  run python3 "$SECTION" --file "$CHANGELOG" --version v0.6.1
  [ "$status" -eq 0 ]
  local with_v="$output"
  run python3 "$SECTION" --file "$CHANGELOG" --version 0.6.1
  [ "$output" = "$with_v" ]
}

@test "changelog_section fails loudly on a version that isn't there" {
  # The release workflow relies on this being an error rather than an
  # empty string: empty notes would publish a blank Release and look fine.
  run python3 "$SECTION" --file "$CHANGELOG" --version 9.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"no '## [9.9.9]'"* ]]
}

@test "changelog_section keeps the link-ref footer out of the oldest section" {
  # The footer sits directly under the last version's prose, so an
  # off-by-one in the parser publishes a maintenance note as 0.1.0's
  # release notes.
  run python3 "$SECTION" --file "$CHANGELOG" --version 0.1.0
  [ "$status" -eq 0 ]
  [[ "$output" != *"https://github.com"* ]]
  [[ "$output" != *"<!--"* ]]
}

# ── The file's structure ─────────────────────────────────────────────────

@test "there is exactly one [Unreleased] heading" {
  run grep -c '^## \[Unreleased\]' "$CHANGELOG"
  [ "$output" -eq 1 ]
}

@test "versions run in descending order" {
  local versions sorted
  versions="$(released_versions)"
  sorted="$(printf '%s\n' "$versions" | sort -rV)"
  [ "$versions" = "$sorted" ] || {
    echo "file order:   $(printf '%s ' $versions)"
    echo "sorted order: $(printf '%s ' $sorted)"
    return 1
  }
}

@test "every released version has a git tag" {
  # The gap this closes: a CHANGELOG entry for a version that was never
  # tagged describes something a reader cannot obtain.
  require_tags
  local missing=""
  while read -r v; do
    [ -n "$v" ] || continue
    git -C "$REPO" rev-parse -q --verify "refs/tags/v$v" >/dev/null || missing="$missing v$v"
  done <<< "$(released_versions)"
  [ -z "$missing" ] || { echo "documented but untagged:$missing"; return 1; }
}

@test "every version heading is preceded by a blank line" {
  # Not cosmetic. Releasing v0.9.1 inserted its heading directly on top of
  # the last line of the entry above it, deleting "asserted to exit
  # anything but 3 and to parse with python3." — the previous release's
  # notes ended mid-sentence, and nothing complained. A heading flush
  # against prose is the visible signature of that clobber.
  local bad
  bad="$(awk '
    /^## \[/ && NR > 1 && prev != "" { print NR ": " $0 }
    { prev = $0 }
  ' "$CHANGELOG")"
  [ -z "$bad" ] || { echo "heading with no blank line above it:"; echo "$bad"; return 1; }
}

@test "every heading has a link-reference definition" {
  local missing=""
  while read -r v; do
    [ -n "$v" ] || continue
    grep -qF "[$v]: http" "$CHANGELOG" || missing="$missing $v"
  done <<< "$(python3 "$SECTION" --file "$CHANGELOG" --list | cut -f1)"
  [ -z "$missing" ] || { echo "headings with no link ref:$missing"; return 1; }
}

@test "every released version's section actually has notes" {
  while read -r v; do
    [ -n "$v" ] || continue
    run python3 "$SECTION" --file "$CHANGELOG" --version "$v"
    [ "$status" -eq 0 ] || { echo "empty or missing notes for $v"; return 1; }
  done <<< "$(released_versions)"
}

@test "every version the README credits a feature to actually exists" {
  # The README's Roadmap said the one-line installer shipped in v0.5.3.
  # There has never been a v0.5.3 — no tag, no CHANGELOG section — and the
  # installer actually landed in 0.6.0. A reader chasing that version finds
  # nothing, which is worse than an undated claim.
  require_tags
  local missing=""
  local v
  for v in $(grep -oE '\(v[0-9]+\.[0-9]+\.[0-9]+\)' "$REPO/README.md" \
             | tr -d '()' | sort -u); do
    git -C "$REPO" rev-parse -q --verify "refs/tags/$v" >/dev/null || missing="$missing $v"
  done
  [ -z "$missing" ] || { echo "README credits versions that do not exist:$missing"; return 1; }
}

# ── The file and the CLI agree ───────────────────────────────────────────

@test "NETDIAG_VERSION is documented in the CHANGELOG" {
  # The release workflow enforces this against the tag; here it is
  # enforced on every push, so a version bump without a CHANGELOG entry
  # fails at the point it is made rather than at release time.
  local cli
  cli="$(sed -n 's/^NETDIAG_VERSION="\(.*\)"$/\1/p' "$REPO/bin/netdiag" | head -1)"
  [ -n "$cli" ] || { echo "could not read NETDIAG_VERSION from bin/netdiag"; return 1; }
  run python3 "$SECTION" --file "$CHANGELOG" --version "$cli"
  [ "$status" -eq 0 ] || {
    echo "bin/netdiag reports $cli, which has no '## [$cli]' section"
    return 1
  }
}
