#!/usr/bin/env bash
# install.sh — symlink netdiag into a directory on $PATH.
#
# Usage: ./install.sh [--prefix DIR]
#
# Defaults to /usr/local/bin when writable, otherwise ~/bin (created if
# missing). Pass --prefix to override.

set -euo pipefail

PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

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
  *) printf 'note: %s is not on $PATH — add it to your shell rc\n' "$PREFIX" ;;
esac
