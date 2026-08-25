#!/usr/bin/env python3
"""Render one stored netdiag run as pasteable, redacted plain text.

Why this exists instead of a flag on --redact
──────────────────────────────────────────────
The app's only copy affordance (gui/.../Views/ExpertPanel.swift:246) copies
a run's raw JSON, unredacted: the machine's public IPv4 and IPv6
addresses, SSID, BSSID, gateway MAC and city all ride along in it. The
obvious fix — reuse --redact against a stored run — does not work, because
of two deliberate design decisions elsewhere in this codebase:

  1. lib/output.sh:160-163 saves REDACT, forces it to 0 to build the
     record appended to history, then restores it. The log and the
     history store always hold full detail; only stdout and --json are
     ever masked, and only for the run currently in progress.
  2. helpers/history.py:355 (is_redacted, :281) drops any record that
     *was* written under --redact from the store entirely, because a
     masked record's network.id is the literal string
     "wifi:mac=[redacted]" — shared with every other redacted run on
     every other network — and grouping on it would invent a network
     that never existed.

So there is no redacted stored copy to read, and there never will be:
redaction of a stored run has to happen at read time, against whatever
JSON `netdiag --show` hands back. That is what this file does.

The redactor below mirrors emit_json.py's _REDACT_ENV / _scrub / redact
(see helpers/emit_json.py:258-305) field for field, but pulls its secrets
out of the record itself rather than out of the process environment —
there is no live run here to source NETDIAG_* vars from, only a JSON
object read from stdin or a file.
"""

from __future__ import annotations

import argparse
import json
import sys

REDACTED = "[redacted]"

# Mirrors emit_json.py's _REDACT_ENV exactly, one record path per name.
# ASN/ISP and country/country_iso are deliberately absent: ISP and ASN
# name a provider, which is what a reader needs to act on the report, and
# a 2-letter country code is too short to substring-replace safely (see
# the minimum-length guard in secrets_in below). RFC1918 addresses are
# also deliberately absent: a 192.168.x.y identifies nobody, and blanking
# it would gut the router/NAT rows. network.id and network.label are
# deliberately absent too — they are composites of values already listed
# here ("wifi:ssid=Home,mac=aa:bb:…"), so the parts that identify anything
# are masked anyway when the substring scrub runs, leaving the readable
# structure ("wifi:ssid=[redacted],mac=[redacted]") intact.
_REDACT_PATHS = (
    "public.ip",
    "interface.ip",
    "wifi.ssid",
    "wifi.bssid",
    "ipv6.global_addr",
    # A fe80:: address is EUI-64-derived from the router's MAC, so leaving
    # it in would republish interface.gateway_mac sitting next to it.
    "ipv6.gateway",
    "interface.gateway_mac",
    "public.city",
)


def get_nested(d, path: str):
    """Walk a dotted path through nested dicts; None on any missing hop."""
    cur = d
    for k in path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def secrets_in(record: dict) -> list[str]:
    """The identifying substrings to scrub out of `record`, longest first.

    Longest-first matters the same way it does in emit_json.py: an SSID
    has to be masked before a shorter value that happens to sit inside it
    (e.g. an SSID that contains a street number that also appears alone
    elsewhere), or the shorter replacement would run first and leave a
    fragment of the longer secret exposed.

    Values shorter than 3 characters are dropped rather than scrubbed —
    replacing a 1- or 2-character string would corrupt unrelated text
    (English prose is full of 2-letter words) rather than protect anything.
    """
    found: set[str] = set()
    for path in _REDACT_PATHS:
        v = get_nested(record, path)
        if isinstance(v, str) and len(v) >= 3:
            found.add(v)
    return sorted(found, key=len, reverse=True)


def scrub(node, secrets: list[str]):
    """Replace every secret substring anywhere in `node`, recursively.

    Field-by-field nulling is not enough on its own: diagnosis summaries
    interpolate these values into prose ("Your WiFi channel is crowded on
    MyHouse at 203.0.113.77."), so the same string has to be caught
    wherever it landed, not just in the field it was copied out of.
    """
    if isinstance(node, dict):
        return {k: scrub(v, secrets) for k, v in node.items()}
    if isinstance(node, list):
        return [scrub(v, secrets) for v in node]
    if isinstance(node, str):
        for s in secrets:
            node = node.replace(s, REDACTED)
        return node
    return node


def redact(record: dict) -> dict:
    return scrub(record, secrets_in(record))


def render(record: dict) -> str:
    """Replaced in full by the next task. Dumping the redacted record is
    enough to prove the scrub works, and nothing ships between these two
    commits."""
    return json.dumps(record, indent=2)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--file", type=str, default=None,
                     help="Read the run's JSON from PATH instead of stdin.")
    args = ap.parse_args()

    if args.file:
        try:
            with open(args.file, "r", encoding="utf-8") as f:
                raw = f.read()
        except OSError as e:
            print(f"netdiag-share: cannot read {args.file}: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        raw = sys.stdin.read()

    try:
        record = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"netdiag-share: input is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(record, dict):
        print("netdiag-share: input is not valid JSON: expected an object",
              file=sys.stderr)
        sys.exit(1)

    print(render(redact(record)))


if __name__ == "__main__":
    main()
