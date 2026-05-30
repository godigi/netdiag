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
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any


def load_jsonl(p: Path) -> list[dict]:
    if not p.exists():
        return []
    out: list[dict] = []
    with p.open() as f:
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


def stats(label: str, values: list[float | int], unit: str = "") -> str:
    if not values:
        return f"  {label:24s}  no data"
    lo, med, hi = min(values), statistics.median(values), max(values)
    return f"  {label:24s}  {fmt_val(lo)}{unit} / {fmt_val(med)}{unit} / {fmt_val(hi)}{unit}   ({len(values)} samples)"


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
        if ts is None or ts >= cutoff:
            in_window.append(r)
    if not in_window:
        print(f"No runs in the last {args.window}h.")
        return

    first_ts = parse_ts(in_window[0].get("timestamp"))
    last_ts = parse_ts(in_window[-1].get("timestamp"))

    print(f"netdiag summary — last {args.window}h ({len(in_window)} runs)")
    if first_ts and last_ts:
        print(f"  span: {first_ts.isoformat()} → {last_ts.isoformat()}")
    print()

    # Incident count = runs where the diagnosis array was non-empty.
    incidents = [r for r in in_window if r.get("diagnosis")]
    print(f"  incidents (any diagnosis):  {len(incidents)} / {len(in_window)} runs")
    if incidents:
        # Top recurring diagnosis summaries
        from collections import Counter
        all_summaries = [d.get("summary", "") for r in incidents for d in r.get("diagnosis", [])]
        for summary, n in Counter(all_summaries).most_common(5):
            short = summary[:80] + ("…" if len(summary) > 80 else "")
            print(f"     × {n:3d}  {short}")
    print()

    # Metric distributions
    def metric(path: str) -> list[float]:
        out = []
        for r in in_window:
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

    # Categorical changes
    isps = {get_nested(r, "public.isp") for r in in_window if get_nested(r, "public.isp")}
    channels = {get_nested(r, "wifi.channel") for r in in_window if get_nested(r, "wifi.channel")}
    pmtus = {get_nested(r, "mtu.effective") for r in in_window if get_nested(r, "mtu.effective")}

    print(f"  distinct ISPs seen:        {', '.join(sorted(isps)) or '-'}")
    print(f"  distinct WiFi channels:    {', '.join(sorted(map(str, channels))) or '-'}")
    print(f"  distinct path MTUs:        {', '.join(sorted(map(str, pmtus))) or '-'}")

    # WiFi disconnect totals
    dc_total = sum(get_nested(r, "wifi_disconnects.count") or 0 for r in in_window)
    print(f"  WiFi disconnect events:    {dc_total} (summed over {len(in_window)} runs)")


if __name__ == "__main__":
    main()
