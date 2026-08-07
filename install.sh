#!/usr/bin/env bash
# install.sh — install netdiag and its bash 5 runtime dependency.
#
# Usage: ./install.sh [--prefix DIR] [--no-brew]
#
# Defaults to /usr/local/bin when writable, otherwise ~/bin (created if
# missing). Pass --prefix to override the install location, --no-brew to
# skip the Homebrew bash 5 bootstrap.

set -euo pipefail

PREFIX=""
NO_BREW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      # Guard before indexing $2 — under `set -u` a bare --prefix aborts
      # with "unbound variable" instead of a usable message.
      if [ $# -lt 2 ]; then
        printf 'install.sh: --prefix expects a directory\n' >&2; exit 2
      fi
      PREFIX="$2"; shift 2 ;;
    --no-brew) NO_BREW=1; shift ;;
    -h|--help)
      cat <<'HELP'
install.sh — install netdiag and its bash 5 runtime dependency.

Usage: ./install.sh [--prefix DIR] [--no-brew]

Defaults to /usr/local/bin when writable, otherwise ~/bin (created if
missing). Pass --prefix to override the install location, --no-brew to
skip the Homebrew bash 5 bootstrap.
HELP
      exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# bash 5 is the runtime requirement (see bin/netdiag startup check). Try to
# satisfy it via Homebrew if it isn't already present.
have_bash5() {
  [ -x /opt/homebrew/bin/bash ] || [ -x /usr/local/bin/bash ]
}

if [ "$NO_BREW" -eq 0 ] && ! have_bash5; then
  if command -v brew >/dev/null 2>&1; then
    printf 'installing Homebrew bash 5 (netdiag runtime dependency)...\n'
    brew install bash
  else
    printf 'warning: bash 5+ not found and Homebrew not installed.\n' >&2
    printf '         netdiag requires bash 5+. Install Homebrew, then:\n' >&2
    printf '         brew install bash\n' >&2
  fi
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO_ROOT/bin/netdiag"

if [ ! -x "$SRC" ]; then
  printf 'error: %s is not executable\n' "$SRC" >&2
  exit 1
fi

if [ -z "$PREFIX" ]; then
  if [ -w /usr/local/bin ]; then
    PREFIX=/usr/local/bin
  else
    PREFIX="$HOME/bin"
    mkdir -p "$PREFIX"
  fi
fi

DEST="$PREFIX/netdiag"
ln -sfn "$SRC" "$DEST"
printf 'installed: %s -> %s\n' "$DEST" "$SRC"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) printf 'note: %s is not in your PATH — add it to your shell rc\n' "$PREFIX" ;;
esac
