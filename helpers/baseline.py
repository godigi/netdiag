#!/usr/bin/env python3
"""Compare a netdiag JSON snapshot to medians over the last N historical runs.

Inputs:
  --history PATH   Path to a JSONL file with one snapshot per line.
  --current PATH   Path to the current snapshot JSON (separate file).
  --n N            How many prior snapshots to consider (default 10).

Output (stdout): a JSON object
  {
    "compared_runs": N,
    "regressions": [
      {"metric": "gateway.rtt_avg_ms", "current": 12.3, "median": 3.5,
       "label": "gateway RTT", "kind": "spike|drop|drift"}
    ]
  }

Regressions are surfaced when:
  * a "higher is worse" metric (RTT, loss, delta, drift) exceeds median × FACTOR
  * a "higher is better" metric (RSSI, throughput) falls below median × FACTOR
  * an absolute-comparison metric (PMTU, ISP, WiFi channel) changes value
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path
from typing import Any

# (path, human label, kind, factor)
#   spike: flag when current > median * factor
#   drop:  flag when current < median * factor
#   drift: flag when |current - median| / |median| > 0.5
#   change: flag when value != prior majority
METRICS: list[tuple[str, str, str, float | None]] = [
    ("gateway.rtt_avg_ms",        "gateway RTT",         "spike", 3.0),
    ("gateway.loss_pct",          "gateway loss%",       "spike", 2.0),
    ("bufferbloat.gw_delta_ms",   "bufferbloat gw Δ",    "spike", 3.0),
    ("bufferbloat.inet_delta_ms", "bufferbloat inet Δ",  "spike", 3.0),
    ("mtu.effective",             "path MTU",            "change", None),
    ("wifi.rssi",                 "WiFi RSSI",           "drop", 1.15),  # current < median * 1.15 → worse
    ("ntp.drift_seconds",         "NTP drift",           "drift", None),
    ("speedtest.down_mbps",       "speedtest down",      "drop", 0.5),
    ("speedtest.up_mbps",         "speedtest up",        "drop", 0.5),
    ("public.isp",                "ISP",                 "change", None),
    ("wifi.channel",              "WiFi channel",        "change", None),
]


def get_nested(d: dict | None, path: str) -> Any:
    cur: Any = d
    for k in path.split("."):
        if cur is None or not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


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


def evaluate(current: dict, history: list[dict]) -> list[dict]:
    regressions: list[dict] = []
    for path, label, kind, factor in METRICS:
        cur = get_nested(current, path)
        if cur is None:
            continue
        hist = [get_nested(r, path) for r in history]
        hist_clean: list[float | int | str] = [v for v in hist if v is not None]
        if not hist_clean:
            continue

        if kind == "change":
            counts: dict[Any, int] = {}
            for v in hist_clean:
                counts[v] = counts.get(v, 0) + 1
            majority = max(counts.items(), key=lambda kv: kv[1])
            if majority[1] >= max(3, len(hist_clean) // 2) and cur != majority[0]:
                regressions.append({
                    "metric": path, "current": cur, "median": majority[0],
                    "label": label, "kind": "change",
                })
            continue

        nums = [float(v) for v in hist_clean if isinstance(v, (int, float))]
        if len(nums) < 3:
            continue
        med = statistics.median(nums)
        try:
            cur_f = float(cur)
        except (TypeError, ValueError):
            continue

        if kind == "spike" and factor is not None and med > 0 and cur_f > med * factor:
            regressions.append({
                "metric": path, "current": cur_f, "median": med,
                "label": label, "kind": "spike",
                "factor": round(cur_f / med, 1) if med else None,
            })
        elif kind == "drop" and factor is not None and med != 0:
            # For RSSI (negative dBm), more-negative is worse; flip the inequality.
            if path == "wifi.rssi":
                if cur_f < med * factor:
                    regressions.append({
                        "metric": path, "current": cur_f, "median": med,
                        "label": label, "kind": "drop",
                    })
            elif cur_f < med * factor:
                regressions.append({
                    "metric": path, "current": cur_f, "median": med,
                    "label": label, "kind": "drop",
                })
        elif kind == "drift" and med != 0 and abs(cur_f - med) / abs(med) > 0.5:
            regressions.append({
                "metric": path, "current": cur_f, "median": med,
                "label": label, "kind": "drift",
            })
    return regressions


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--history", required=True, type=Path)
    ap.add_argument("--current", required=True, type=Path)
    ap.add_argument("--n", type=int, default=10)
    args = ap.parse_args()

    history_all = load_jsonl(args.history)
    history = history_all[-args.n:] if history_all else []

    try:
        current = json.loads(args.current.read_text())
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(json.dumps({"error": f"cannot read current: {e}"}), file=sys.stderr)
        sys.exit(1)

    regressions = evaluate(current, history) if len(history) >= 3 else []
    out = {"compared_runs": len(history), "regressions": regressions}
    json.dump(out, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
