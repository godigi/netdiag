#!/usr/bin/env python3
"""Aggregate ~/net-diag/baseline.jsonl into a 'what happened in the last
WINDOW' report. Designed for the netdiag --summary mode.

Inputs:
  --history PATH    JSONL file of snapshots
  --window HOURS    look-back window in hours (24, 168, 720, ...)

Output: a human-readable report on stdout. The report covers:
  * run count + first/last timestamps
  * count of runs with any diagnoses (== incident count)
  * worst-case gateway RTT, gateway loss, bufferbloat grade
  * WiFi RSSI range, channel changes
  * ISP changes
  * speedtest down/up min/median/max (if recorded)
  * PMTU shifts
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import textwrap
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

# Same directory, so a plain import works when this is run as
# `python3 helpers/summary.py`. Verified side-effect-free at import.
#
# Deliberately history.py rather than lib/netid.sh's netid_group: those
# two disagree today (tests/test_history.bats:116, tracker NET.2), and
# importing the Python side means --summary inherits --history's answer
# rather than silently picking a winner.
from history import group_key, clean, is_redacted

# Prose wrapping width. Not a threshold — nothing is judged against it and
# no diagnosis depends on it; it is the shape of a paragraph, which is why
# it lives here rather than in lib/thresholds.sh.
DIAGNOSIS_WRAP_COLS = 68


def load_jsonl(p: Path) -> list[dict]:
    if not p.exists():
        return []
    out: list[dict] = []
    with p.open(errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def get_nested(d: dict | None, path: str) -> Any:
    cur: Any = d
    for k in path.split("."):
        if cur is None or not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def parse_ts(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        if s.endswith("Z"):
            return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        return datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def fmt_val(v: Any) -> str:
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.1f}"
    return str(v)


def plural(n: int, noun: str) -> str:
    """'1 sample' / '2 samples'. The GUI's Trends counts were corrected
    for exactly this in 3e5ca0b; the CLI's were missed."""
    return f"{n} {noun}" if n == 1 else f"{n} {noun}s"


def stats(label: str, values: list[float | int], unit: str = "") -> str:
    if not values:
        return f"  {label:24s}  no data"
    lo, med, hi = min(values), statistics.median(values), max(values)
    return (f"  {label:24s}  {fmt_val(lo)}{unit} / {fmt_val(med)}{unit} / "
            f"{fmt_val(hi)}{unit}   ({plural(len(values), 'sample')})")


def report_network(label: str, records: list[dict]) -> None:
    """One network's block. Every figure here is scoped to `records`."""
    first_ts = parse_ts(records[0].get("timestamp"))
    last_ts = parse_ts(records[-1].get("timestamp"))

    print()
    print(f"── {label} — {plural(len(records), 'run')} ──")
    if first_ts and last_ts:
        print(f"  span: {first_ts.isoformat()} → {last_ts.isoformat()}")
    print()

    # Incident count = runs where the diagnosis array was non-empty.
    incidents = [r for r in records if r.get("diagnosis")]
    print(f"  incidents (any diagnosis):  {len(incidents)} / {len(records)} runs")
    if incidents:
        # Top recurring diagnosis summaries, wrapped rather than cut. The
        # CLI writes the fix into the back half of each sentence — "…the
        # box that…", advice following — so an 80-character truncation
        # reliably threw away the only actionable part.
        from collections import Counter
        all_summaries = [d.get("summary", "") for r in incidents for d in r.get("diagnosis", [])]
        for summary, n in Counter(all_summaries).most_common(5):
            lines = textwrap.wrap(summary, width=DIAGNOSIS_WRAP_COLS) or [""]
            print(f"     × {n:3d}  {lines[0]}")
            for continuation in lines[1:]:
                print(f"            {continuation}")
    print()

    # Metric distributions
    def metric(path: str) -> list[float]:
        out = []
        for r in records:
            v = get_nested(r, path)
            if isinstance(v, (int, float)):
                out.append(float(v))
        return out

    print("  metric                    min / med / max")
    print(stats("gateway RTT (ms)",       metric("gateway.rtt_avg_ms")))
    print(stats("gateway loss (%)",       metric("gateway.loss_pct")))
    print(stats("bufferbloat gw Δ (ms)",  metric("bufferbloat.gw_delta_ms")))
    print(stats("bufferbloat inet Δ (ms)", metric("bufferbloat.inet_delta_ms")))
    print(stats("WiFi RSSI (dBm)",        metric("wifi.rssi")))
    print(stats("path MTU",               metric("mtu.effective")))
    print(stats("NTP drift (s)",          metric("ntp.drift_seconds")))
    print(stats("speedtest down (Mbps)",  metric("speedtest.down_mbps")))
    print(stats("speedtest up   (Mbps)",  metric("speedtest.up_mbps")))
    print()

    # Categorical changes. Distinct ISPs is deliberately scoped to this one
    # network now: it answers "did this network's ISP change under me?"
    # instead of "how many places have I been?", which a blended view could
    # never tell apart from a single ISP migrating a whole city.
    isps = {get_nested(r, "public.isp") for r in records if get_nested(r, "public.isp")}
    channels = {get_nested(r, "wifi.channel") for r in records if get_nested(r, "wifi.channel")}
    pmtus = {get_nested(r, "mtu.effective") for r in records if get_nested(r, "mtu.effective")}

    print(f"  distinct ISPs seen:        {', '.join(sorted(isps)) or '-'}")
    print(f"  distinct WiFi channels:    {', '.join(sorted(map(str, channels))) or '-'}")
    print(f"  distinct path MTUs:        {', '.join(sorted(map(str, pmtus))) or '-'}")

    # WiFi disconnects: a maximum, never a sum.
    #
    # wifi_disconnects.count is a count of events in the past
    # WIFI_DISCONNECT_WINDOW_HOURS (1, lib/globals.sh:42), recomputed on
    # every run. Summing it across a 24h window adds twelve overlapping
    # one-hour views of the same events together — this printed "173" on a
    # laptop that had seen nothing like 173 disconnects. The worst single
    # window is a real quantity; the sum is not a quantity of anything.
    dc_counts = [c for r in records
                 if isinstance(c := get_nested(r, "wifi_disconnects.count"), int)]
    if dc_counts:
        worst = max(dc_counts)
        print(f"  WiFi disconnects:          busiest hour: "
              f"{plural(worst, 'disconnect')} "
              f"(worst of {plural(len(dc_counts), 'run')})")
    else:
        print("  WiFi disconnects:          no data")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--history", required=True, type=Path)
    ap.add_argument("--window", type=int, default=24, help="hours")
    args = ap.parse_args()

    records = load_jsonl(args.history)
    if not records:
        print("(no history yet — netdiag --watch will populate it)")
        return

    cutoff = datetime.now(timezone.utc) - timedelta(hours=args.window)
    in_window: list[dict] = []
    for r in records:
        ts = parse_ts(r.get("timestamp"))
        # A malformed timestamp cannot be placed in a time window. Exclude
        # it rather than keeping ancient/corrupt records in every summary.
        if ts is not None and ts >= cutoff:
            in_window.append(r)
    if not in_window:
        print(f"No runs in the last {args.window}h.")
        return

    # A --redact run carries network.id "wifi:mac=[redacted]", shared with
    # every other redacted run on every machine, so it can never join a
    # real group. helpers/history.py drops these for the same reason; if
    # the two disagreed, --summary and --history would report different
    # numbers of networks from one file.
    in_window = [r for r in in_window if not is_redacted(r)]
    if not in_window:
        print(f"No runs in the last {args.window}h.")
        return

    # One bucket per network, insertion-ordered so the block order follows
    # first appearance in the file, which is chronological.
    buckets: dict[str, list[dict]] = {}
    labels: dict[str, str] = {}
    for r in in_window:
        key, _ = group_key(r)
        buckets.setdefault(key, []).append(r)
        # Prefer a real label over a placeholder, and the most recent real
        # one over an older one — an SSID that only became visible later
        # still names the whole group.
        if label := clean(get_nested(r, "network.label")):
            labels[key] = label

    print(f"netdiag summary — last {args.window}h "
          f"({plural(len(in_window), 'run')} across "
          f"{plural(len(buckets), 'network')})")

    for key, records in buckets.items():
        report_network(labels.get(key, key), records)


if __name__ == "__main__":
    main()
