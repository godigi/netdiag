#!/usr/bin/env python3
"""Judge one metric's median against its warn/critical cutoffs.

Two things now compose a per-network verdict out of the stored run
history: `netdiag --summary`'s text report (helpers/summary.py) and
`netdiag --history`'s `judged` JSON block (helpers/history.py). Before
this module existed those were on a collision course — summary.py already
had its own glyph-emitting `judge()` compared against its own local
threshold reads, and history.py was about to grow a second, JSON-shaped
version of exactly the same judgement. Two implementations of one
judgement is precisely the shape that drifts silently: a menu-bar app
reading `judged` and a terminal reading `--summary`'s prose would end up
telling the user two different things about the same network, with
nothing to say which one lied.

This module is the one shared pair-table — metric key, warn cutoff env
name, critical cutoff env name, direction, and a plain-language phrase —
that both consumers read. `--summary`'s text and `--history`'s `judged`
block can now only ever agree, because they are reading the same six
rows.

Import-side-effect-free, the same discipline helpers/history.py and
helpers/summary.py already hold: importing this module reads nothing,
opens nothing, and touches no environment variable. Every threshold is
read lazily, by name, the moment a caller actually asks for one — never
at import time, and never with a default.
"""

from __future__ import annotations

import os
import sys

# ── One cutoff, read from the one place it lives ──────────────────────────


def require_threshold(name: str) -> float:
    """Read one cutoff from the environment, or refuse to run.

    No defaults, ever. A default here would be a second home for a number
    that has exactly one home (lib/thresholds.sh), and a stale second copy
    still produces a plausible verdict — the failure nobody notices. This
    is the same contract helpers/history.py holds for THRESH_COMPARE_*,
    and the one helpers/summary.py's own (now-deleted) _require_threshold
    held before this module absorbed it.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        print(f"judgement.py: {name} is not set. It is defined in "
              f"lib/thresholds.sh and exported by bin/netdiag before this "
              f"helper runs.", file=sys.stderr)
        sys.exit(3)
    try:
        return float(raw)
    except ValueError:
        print(f"judgement.py: {name}={raw!r} is not a number. It is "
              f"defined in lib/thresholds.sh.", file=sys.stderr)
        sys.exit(3)


def level(value: float, warn: float, crit: float,
          higher_is_worse: bool = True) -> str:
    """One verdict word for one number, against two cutoffs from thresholds.sh.

    The comparisons here are against named parameters, never literals —
    tests/test_thresholds.bats greps this file for a bare number beside a
    comparison operator and fails the build on one.
    """
    if higher_is_worse:
        if value >= crit:
            return "critical"
        if value >= warn:
            return "warn"
        return "ok"
    if value <= crit:
        return "critical"
    if value <= warn:
        return "warn"
    return "ok"


# ── The one table both consumers judge from ───────────────────────────────
#
# Keyed by the --history metric key (helpers/history.py's METRICS table),
# so a network's already-computed metric_stats entry can be judged with a
# single dict lookup. Mirrors, row for row, the six metrics
# helpers/summary.py's report_network has always judged — derived by
# reading its judged stats(...) calls directly, not guessed. Every other
# metric METRICS carries (gateway RTT, jitter, internet RTT/loss,
# throughput) has no absolute cutoff to judge against, so it is
# deliberately absent here: absence from JUDGED_METRICS, and so from
# `judged.metrics`, is not a verdict of "healthy" — it means this metric
# has no policy threshold at all.
#
# (warn_env, crit_env, higher_is_worse, phrase_fragment)
JUDGED_METRICS: dict[str, tuple[str, str, bool, str]] = {
    "gateway_loss_pct": (
        "LOSS_WARN_PCT", "LOSS_CRIT_PCT", True,
        "the router drops packets"),
    "bufferbloat_gw_ms": (
        "THRESH_BUFFERBLOAT_B_MS", "THRESH_BUFFERBLOAT_C_MS", True,
        "the connection to the router bloats under load"),
    "bufferbloat_inet_ms": (
        "THRESH_BUFFERBLOAT_B_MS", "THRESH_BUFFERBLOAT_C_MS", True,
        "the connection to the internet bloats under load"),
    # higher_is_worse=False: a lower (more negative) dBm is worse, and
    # THRESH_WIFI_RSSI_G1_DBM (-70) is the milder cutoff, WEAK (-75) the
    # more severe one — same ordering summary.py's report_network has
    # always used, and the same reasoning is spelled out there.
    "wifi_rssi_dbm": (
        "THRESH_WIFI_RSSI_G1_DBM", "THRESH_WIFI_RSSI_WEAK_DBM", False,
        "the Wi-Fi signal is often weak"),
    # higher_is_worse=False: a smaller path MTU is worse.
    "mtu_effective": (
        "THRESH_MTU_STANDARD", "THRESH_MTU_CRIT", False,
        "the path MTU is often reduced"),
    "ntp_drift_s": (
        "THRESH_NTP_DRIFT_WARN_S", "THRESH_NTP_DRIFT_CRIT_S", True,
        "the clock often drifts out of sync"),
}


def _join_fragments(fragments: list[str]) -> str:
    """"a" / "a and b" / "a, b and c" — a plain-language offender list."""
    if not fragments:
        return ""
    if len(fragments) == 1:
        return fragments[0]
    return f"{', '.join(fragments[:-1])} and {fragments[-1]}"


def compose_summary(overall: str | None, offender_phrases: list[str],
                     n_checks: int) -> str:
    """The one sentence both --summary's text and --history's judged.summary
    render verbatim — see the module docstring for why there is only one
    of these rather than two wordings that could drift apart.

    `overall` is the worst verdict across JUDGED_METRICS for this network
    (or None when every judged metric is null, i.e. below
    THRESH_COMPARE_MIN_SAMPLES). `offender_phrases` is the phrase fragment
    of every metric that judged warn or critical, in JUDGED_METRICS order.
    """
    n = f"{n_checks:,}"
    if overall is None:
        return "Not enough checks on this network to judge it yet."
    if overall == "ok":
        return f"Usually healthy across {n} checks."
    fragment = _join_fragments(offender_phrases)
    if overall == "warn":
        return f"Usually healthy — but {fragment}."
    return f"Often having problems — {fragment}."
