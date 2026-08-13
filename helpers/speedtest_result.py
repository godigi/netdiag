#!/usr/bin/env python3
"""Parse a speed test's FINAL result JSON into one tab-separated line.

Called from lib/speedtest.sh with the last line of a completed test piped
in on stdin — either Ookla `speedtest`'s `{"type":"result",...}` object
(the same object `--format=json` would print on its own; see the comment
above `speedtest_translate_line` in lib/speedtest.sh) or `speedtest-cli
--json`'s single result object. This replaces ~10 `jq -r` calls that used
to do the same extraction, so netdiag's speed test no longer needs jq on
PATH — python3 stdlib is the only requirement left.

Output (stdout): one line, five tab-separated fields, empty string for any
field that was absent, non-numeric, or the wrong shape:

    down_mbps<TAB>up_mbps<TAB>latency_ms<TAB>jitter_ms<TAB>server

Malformed or empty stdin is not a distinct error case — it parses to the
same "object with no recognized fields" result as valid-but-irrelevant
JSON, so the output is always exactly one line of (possibly all-empty)
tab-separated fields, and this always exits 0. The caller tells success
from failure the same way the old jq pipeline did: down_mbps is empty
exactly when `.download`/`.download.bandwidth` was missing or not a
number, which is what jq -e used to gate on.

── This function is a security boundary ─────────────────────────────────
Same deny-by-default discipline lib/speedtest.sh documents around its own
jq calls, restated here because this file is where it now actually
happens: an Ookla result object carries `interface.internalIp` (on a
dual-stack machine, the host's public IPv6 address — identifies a
household the way a NATed v4 address does not), `interface.externalIp`,
`interface.macAddr`, and `result.url`. None of that may ever reach
stdout, even by accident.

So exactly five fields are extracted **by name**, and each is also
shape-checked before being trusted: a number field is rejected unless it
is actually `int`/`float` (never `bool`, which is an `int` subclass in
Python, and never NaN/Infinity, which `json` will happily parse), and a
string field is rejected unless it is actually `str`. Nothing here ever
takes a whole sub-object and serializes it back out — a filter would have
to enumerate what is dangerous and would be wrong the day Ookla adds a
field; this instead enumerates the five things that are wanted and
extracts only those.

── Both flavors ──────────────────────────────────────────────────────────
Ookla:        {"download": {"bandwidth": <bytes/sec>, ...},
               "upload":   {"bandwidth": <bytes/sec>, ...},
               "ping":     {"latency": <ms>, "jitter": <ms>, ...},
               "server":   {"name": <str>, ...}}
              bandwidth is bytes/sec; ×8/1e6 converts to Mbps (matches the
              bash arithmetic in speedtest_translate_line's progress path).

speedtest-cli: {"download": <bits/sec>, "upload": <bits/sec>,
                "ping": <ms>, "server": {"host": <str>, ...}}
               already bits/sec; /1e6 converts to Mbps. No jitter field —
               that column is always empty for this flavor.

`download`'s shape (object vs number) is what selects the flavor; the two
never overlap in real output, so there is no separate "which tool ran"
signal to trust or get wrong.
"""

from __future__ import annotations

import json
import math
import sys


def _is_num(x: object) -> bool:
    """True for a JSON number, and only a JSON number.

    Not `bool` (an `int` subclass in Python — a stray `true` must never be
    read as 1), and not NaN/Infinity (which `json.loads` parses by default
    but which have no sane tab-separated representation).
    """
    if isinstance(x, bool):
        return False
    if not isinstance(x, (int, float)):
        return False
    return math.isfinite(x)


def _parse_ookla(
    doc: dict, download: dict, server: dict
) -> tuple[str, str, str, str, str]:
    upload = doc.get("upload")
    upload = upload if isinstance(upload, dict) else {}
    ping = doc.get("ping")
    ping = ping if isinstance(ping, dict) else {}

    down_bw = download.get("bandwidth")
    up_bw = upload.get("bandwidth")
    latency = ping.get("latency")
    jitter = ping.get("jitter")
    name = server.get("name")

    return (
        f"{down_bw * 8 / 1_000_000:.1f}" if _is_num(down_bw) else "",
        f"{up_bw * 8 / 1_000_000:.1f}" if _is_num(up_bw) else "",
        str(latency) if _is_num(latency) else "",
        str(jitter) if _is_num(jitter) else "",
        name if isinstance(name, str) else "",
    )


def _parse_cli(
    doc: dict, download: float, server: dict
) -> tuple[str, str, str, str, str]:
    upload = doc.get("upload")
    ping = doc.get("ping")
    host = server.get("host")

    return (
        # download is numeric by construction: parse() dispatched on it.
        f"{download / 1_000_000:.1f}",
        f"{upload / 1_000_000:.1f}" if _is_num(upload) else "",
        str(ping) if _is_num(ping) else "",
        "",  # speedtest-cli's JSON has no jitter field.
        host if isinstance(host, str) else "",
    )


def parse(doc: object) -> tuple[str, str, str, str, str]:
    """Five-field tuple — down_mbps, up_mbps, latency_ms, jitter_ms,
    server; main() joins them into the tab-separated line. Deny-by-default:
    only ever these five names, only ever after a type check, never a
    passed-through object."""
    if not isinstance(doc, dict):
        return "", "", "", "", ""

    download = doc.get("download")
    server = doc.get("server")
    server = server if isinstance(server, dict) else {}

    if isinstance(download, dict):
        return _parse_ookla(doc, download, server)
    if _is_num(download):
        return _parse_cli(doc, download, server)
    # Neither shape recognized (missing, null, or the wrong type) — same
    # "nothing to report" result malformed/empty stdin produces.
    return "", "", "", "", ""


def main() -> None:
    raw = sys.stdin.read()
    try:
        doc = json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError:
        doc = None
    down_mbps, up_mbps, latency_ms, jitter_ms, server = parse(doc)
    sys.stdout.write(f"{down_mbps}\t{up_mbps}\t{latency_ms}\t{jitter_ms}\t{server}\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # One-shot writer like capabilities.py: this only silences the
        # traceback when a consumer closes early.
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        sys.exit(1)
