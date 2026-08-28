#!/usr/bin/env python3
"""Turn two `nettop` snapshots into "what was using the link, and how much".

Reads `nettop -P -x -J bytes_in,bytes_out -L 2 -s N` on stdin and writes one
compact JSON object on stdout. Parsing only: nothing here decides whether a
number is large. That judgement belongs to lib/diagnosis.sh reading
lib/thresholds.sh, like every other verdict in this project.

Why this measurement exists at all: netdiag measures the *path* and never
the traffic on it. A bufferbloat grade of D with a 40 Mb/s upload running is
a different fact from a D on an idle link — the first blames a backup, the
second blames the router's queue — and until now the report could not tell
them apart, so it blamed the router either way and sent the user shopping.

The input is two cumulative snapshots separated by a header line:

    time,,bytes_in,bytes_out,
    18:28:14.824828,mDNSResponder.506,114694167,25571561,
    time,,bytes_in,bytes_out,
    18:28:16.812445,mDNSResponder.506,114700608,25572378,

so a rate is the difference between them over the elapsed wall-clock, which
is passed in rather than derived from those timestamps: they carry no date,
so a sample straddling midnight would compute a negative interval.
"""

import json
import re
import sys

# netdiag's own traffic, excluded from the totals and from the top talkers.
#
# Not cosmetic: the sample deliberately runs alongside the parallel batch —
# nettop is a passive observer, so making it wait would add its whole window
# to the run for nothing — and that batch is DNS lookups, TCP connects, two
# WAN probes and a public-IP fetch. Counting those would have netdiag
# reporting itself as the process saturating the link, every single run.
#
# Matched on the process name only, before the `.pid` suffix.
SELF = frozenset({
    "netdiag", "curl", "dig", "nc", "ping", "ping6", "traceroute", "traceroute6",
    "mtr", "mtr-packet", "speedtest", "speedtest-cli", "sntp", "nettop",
    "python3", "gping",
})

# "<name>.<pid>" — the pid is nettop's, not something to report.
_PROC = re.compile(r"^(?P<name>.+)\.(?P<pid>\d+)$")


def parse_snapshots(text):
    """Two {process name: (bytes_in, bytes_out)} dicts, oldest first.

    Tolerates one snapshot (nettop killed early, or a machine where it
    refuses to run twice) by returning what it has; the caller decides
    that fewer than two means no measurement rather than a zero one.
    """
    snapshots = []
    current = None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("time,"):
            current = {}
            snapshots.append(current)
            continue
        if current is None:
            continue
        fields = line.split(",")
        if len(fields) < 4:
            continue
        match = _PROC.match(fields[1].strip())
        if not match:
            continue
        try:
            bytes_in = int(fields[2])
            bytes_out = int(fields[3])
        except ValueError:
            continue
        name = match.group("name")
        # One process can appear more than once (nettop lists per-connection
        # rows for some). Sum rather than overwrite.
        prev_in, prev_out = current.get(name, (0, 0))
        current[name] = (prev_in + bytes_in, prev_out + bytes_out)
    return snapshots


def deltas(first, last):
    """Per-process (down_bytes, up_bytes) between two cumulative snapshots.

    A process present in only the last snapshot started mid-window; its
    whole count is the delta. A negative delta — a counter that went
    backwards, which happens when a pid is reused inside the window — is
    dropped rather than clamped to zero, because a reused pid means the
    two numbers describe different processes and neither difference means
    anything.
    """
    out = {}
    for name, (in_last, out_last) in last.items():
        in_first, out_first = first.get(name, (0, 0))
        d_in, d_out = in_last - in_first, out_last - out_first
        if d_in < 0 or d_out < 0:
            continue
        if d_in or d_out:
            out[name] = (d_in, d_out)
    return out


def mbps(byte_count, seconds):
    if seconds <= 0:
        return 0.0
    return round(byte_count * 8 / seconds / 1_000_000, 2)


def main():
    if len(sys.argv) < 2:
        print("usage: traffic.py <sample_seconds>", file=sys.stderr)
        return 3
    try:
        seconds = float(sys.argv[1])
    except ValueError:
        print("traffic.py: sample seconds must be a number", file=sys.stderr)
        return 3

    snapshots = parse_snapshots(sys.stdin.read())
    if len(snapshots) < 2:
        # No measurement, which is not the same as a measurement of zero.
        json.dump({"measured": False}, sys.stdout, separators=(",", ":"))
        return 0

    per_process = deltas(snapshots[0], snapshots[-1])
    total_down = sum(d for name, (d, _) in per_process.items() if name not in SELF)
    total_up = sum(u for name, (_, u) in per_process.items() if name not in SELF)

    talkers = sorted(
        ((name, d, u) for name, (d, u) in per_process.items() if name not in SELF),
        key=lambda row: row[1] + row[2],
        reverse=True,
    )

    json.dump(
        {
            "measured": True,
            "sampled_s": seconds,
            "down_mbps": mbps(total_down, seconds),
            "up_mbps": mbps(total_up, seconds),
            "top_processes": [
                {
                    "name": name,
                    "down_mbps": mbps(d, seconds),
                    "up_mbps": mbps(u, seconds),
                }
                for name, d, u in talkers[:3]
                if d or u
            ],
        },
        sys.stdout,
        separators=(",", ":"),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
