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
import os
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


def _require_threshold(name: str) -> float:
    """Read one cutoff from the environment, or refuse to run.

    No defaults, ever. A default here would be a second home for a number
    that has exactly one home (lib/thresholds.sh), and a stale second copy
    still produces a plausible verdict — the failure nobody notices. Same
    contract helpers/history.py holds for THRESH_COMPARE_*.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        print(f"summary.py: {name} is not set. It is defined in "
              f"lib/thresholds.sh and exported by bin/netdiag before this "
              f"helper runs.", file=sys.stderr)
        sys.exit(3)
    try:
        return float(raw)
    except ValueError:
        print(f"summary.py: {name}={raw!r} is not a number. It is defined "
              f"in lib/thresholds.sh.", file=sys.stderr)
        sys.exit(3)


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


OK, WARN, CRIT = "✓", "⚠", "×"


def judge(value: float, warn: float, crit: float, higher_is_worse: bool = True) -> str:
    """One glyph for one number, against two cutoffs from thresholds.sh.

    The comparisons here are against named parameters, never literals —
    tests/test_thresholds.bats greps this file for a bare number beside a
    comparison operator and fails the build on one.
    """
    if higher_is_worse:
        if value >= crit:
            return CRIT
        if value >= warn:
            return WARN
        return OK
    if value <= crit:
        return CRIT
    if value <= warn:
        return WARN
    return OK


def stats(label: str, values: list[float | int], unit: str = "",
          warn: float | None = None, crit: float | None = None,
          higher_is_worse: bool = True) -> str:
    if not values:
        # Absence of a measurement is not a verdict. Same rule the Report
        # card follows when it renders a grey minus.circle instead of a
        # green dot on a row that was never measured.
        return f"     {label:24s}  no data"
    lo, med, hi = min(values), statistics.median(values), max(values)
    body = (f"{fmt_val(lo)}{unit} / {fmt_val(med)}{unit} / {fmt_val(hi)}{unit}"
            f"   ({plural(len(values), 'sample')})")
    if warn is None or crit is None:
        return f"     {label:24s}  {body}"

    # The glyph judges the median — the typical case, which is what a
    # distribution summary is for. A worse extreme is named rather than
    # promoted: "usually fine, once terrible" is the true sentence, and
    # letting the max own the glyph would make one bad minute in a month
    # read as a broken network.
    glyph = judge(med, warn, crit, higher_is_worse)
    worst = judge(hi if higher_is_worse else lo, warn, crit, higher_is_worse)
    if worst != glyph:
        extreme = hi if higher_is_worse else lo
        body += f"   {worst} {'max' if higher_is_worse else 'min'} {fmt_val(extreme)}{unit}"
    return f"  {glyph}  {label:24s}  {body}"


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

    print("     metric                    min / med / max")
    print(stats("gateway RTT (ms)", metric("gateway.rtt_avg_ms")))
    print(stats("gateway loss (%)", metric("gateway.loss_pct"),
                warn=_require_threshold("LOSS_WARN_PCT"),
                crit=_require_threshold("LOSS_CRIT_PCT")))
    print(stats("bufferbloat gw Δ (ms)", metric("bufferbloat.gw_delta_ms"),
                warn=_require_threshold("THRESH_BUFFERBLOAT_B_MS"),
                crit=_require_threshold("THRESH_BUFFERBLOAT_C_MS")))
    print(stats("bufferbloat inet Δ (ms)", metric("bufferbloat.inet_delta_ms"),
                warn=_require_threshold("THRESH_BUFFERBLOAT_B_MS"),
                crit=_require_threshold("THRESH_BUFFERBLOAT_C_MS")))
    # higher_is_worse=False, so judge() tests the critical cutoff first, and
    # a lower (more negative) dBm is worse. THRESH_WIFI_RSSI_WEAK_DBM (-75)
    # is worse than THRESH_WIFI_RSSI_G1_DBM (-70), so the weak cutoff is
    # crit and the G1 cutoff is warn. Swapping them would put every reading
    # at or below G1's cutoff into the critical band, leaving the warn band
    # unreachable: a signal a few dBm past G1 would read identically to one
    # deep past the weak floor.
    print(stats("WiFi RSSI (dBm)", metric("wifi.rssi"),
                warn=_require_threshold("THRESH_WIFI_RSSI_G1_DBM"),
                crit=_require_threshold("THRESH_WIFI_RSSI_WEAK_DBM"),
                higher_is_worse=False))
    print(stats("path MTU", metric("mtu.effective"),
                warn=_require_threshold("THRESH_MTU_STANDARD"),
                crit=_require_threshold("THRESH_MTU_CRIT"),
                higher_is_worse=False))
    print(stats("NTP drift (s)", metric("ntp.drift_seconds"),
                warn=_require_threshold("THRESH_NTP_DRIFT_WARN_S"),
                crit=_require_threshold("THRESH_NTP_DRIFT_CRIT_S")))
    # Throughput has no absolute cutoff — "slow" is relative to what this
    # link has done before, which is BL-1's job in --show, not a number
    # that could live in thresholds.sh. Reported unjudged, deliberately.
    print(stats("speedtest down (Mbps)", metric("speedtest.down_mbps")))
    print(stats("speedtest up   (Mbps)", metric("speedtest.up_mbps")))
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
