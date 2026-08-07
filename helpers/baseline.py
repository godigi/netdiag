#!/usr/bin/env python3
"""Compare a netdiag JSON snapshot to medians over the last N historical runs.

History is scoped by network identity (`network.id`, see lib/netid.sh).
Without that scoping the file is one flat stream across every network the
machine has ever been on, so a laptop moving between home, office, and a
café tripped "gateway RTT x4 spike", "ISP changed", "WiFi channel changed"
and "path MTU changed" on essentially every location change — each one an
add_diag warn that bumped the exit code to 1. Comparing a run only
against prior runs on the same network makes these regressions mean what
they claim to mean.

Records written before network identity existed have no `network.id`.
They're skipped rather than pooled, so old history ages out of relevance
instead of silently polluting the comparison.

Inputs:
  --history PATH   Path to a JSONL file with one snapshot per line.
  --current PATH   Path to the current snapshot JSON (separate file).
  --n N            How many prior snapshots to consider (default 10).

Output (stdout): a JSON object
  {
    "compared_runs": N,
    "network_id": "wifi:ssid=Home,mac=aa:bb:cc:dd:ee:01",
    "skipped_other_networks": 12,
    "regressions": [
      {"metric": "gateway.rtt_avg_ms", "current": 12.3, "median": 3.5,
       "label": "gateway RTT", "kind": "spike|drop|drift"}
    ]
  }

Regressions are surfaced when:
  * a "higher is worse" metric (RTT, loss, delta) exceeds median × FACTOR
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
#   change: flag when value != prior majority
#
# (The "drift" kind, which fired on |current - median|/|median| > 0.5, was
# removed along with ntp.drift_seconds — sub-second sntp jitter swamped the
# ratio and produced false positives. Reintroduce it only if a future metric
# genuinely needs symmetric, ratio-based comparison.)
#
# Note: ntp.drift_seconds is intentionally excluded. Sntp's sub-second drift
# values are dominated by UDP round-trip noise, so a "drift increased from
# 37ms to 60ms" regression isn't actionable — it's just two samples of the
# same noise floor. The ntp module surfaces drift directly when it crosses
# the 1s/30s thresholds where it actually affects apps.
METRICS: list[tuple[str, str, str, float | None]] = [
    ("gateway.rtt_avg_ms",        "gateway RTT",         "spike", 3.0),
    ("gateway.loss_pct",          "gateway loss%",       "spike", 2.0),
    ("bufferbloat.gw_delta_ms",   "bufferbloat gw Δ",    "spike", 3.0),
    ("bufferbloat.inet_delta_ms", "bufferbloat inet Δ",  "spike", 3.0),
    ("mtu.effective",             "path MTU",            "change", None),
    ("wifi.rssi",                 "WiFi RSSI",           "drop", 1.15),  # current < median * 1.15 → worse
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
    return regressions


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--history", required=True, type=Path)
    ap.add_argument("--current", required=True, type=Path)
    ap.add_argument("--n", type=int, default=10)
    args = ap.parse_args()

    try:
        current = json.loads(args.current.read_text())
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(json.dumps({"error": f"cannot read current: {e}"}), file=sys.stderr)
        sys.exit(1)

    history_all = load_jsonl(args.history)

    # Scope to the same network before taking the last N. Filtering first
    # matters: taking the tail first would leave a laptop with almost no
    # same-network history right after a batch of runs somewhere else.
    network_id = get_nested(current, "network.id")
    if network_id:
        same_network = [r for r in history_all
                        if get_nested(r, "network.id") == network_id]
    else:
        # No identity for the current run (no gateway MAC, no SSID, no
        # gateway). Comparing against an arbitrary mix would be worse than
        # not comparing, so don't.
        same_network = []
    skipped = len(history_all) - len(same_network)

    history = same_network[-args.n:] if same_network else []

    regressions = evaluate(current, history) if len(history) >= 3 else []
    out = {
        "compared_runs": len(history),
        "network_id": network_id,
        "skipped_other_networks": skipped,
        "regressions": regressions,
    }
    json.dump(out, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
