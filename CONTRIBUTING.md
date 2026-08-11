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
