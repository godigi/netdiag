#!/usr/bin/env python3
"""Print one version's section of CHANGELOG.md, for release notes.

Exists because this repo's release notes drifted badly: eleven tags were
pushed and only two of them ever became a GitHub Release, so the repo
page advertised v0.2.1 as "Latest" for three months while v0.9.1 was the
shipping version. The CHANGELOG was accurate the whole time — nothing
read it. This helper is the thing that reads it, so
.github/workflows/release.yml can turn a tag push into a Release whose
notes are the same prose a reader of the file would get, rather than a
hand-copied summary that can disagree with it.

Parsing is deliberately literal: sections are delimited by `## [VERSION]`
at column 0, exactly as Keep a Changelog specifies and exactly as
CHANGELOG.md is already written. Anything looser (a regex over the whole
file, a fuzzy version match) would silently return the wrong section when
the format shifts, which is the failure this is meant to prevent — so a
version whose heading is absent is an error, not an empty string.

Also used by tests/test_changelog.bats as the structural guard on the
file itself: every released version has a section, the [Unreleased]
heading appears exactly once, and versions run in descending order.

Usage:
    changelog_section.py --version 0.9.1 [--file CHANGELOG.md]
    changelog_section.py --list [--file CHANGELOG.md]
"""

import argparse
import re
import sys

# `## [0.9.1] - 2026-08-15` or `## [Unreleased]`. The date is optional
# because [Unreleased] carries none; the brackets are not, because they
# are what distinguishes a version heading from an ordinary `## ` heading
# inside a section's prose.
HEADING = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\S+))?\s*$")

# Link-reference definitions at the foot of the file (`[0.9.1]: https://…`),
# and the comment that introduces them. Both belong to the document rather
# than to the last version's section, so the oldest release's notes stop
# here instead of ending with a maintenance note about tags. Matching at
# column 0 only: list items in a section body are indented, so a `<!--`
# inside a real entry is untouched.
FOOTER = re.compile(r"^(?:\[[^\]]+\]:\s+\S+|<!--)")


def parse(path):
    """Return [(version, date, [body lines]), ...] in file order."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    sections = []
    current = None
    for line in lines:
        match = HEADING.match(line)
        if match:
            current = (match.group(1), match.group(2), [])
            sections.append(current)
            continue
        if current is None:
            continue  # preamble above the first heading
        if FOOTER.match(line):
            current = None  # footer block: the sections are over
            continue
        current[2].append(line)
    return sections


def body(section):
    """The section's prose, stripped of leading and trailing blank lines."""
    lines = section[2]
    start, end = 0, len(lines)
    while start < end and not lines[start].strip():
        start += 1
    while end > start and not lines[end - 1].strip():
        end -= 1
    return "\n".join(lines[start:end])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--file", default="CHANGELOG.md")
    ap.add_argument("--version", help="version to print, with or without a leading v")
    ap.add_argument("--list", action="store_true", help="list every version heading")
    args = ap.parse_args()

    try:
        sections = parse(args.file)
    except OSError as exc:
        print(f"changelog_section: cannot read {args.file}: {exc}", file=sys.stderr)
        return 2

    if args.list:
        for version, date, _ in sections:
            print(version if date is None else f"{version}\t{date}")
        return 0

    if not args.version:
        print("changelog_section: --version or --list is required", file=sys.stderr)
        return 2

    wanted = args.version.lstrip("vV")
    for section in sections:
        if section[0] == wanted:
            text = body(section)
            if not text:
                print(
                    f"changelog_section: [{wanted}] has a heading but no notes",
                    file=sys.stderr,
                )
                return 1
            print(text)
            return 0

    have = ", ".join(s[0] for s in sections) or "(none)"
    print(
        f"changelog_section: no '## [{wanted}]' heading in {args.file}\n"
        f"  headings found: {have}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
