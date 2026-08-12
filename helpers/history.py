#!/usr/bin/env python3
"""Normalize ~/net-diag/baseline.jsonl into network-grouped history JSON.

`netdiag --history` emits one object on stdout: the networks this machine
has been on, and one compact row per run. It exists because the raw store
is 5+ MB of full run snapshots — every traceroute hop, every DNS answer —
and the only view onto it was `--summary`'s text. A GUI charting two
months of gateway RTT should not have to decode all of that, and should
never have to reimplement network identity to do it.

    {"networks": [{"id": "...", "label": "...", "synthesized": true,
                   "first_seen": "...", "last_seen": "...",
                   "run_count": 412, ...}],
     "runs":     [{"ts": "...", "network_id": "...", "severity": "warn",
                   "diagnosis_count": 2, "root_cause": "...",
                   "metrics": {"gateway_rtt_ms": 3.4}}]}

Grouping is the whole substance of this file
────────────────────────────────────────────
Exact-string matching on `network.id` does not work, and the reason is not
hypothetical — it is what the author's own 1,972-record store looks like:

  * 1,926 records predate lib/netid.sh entirely and carry no `network.id`.
  * All 46 that do carry one are `wifi:mac=…`, because macOS has redacted
    the SSID throughout the v0.5.x era.
  * Every legacy record's `wifi.ssid` is the literal string `<redacted>`.

So legacy and modern records share no join key, and the id of the *same*
network changes again the day Location Services is granted, when
`wifi:mac=X` silently becomes `wifi:ssid=Y,mac=X`. Four rules follow:

  1. Parse the composite id and group by its `mac=` component when present.
     A network keeps one identity across an SSID rename or a Location
     Services grant.
  2. Backfill records without an id using lib/netid.sh's own precedence
     (gateway MAC → SSID → gateway IP), degraded to whatever the record
     actually has. Every backfilled group is marked `synthesized: true` so
     the UI can say so rather than implying a certainty it doesn't have.
  3. Bridge a synthesized SSID/gateway group into a MAC group when they
     agree on gateway IP *and* ISP (and WiFi channel where both know it).
     A bridge marks the merged group synthesized too.
  4. When the evidence is ambiguous — no candidate, or more than one —
     leave the groups apart and let the user merge them by hand in the
     app. A wrong merge silently corrupts a chart; a missing one is
     visible and fixable.

On the author's store rule 3 correctly bridges nothing: the legacy runs are
on 192.168.50.1 behind SPACEX-STARLINK, the modern ones on 192.168.15.1
behind TELEFONICA BRASIL. Those are two different networks on two
continents, and the honest answer is two groups.

Redacted records are dropped
────────────────────────────
Runs whose identity fields were masked by `--redact` before being appended
carry `network.id = "wifi:mac=[redacted]"`. They can never match a real
group, so they are dropped and counted rather than shown as a phantom
network. lib/output.sh stops producing them as of this release; these are
the historical ones.

One run, and what "normal" means for its network
────────────────────────────────────────────────
`--show ID` emits a single stored run instead of the whole store: the
record exactly as it was written, where it sits in that network's history,
and how each of its metrics compares to every other run on the same
network. A reading on its own says nothing — "3.7 ms" needs "and this
network usually does 3.2 ms" before anyone can act on it.

The comparison population is every run on that network, never a recent
window. One rule with nothing to configure, and the app's window picker
already narrows the charts when a recent view is what's wanted.

The two numbers that decide a verdict are deliberately absent from this
file. They arrive from lib/thresholds.sh through the environment, because
a cutoff that judges a network lives in exactly one place (CLAUDE.md), and
a Python default would be a second copy of it that nobody would notice
going stale.

Inputs:
  --history PATH   live JSONL store (required)
  --archive PATH   rolled-over older records; defaults to the
                   `-archive.jsonl` sibling of --history, skipped if absent
  --limit N        keep only the N most recent runs (0 = all)
  --show ID        emit one run instead of the store: full record, context
                   and comparison. Accepts a bare timestamp when it names
                   exactly one run. Needs THRESH_COMPARE_* in the
                   environment; see docs/JSON-SCHEMA.md for the shape.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import statistics
import sys
from pathlib import Path
from typing import Any, Iterable, NoReturn

# macOS substitutes this when the caller lacks Location Services, and
# --redact substitutes the other. Neither is a name; treating either as one
# would collapse every affected machine into a single shared identity.
PLACEHOLDERS = ("<redacted>", "[redacted]", "unknown", "")

# (json path, output key, label, unit, direction)
#
# direction is what a chart needs to colour a trend, and it is stated here
# rather than in Swift for the same reason every threshold lives in
# lib/thresholds.sh: the GUI renders what the CLI decides.
METRICS: list[tuple[str, str, str, str, str]] = [
    ("gateway.rtt_avg_ms",         "gateway_rtt_ms",       "Gateway RTT",        "ms",   "lower_is_better"),
    ("gateway.loss_pct",           "gateway_loss_pct",     "Gateway loss",       "%",    "lower_is_better"),
    ("gateway.rtt_jitter_ms",      "gateway_jitter_ms",    "Gateway jitter",     "ms",   "lower_is_better"),
    ("internet_latency.rtt_avg_ms", "inet_rtt_ms",         "Internet RTT",       "ms",   "lower_is_better"),
    ("internet_latency.loss_pct",  "inet_loss_pct",        "Internet loss",      "%",    "lower_is_better"),
    ("wifi.rssi",                  "wifi_rssi_dbm",        "WiFi signal",        "dBm",  "higher_is_better"),
    ("wifi.snr",                   "wifi_snr_db",          "WiFi SNR",           "dB",   "higher_is_better"),
    ("mtu.effective",              "mtu_effective",        "Path MTU",           "bytes", "higher_is_better"),
    ("bufferbloat.gw_delta_ms",    "bufferbloat_gw_ms",    "Bufferbloat (router)", "ms", "lower_is_better"),
    ("bufferbloat.inet_delta_ms",  "bufferbloat_inet_ms",  "Bufferbloat (ISP)",  "ms",   "lower_is_better"),
    ("speedtest.down_mbps",        "speed_down_mbps",      "Download",           "Mbps", "higher_is_better"),
    ("speedtest.up_mbps",          "speed_up_mbps",        "Upload",             "Mbps", "higher_is_better"),
    ("ntp.drift_seconds",          "ntp_drift_s",          "Clock drift",        "s",    "lower_is_better"),
]

SEVERITY_ORDER = {"info": 1, "warn": 2, "critical": 3}

# How much of the digest an id carries. Eight hex characters is short
# enough to read off a screen and retype, and long enough that the runs it
# has to separate — the handful that landed in the same wall-clock second —
# will not collide.
ID_HEX_CHARS = 8


def fail(message: str) -> NoReturn:
    """Refuse to answer, with the reason, and exit 3.

    3 is netdiag's "the caller or the environment is wrong" status. 2 is
    reserved for a real diagnosis, so a wrapper can keep telling "you typed
    the id wrong" apart from "your network is broken".
    """
    print(f"history.py: {message}", file=sys.stderr)
    sys.exit(3)


def env_threshold(name: str) -> int:
    """One cutoff from lib/thresholds.sh, or a loud failure.

    No default on purpose. A default would be a second home for a number
    CLAUDE.md says has exactly one, and the two would diverge the first
    time the value in lib/thresholds.sh was tuned — silently, because a
    stale cutoff still produces a plausible-looking verdict.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        fail(f"{name} is not set. It is defined in lib/thresholds.sh and "
             f"exported by bin/netdiag before this helper runs.")
    try:
        return int(raw)
    except ValueError:
        fail(f"{name}={raw!r} is not a whole number. It is defined in "
             f"lib/thresholds.sh.")


def get_nested(d: Any, path: str) -> Any:
    cur = d
    for k in path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def clean(v: Any) -> str | None:
    """A value usable as identity, or None. Placeholders are not values."""
    if not isinstance(v, str):
        return None
    s = v.strip()
    return None if s.lower() in [p.lower() for p in PLACEHOLDERS] else s


def parse_network_id(raw: str | None) -> dict[str, str]:
    """Split `wifi:ssid=Home,mac=aa:bb:…` into {kind, ssid, mac, gw}.

    Values may themselves contain '=' (rare in an SSID but legal), so each
    component splits on the *first* '=' only. Commas inside an SSID would
    break this, which is why the resulting parts are only ever used as
    identity hints — never round-tripped back into an id.
    """
    out: dict[str, str] = {}
    if not raw:
        return out
    kind, _, rest = raw.partition(":")
    if not rest:
        kind, rest = "", raw
    out["kind"] = kind or "lan"
    for part in rest.split(","):
        key, _, val = part.partition("=")
        val = clean(val)
        if val:
            out[key.strip()] = val
    return out


def group_key(rec: dict) -> tuple[str, bool]:
    """(stable group key, synthesized) for one record.

    Mirrors lib/netid.sh's precedence — gateway MAC, then SSID, then
    gateway IP — so a run recorded before netid.sh existed lands in the
    same group as one recorded after it, on the strongest evidence the
    record happens to carry.
    """
    parsed = parse_network_id(clean(get_nested(rec, "network.id")))
    if parsed.get("mac"):
        return f"mac:{parsed['mac'].lower()}", False
    if parsed.get("ssid"):
        return f"ssid:{parsed['ssid']}", False
    if parsed.get("gw"):
        return f"gw:{parsed['gw']}", False

    # No usable id: backfill from the raw fields, and say so.
    mac = clean(get_nested(rec, "interface.gateway_mac"))
    if mac:
        return f"mac:{mac.lower()}", True
    ssid = clean(get_nested(rec, "wifi.ssid"))
    if ssid:
        return f"ssid:{ssid}", True
    gw = clean(get_nested(rec, "interface.gateway"))
    if gw:
        return f"gw:{gw}", True
    return "unknown", True


def is_redacted(rec: dict) -> bool:
    """True when --redact masked this record's identity before it was stored.

    Such a record can never join a real group: its network.id is the string
    "wifi:mac=[redacted]", shared with every other redacted run on every
    other network. Showing it as a network would invent one that does not
    exist.
    """
    for path in ("network.id", "interface.gateway_mac", "public.ip", "wifi.ssid"):
        v = get_nested(rec, path)
        if isinstance(v, str) and "[redacted]" in v:
            return True
    return False


def canonical(rec: dict) -> str:
    """The exact byte form deduplication keys on.

    An id hashes this and nothing else. If the two ever diverged, two
    records the dedup step considers the same run could be handed different
    ids, and an id would stop naming exactly one run — which is the only
    property that makes it worth having.
    """
    return json.dumps(rec, sort_keys=True, separators=(",", ":"))


def run_id(timestamp: str, canonical_json: str) -> str:
    """The stable name of one run: timestamp, a dot, and a digest head.

    `ts` alone cannot address a run — two runs land in the same second
    often enough that dedup already keys on the record's bytes as well.

    The separator is a dot rather than a '#': under zsh with EXTENDED_GLOB,
    which many setups enable, an unquoted `--show=…#…` is a glob pattern
    and fails with "no matches found", and this CLI has to work under both
    shells. Ids split on the *last* dot, so a timestamp that grows
    sub-second precision later still parses.
    """
    digest = hashlib.sha256(canonical_json.encode("utf-8")).hexdigest()
    return f"{timestamp}.{digest[:ID_HEX_CHARS]}"


def load_records(paths: Iterable[Path]) -> tuple[list[tuple[str, dict]], dict[str, int]]:
    """Read every JSONL source, dropping duplicates and redacted records.

    Deduplication is on (timestamp, canonical JSON) rather than timestamp
    alone. prune_history appends the head to the archive *before*
    truncating the live file, so a crash between the two yields
    byte-identical duplicates — which this catches — while two genuinely
    distinct runs that happen to land in the same wall-clock second are
    kept. Timestamps have one-second resolution and back-to-back manual
    runs do collide, so timestamp-only dedup would silently delete real
    measurements to solve a problem that never produces them.
    """
    stats = {"records_read": 0, "unparseable": 0, "duplicates": 0, "redacted": 0}
    seen: set[tuple[str, str]] = set()
    out: list[tuple[str, dict]] = []
    for p in paths:
        if not p.exists():
            continue
        with p.open(errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                stats["records_read"] += 1
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    stats["unparseable"] += 1
                    continue
                if not isinstance(rec, dict):
                    stats["unparseable"] += 1
                    continue
                if is_redacted(rec):
                    stats["redacted"] += 1
                    continue
                ts = str(rec.get("timestamp") or "")
                blob = canonical(rec)
                key = (ts, blob)
                if key in seen:
                    stats["duplicates"] += 1
                    continue
                seen.add(key)
                out.append((run_id(ts, blob), rec))
    out.sort(key=lambda pair: str(pair[1].get("timestamp") or ""))
    return out, stats


def run_severity(rec: dict) -> tuple[str, int, list[str]]:
    """(worst severity, count of non-info diagnoses, rule ids) for a run.

    Severity words and rule ids both come straight from the CLI's own
    diagnosis array. Nothing here decides what counts as a fault.
    """
    diags = rec.get("diagnosis")
    if not isinstance(diags, list):
        return "ok", 0, []
    worst, faults, rules = 0, 0, []
    for d in diags:
        if not isinstance(d, dict):
            continue
        sev = d.get("severity")
        rank = SEVERITY_ORDER.get(sev, 0)
        worst = max(worst, rank)
        if rank >= SEVERITY_ORDER["warn"]:
            faults += 1
        rule = d.get("rule")
        if rule and rule not in rules:
            rules.append(rule)
    inv = {v: k for k, v in SEVERITY_ORDER.items()}
    return inv.get(worst, "ok"), faults, rules


def metric_value(rec: dict, path: str) -> float | None:
    """One metric as a number, or None when this run did not measure it.

    A bool is not a measurement even though Python says it is an int:
    `true` reaching a chart as 1 ms is a reading that never happened.
    """
    v = get_nested(rec, path)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


def build_run(rid: str, rec: dict, key: str) -> dict:
    sev, faults, rules = run_severity(rec)
    metrics: dict[str, float] = {}
    for path, out_key, _label, _unit, _dir in METRICS:
        v = metric_value(rec, path)
        if v is None:
            continue
        metrics[out_key] = v
    return {
        "id": rid,
        "ts": rec.get("timestamp"),
        "network_id": key,
        "version": rec.get("version"),
        "severity": sev,
        "diagnosis_count": faults,
        "rules": rules,
        "root_cause": rec.get("most_likely_root_cause"),
        "metrics": metrics,
    }


def bridge_candidates(groups: dict[str, dict]) -> dict[str, str]:
    """Map weak (ssid:/gw:) group keys onto the MAC group they belong to.

    Evidence is the tuple a router actually pins down: its LAN address and
    the provider behind it, plus WiFi channel where both sides recorded
    one. Both must agree, and exactly one MAC group must match — two
    candidates means the evidence does not distinguish them, and a wrong
    merge corrupts a chart in a way the user cannot see. Ambiguity is left
    for the app's manual "merge networks" action instead.
    """
    mac_groups = {k: g for k, g in groups.items() if k.startswith("mac:")}
    weak = {k: g for k, g in groups.items() if not k.startswith("mac:") and k != "unknown"}
    bridges: dict[str, str] = {}
    for wk, wg in weak.items():
        matches = []
        for mk, mg in mac_groups.items():
            gws = set(wg["gateways"]) & set(mg["gateways"])
            isps = set(wg["isps"]) & set(mg["isps"])
            if not gws or not isps:
                continue
            # Channel is corroboration when known on both sides, never a
            # veto when one side never recorded it — legacy runs almost
            # never did.
            if wg["channels"] and mg["channels"] and not (set(wg["channels"]) & set(mg["channels"])):
                continue
            matches.append(mk)
        if len(matches) == 1:
            bridges[wk] = matches[0]
    return bridges


def label_for(key: str, group: dict) -> str:
    """Human-readable name, preferring what the CLI already called it."""
    for lbl in group["labels"]:
        if clean(lbl) and not lbl.startswith("WiFi (SSID hidden"):
            return lbl
    if key.startswith("ssid:"):
        return key[5:]
    if key.startswith("mac:"):
        gw = group["gateways"][0] if group["gateways"] else None
        isp = group["isps"][0] if group["isps"] else None
        if gw and isp:
            return f"{isp} via {gw}"
        if gw:
            return f"Network at {gw}"
        return f"Network {key[4:]}"
    if key.startswith("gw:"):
        isp = group["isps"][0] if group["isps"] else None
        return f"{isp} via {key[3:]}" if isp else f"Network at {key[3:]}"
    return "Unknown network"


# ── One run against its network's history (--show) ───────────────────────
# Everything below runs only in --show mode. It is the only judgement this
# file makes, which is why it is the only part that reads lib/thresholds.sh.


def quantile(ordered: list[float], pct: float) -> float | None:
    """The value `pct` of the way up the sorted sample, interpolated.

    Interpolated rather than nearest-rank so the band edges move smoothly
    as history accumulates: a nearest-rank quantile jumps by a whole order
    statistic every time one run is added, and a "normal range" that
    twitches on every scan is one nobody trusts.
    """
    if not ordered:
        return None
    pos = (len(ordered) - 1) * pct / 100
    lo, hi = math.floor(pos), math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def percentile_rank(ordered: list[float], value: float) -> float:
    """Where `value` sits in `ordered`, on a 0–100 scale, ties averaged.

    Ties are averaged rather than counted as "at or below", because the
    usual shape here is a metric that reads the same in nearly every run:
    0.0% loss in 1,900 of 1,900 checks. Counting ties as below would put a
    flawless run at the 100th percentile and, for a lower-is-better metric,
    announce it as the worst thing that has ever happened on this network.
    """
    below = sum(1 for v in ordered if v < value)
    tied = sum(1 for v in ordered if v == value)
    return 100.0 * (below + tied / 2) / len(ordered)


def format_value(v: float | None, unit: str) -> str | None:
    """A measurement the way prose reads it: "3.7 ms", "-55 dBm", "0.4%".

    Whole numbers lose the decimal — an RSSI is -55 dBm, not -55.0 dBm —
    and only "%" closes up against its number, matching how the rest of
    this project prints a percentage.
    """
    if v is None:
        return None
    text = f"{v:,.0f}" if float(v).is_integer() else f"{v:,.1f}"
    return f"{text}{unit}" if unit == "%" else f"{text} {unit}"


def summary_for(verdict: str, value_text: str | None,
                median_text: str | None, n: int) -> str:
    """The sentence the app renders verbatim.

    The prose lives here for the same reason the thresholds live in
    lib/thresholds.sh: the GUI renders what the CLI decides. A second
    wording in Swift would be a second verdict.
    """
    checks = f"{n:,} check" + ("" if n == 1 else "s")
    if verdict == "not_measured":
        if median_text is None:
            return "Not measured in this check."
        return f"Not measured in this check (median {median_text} across {checks})."
    if verdict == "insufficient_data":
        return f"{value_text} — only {checks} on this network so far, too few to compare."
    if verdict == "best":
        return f"{value_text} — the best of {checks} on this network (median {median_text})."
    if verdict == "worst":
        return f"{value_text} — the worst of {checks} on this network (median {median_text})."
    if verdict == "better":
        return f"{value_text} — better than usual for this network (median {median_text} across {checks})."
    if verdict == "worse":
        return f"{value_text} — worse than usual for this network (median {median_text} across {checks})."
    return f"{value_text} — typical for this network (median {median_text} across {checks})."


def judge_metric(value: float | None, samples: list[float], unit: str,
                 direction: str, min_samples: int, tail_pctl: int) -> dict:
    """One metric's verdict against the whole population of this network."""
    ordered = sorted(samples)
    n = len(ordered)
    median = statistics.median(ordered) if ordered else None
    percentile: int | None = None
    # The upper tail is the lower one mirrored about the scale percentiles
    # are stated on, so one threshold sets both ends and neither can be
    # applied the wrong way round. 100 here is that scale, not a cutoff.
    upper_pctl = 100 - tail_pctl

    if value is None:
        # Never a zero. "This run did not measure it" and "this run
        # measured nothing" are different facts, and collapsing them is
        # what produced false diagnoses in earlier versions of this tool.
        verdict = "not_measured"
    elif n < min_samples:
        # percentile stays null: over a handful of readings it would state
        # a precision the sample does not have, and a UI showing "12th
        # percentile" next to "too few to compare" contradicts itself.
        verdict = "insufficient_data"
    else:
        # Rank first, judge second. The percentile is computed on the raw
        # value ascending with no notion of which end is good; `direction`
        # is applied here and only here, where a tail becomes a verdict.
        percentile = round(percentile_rank(ordered, value))
        lower_tail = percentile <= tail_pctl
        upper_tail = percentile >= upper_pctl
        lower_is_better = direction == "lower_is_better"
        if lower_tail:
            verdict = "better" if lower_is_better else "worse"
        elif upper_tail:
            verdict = "worse" if lower_is_better else "better"
        else:
            verdict = "typical"
        # best/worst only ever replace better/worse, so a network where
        # every run measured the same value stays "typical": that reading
        # is both the highest and the lowest, and picking either would be a
        # coin flip presented as a finding.
        best = ordered[0] if lower_is_better else ordered[-1]
        worst = ordered[-1] if lower_is_better else ordered[0]
        if verdict == "better" and value == best:
            verdict = "best"
        elif verdict == "worse" and value == worst:
            verdict = "worst"

    # p10/p90 are named for the default tail and follow it: they are the
    # edges of the band the verdict was drawn from, so a UI shading "normal
    # for this network" shades exactly what was judged.
    return {
        "value": value,
        "median": median,
        "p10": quantile(ordered, tail_pctl),
        "p90": quantile(ordered, upper_pctl),
        "percentile": percentile,
        "n": n,
        "direction": direction,
        "verdict": verdict,
        "summary": summary_for(verdict, format_value(value, unit),
                               format_value(median, unit), n),
    }


def build_comparison(rec: dict, network_runs: list[dict],
                     min_samples: int, tail_pctl: int) -> dict:
    """Every metric in METRICS, this run against every run on its network.

    Exactly that table, no second one: it already carries a direction per
    metric, which is why the CLI rather than the GUI is the thing that
    knows whether higher is better.
    """
    metrics: dict[str, dict] = {}
    for path, out_key, _label, unit, direction in METRICS:
        samples: list[float] = []
        for other in network_runs:
            v = metric_value(other, path)
            if v is not None:
                samples.append(v)
        metrics[out_key] = judge_metric(metric_value(rec, path), samples,
                                        unit, direction, min_samples, tail_pctl)
    return {"metrics": metrics}


def resolve_id(target: str, ids: list[str]) -> str:
    """An exact id, or a bare timestamp that names exactly one run.

    Typing a full id by hand is unpleasant and the timestamp is what a user
    already has in front of them, in a log filename or a report header. An
    ambiguous timestamp lists its candidates and picks nothing: silently
    choosing one would show a report for a run nobody asked for, and
    nothing in the output would give it away.
    """
    if target in ids:
        return target
    candidates = [rid for rid in ids if rid.rsplit(".", 1)[0] == target]
    if len(candidates) == 1:
        return candidates[0]
    if candidates:
        listed = "\n  ".join(candidates)
        fail(f"{target} matches more than one run. Pick one:\n  {listed}")
    fail(f"no run with id {target!r} in this history — it may have been "
         f"pruned, or recorded with --redact (those carry no id).")


def build_detail(target: str, assigned: list[tuple[str, dict, str]],
                 groups: dict[str, dict]) -> dict:
    """The --show object: one stored run, where it sits, how it compares.

    Thresholds are read before the id is resolved, so a broken install says
    so even when the id is wrong too.
    """
    min_samples = env_threshold("THRESH_COMPARE_MIN_SAMPLES")
    tail_pctl = env_threshold("THRESH_COMPARE_TAIL_PCTL")

    rid = resolve_id(target, [i for i, _rec, _key in assigned])
    rec, key = next((r, k) for i, r, k in assigned if i == rid)

    # `assigned` is chronological, oldest first, so the index is the
    # position, and the network's runs are the comparison population.
    network = [(i, r) for i, r, k in assigned if k == key]
    network_runs = [r for _i, r in network]
    position = [i for i, _r in network].index(rid) + 1
    group = groups.get(key, {})

    return {
        "schema": 1,
        # The version of netdiag rendering this view, not the one that
        # recorded the run — that is run.version. Absent when the helper is
        # invoked by hand: it labels the output, it does not decide
        # anything, so it is not worth refusing to run over.
        "version": os.environ.get("NETDIAG_VERSION") or None,
        "id": rid,
        "run": rec,
        "context": {
            # The grouped key, the same string --history reports for this
            # network. A raw network.id would not join to it: grouping is
            # what reconciles four eras of netdiag's identity scheme.
            "network_id": key,
            "runs_on_network": len(network_runs),
            "position": position,
            "first_seen": group.get("first_seen"),
            "last_seen": group.get("last_seen"),
        },
        "comparison": build_comparison(rec, network_runs, min_samples, tail_pctl),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="Normalized netdiag run history")
    ap.add_argument("--history", required=True, type=Path)
    ap.add_argument("--archive", type=Path, default=None)
    ap.add_argument("--limit", type=int, default=0,
                    help="keep only the N most recent runs (0 = all)")
    ap.add_argument("--show", metavar="ID", default=None,
                    help="emit one run — record, context and comparison — "
                         "instead of the whole store")
    args = ap.parse_args()

    archive = args.archive
    if archive is None:
        stem = str(args.history)
        archive = Path(stem[:-6] + "-archive.jsonl" if stem.endswith(".jsonl")
                       else stem + "-archive.jsonl")

    records, stats = load_records([archive, args.history])

    # Pass 1: assign every record a group and accumulate the evidence the
    # bridge heuristic needs.
    groups: dict[str, dict] = {}
    assigned: list[tuple[str, dict, str]] = []
    for rid, rec in records:
        key, synth = group_key(rec)
        g = groups.setdefault(key, {
            "run_count": 0, "synthesized": False, "first_seen": None, "last_seen": None,
            "gateways": [], "isps": [], "channels": [], "ssids": [], "labels": [],
            "metric_samples": {}, "severity_counts": {},
        })
        g["run_count"] += 1
        g["synthesized"] = g["synthesized"] or synth
        ts = rec.get("timestamp")
        if ts:
            g["first_seen"] = ts if g["first_seen"] is None else min(g["first_seen"], ts)
            g["last_seen"] = ts if g["last_seen"] is None else max(g["last_seen"], ts)
        for field, path in (("gateways", "interface.gateway"), ("isps", "public.isp"),
                            ("channels", "wifi.channel"), ("ssids", "wifi.ssid"),
                            ("labels", "network.label")):
            v = clean(get_nested(rec, path))
            if v and v not in g[field]:
                g[field].append(v)
        assigned.append((rid, rec, key))

    # Pass 2: bridge the weak groups that the evidence identifies, then
    # rewrite the affected assignments. Bridged groups inherit
    # synthesized=true — the merge is inference, not a recorded fact.
    bridges = bridge_candidates(groups)
    if bridges:
        for weak_key, mac_key in bridges.items():
            src, dst = groups.pop(weak_key), groups[mac_key]
            dst["run_count"] += src["run_count"]
            dst["synthesized"] = True
            dst.setdefault("bridged_from", []).append(weak_key)
            for f in ("gateways", "isps", "channels", "ssids", "labels"):
                for v in src[f]:
                    if v not in dst[f]:
                        dst[f].append(v)
            for bound, op in (("first_seen", min), ("last_seen", max)):
                if src[bound]:
                    dst[bound] = src[bound] if dst[bound] is None else op(dst[bound], src[bound])
        assigned = [(i, r, bridges.get(k, k)) for i, r, k in assigned]

    # --show wants one run in full, against the whole population of its
    # network, so it answers here — before --limit, which exists to keep a
    # chart's payload small and has nothing to say about a single record.
    if args.show is not None:
        json.dump(build_detail(args.show, assigned, groups), sys.stdout,
                  separators=(",", ":"), default=str)
        sys.stdout.write("\n")
        return

    # Pass 3: emit runs and count samples per metric, per network. The
    # sample count is not decoration: `wifi.rssi` is populated in 1 of
    # 1,926 legacy records here, so a chart that plots it without saying
    # how thin it is presents a single reading as a trend.
    runs = [build_run(rid, rec, key) for rid, rec, key in assigned]
    if args.limit and args.limit > 0:
        runs = runs[-args.limit:]

    global_samples: dict[str, int] = {}
    for run in runs:
        g = groups.get(run["network_id"])
        if g is None:
            continue
        g["severity_counts"][run["severity"]] = g["severity_counts"].get(run["severity"], 0) + 1
        for mk in run["metrics"]:
            g["metric_samples"][mk] = g["metric_samples"].get(mk, 0) + 1
            global_samples[mk] = global_samples.get(mk, 0) + 1

    networks = []
    for key, g in sorted(groups.items(), key=lambda kv: -kv[1]["run_count"]):
        networks.append({
            "id": key,
            "label": label_for(key, g),
            "synthesized": g["synthesized"],
            "bridged_from": g.get("bridged_from", []),
            "first_seen": g["first_seen"],
            "last_seen": g["last_seen"],
            "run_count": g["run_count"],
            "gateways": g["gateways"],
            "isps": g["isps"],
            "ssids": g["ssids"],
            "metric_samples": g["metric_samples"],
            "severity_counts": g["severity_counts"],
        })

    out = {
        "schema": 1,
        "sources": {
            "live": str(args.history),
            "archive": str(archive) if archive.exists() else None,
        },
        "counts": {
            "records_read": stats["records_read"],
            "unparseable_dropped": stats["unparseable"],
            "duplicates_dropped": stats["duplicates"],
            "redacted_dropped": stats["redacted"],
            "runs": len(runs),
            "networks": len(networks),
        },
        "metrics": [
            {"key": k, "label": lbl, "unit": u, "direction": d,
             "samples": global_samples.get(k, 0)}
            for _p, k, lbl, u, d in METRICS
        ],
        "networks": networks,
        "runs": runs,
    }
    json.dump(out, sys.stdout, separators=(",", ":"), default=str)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
