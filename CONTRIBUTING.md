# Contributing to netdiag

Thanks for looking. netdiag is a bash 5 CLI for macOS; there's no build
step, so getting set up is a clone and two Homebrew packages.

```sh
git clone https://github.com/godigi/netdiag.git
cd netdiag
brew install shellcheck bats-core jq bash
./install.sh          # symlinks this clone onto your PATH
```

## Before opening a PR

Both of these run in CI, so it's cheaper to run them locally first:

```sh
shellcheck bin/netdiag install.sh lib/*.sh   # must be clean at default severity
bats tests/                                  # must be green
```

`# shellcheck disable=...` is allowed only with a comment saying why the
warning is a false positive.

## What a good change looks like

- **One logical change per PR.** Conventional-commit prefixes
  (`fix:`, `feat:`, `docs:`, `test:`, `refactor:`) in the subject.
- **A test for anything that could regress.** `tests/` is bats-core.
  Parser-level logic goes in `test_parse.bats` with a fixture under
  `tests/fixtures/`; anything that must never come back goes in
  `test_regressions.bats`. Tests must not need a working network —
  use fixtures, or probe loopback.
- **A CHANGELOG entry** under `## [Unreleased]`.
- **Samples come from real runs.** If you change output,
  regenerate `examples/sample-output.{txt,json}` with
  `./bin/netdiag --redact` and `./bin/netdiag --redact --json`. Don't
  hand-edit them: a sample that doesn't match reality is worse than none,
  and the README has been wrong that way before.

## The rule that matters most

**Never report a failed measurement as a finding about the user's
network.** Most bugs in this project have been that mistake: a probe
silently fails, its empty output is defaulted to a pessimistic number,
and the user is told their network is broken. If a check can't run,
record it as unknown and let the other evidence speak. `null` in JSON
means "did not run"; `[]` means "ran, found nothing". They are not
interchangeable.

Related: diagnoses are read by people who are already frustrated. Write
them in plain English, say what the user will actually experience, and
end with something they can do. See `docs/DIAGNOSIS-RULES.md` for the
format and the existing rules.

## Adding a diagnosis rule

1. Give it an ID (`XX-1`) and document it in `docs/DIAGNOSIS-RULES.md`
   with trigger, severity, evidence, recommendation, and rationale.
2. Emit it with `add_diag <severity> <ID> "<plain-English text>"`.
3. Add it to the README's rule list.
4. Test that it fires when it should **and stays quiet when it
   shouldn't** — the second half is where the false positives live.

Severity drives the exit code (`info` → 0, `warn` → 1, `critical` → 2),
so `critical` means "a wrapper should page someone".

## Releasing

Releases are cut from a tag; `.github/workflows/release.yml` publishes the
GitHub Release and takes its notes from `CHANGELOG.md`, so the notes and
the file cannot disagree. Never write release notes by hand in the GitHub
UI — the workflow overwrites them from the CHANGELOG on the next run.

This process is written down because the informal version failed silently
for three months: eleven tags were pushed and only two ever became a
Release, so the front page advertised v0.2.1 as "Latest" while v0.9.1 was
what `install.sh` actually installed. Four versions (0.1.0, 0.4.1, 0.5.0,
0.9.1) were documented in the CHANGELOG with no tag at all.

1. **Pick the version.** SemVer: a new rule, flag, or JSON key is a minor
   bump; a fix that changes no surface is a patch. Pre-1.0, a breaking
   change to the CLI surface or JSON schema is still a minor bump — say so
   loudly in the notes.
2. **Roll `## [Unreleased]` over** to `## [X.Y.Z] - YYYY-MM-DD` and start
   a fresh empty `## [Unreleased]` above it.
3. **Add the link reference** at the foot of the CHANGELOG, and repoint
   `[Unreleased]` at the new tag:

   ```
   [Unreleased]: https://github.com/godigi/netdiag/compare/vX.Y.Z...HEAD
   [X.Y.Z]: https://github.com/godigi/netdiag/compare/vPREV...vX.Y.Z
   ```
4. **Bump `NETDIAG_VERSION`** in `bin/netdiag`. It is what `--version` and
   the GUI's capabilities handshake report; the release workflow refuses a
   tag that disagrees with it.
5. **Run the suite.** `bats tests/` — `tests/test_changelog.bats` checks
   steps 2–4 for you, so a mistake there fails locally rather than at
   release time.
6. **Commit** as `chore: vX.Y.Z` — the version bump and the CHANGELOG
   rollover together, nothing else.
7. **Tag annotated and push both:**

   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z — one line on what changed"
   git push origin main --follow-tags
   ```
8. **Check the release workflow went green.** It verifies the tag, the
   CLI version and the CHANGELOG agree, then creates the Release. If it
   fails, fix forward and re-run it from the Actions tab with
   `workflow_dispatch` — that also repairs the notes on a Release that
   already exists.

Tags are annotated (`-a`), never lightweight: the tag message is the
one-line summary, and `git describe` depends on it.

## Layout

| Path | What's in it |
|------|--------------|
| `bin/netdiag` | argument parsing and the run orchestrator |
| `lib/*.sh` | one module per check; `common.sh` has shared helpers |
| `helpers/*.py` | JSON emission, baseline math, summaries (stock `python3`) |
| `tests/` | bats-core suites and fixtures |
| `docs/` | architecture, diagnosis rules, JSON schema |

`docs/ARCHITECTURE.md` explains the bash-vs-Python split and when a check
belongs in the parallel batch.

## Scope

macOS 14+ only for now. Checks should prefer macOS built-ins; Homebrew
tools (`mtr`, `gping`, `speedtest`, `jq`) may be used but must degrade to
a skip with a hint when missing, never a hard failure. netdiag is
read-only: it must never change routing, DNS, WiFi, or ARP state.

By contributing you agree your work is licensed under the [MIT
License](./LICENSE).
