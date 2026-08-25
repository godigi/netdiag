#!/usr/bin/env python3
"""Emit `netdiag --signal-scale` as a single JSON object.

Exists because a raw RSSI number is meaningless to almost everyone who
sees one: "-62 dBm" tells a radio engineer something and tells everyone
else nothing. The GUI's Wi-Fi cell wants to show a *word* — "Good",
"Weak" — the way this project already turns every other measurement into
a verdict, and CLAUDE.md draws the same line here it draws everywhere
else: "the GUI holds no diagnostic logic." So the word, and the plain
sentence that explains it, are authored here, once, and the GUI renders
them verbatim.

This is a *scale*, not a per-sample verdict — closer in shape to
helpers/rules_catalog.py (a static catalog of meanings) than to
helpers/history.py's --show (a judgement of one specific reading). The
GUI needs exactly this shape: it takes a live RSSI from its own CoreWLAN
read (the monitor's RSSI is null without privileges — see
Services/RulesCatalogStore.swift's sibling store for the fetch pattern)
and looks up which band it falls in *itself*, entirely by comparing the
number to `min_dbm` — never by embedding a boundary of its own. Nothing
below is a threshold Swift is allowed to reimplement; every boundary is
one already named in lib/thresholds.sh.

Two of the three band edges already existed for a different reason —
THRESH_WIFI_RSSI_WEAK_DBM backs the W1 diagnosis rule, THRESH_WIFI_RSSI_G1_DBM
backs G1 — and are reused here rather than duplicated. The one new
constant, THRESH_WIFI_RSSI_EXCELLENT_DBM, exists only for this scale; see
its comment in lib/thresholds.sh. Like helpers/history.py's THRESH_COMPARE_*,
none of the three carries a Python-side default: this helper refuses to
run without them, because a stale fallback would silently drift from the
value a diagnosis rule actually fires on.

Bands are ordered strongest first — the order a GUI would want to walk
looking for "which one am I" from the top, and the order a legend reads
naturally. `min_dbm: null` marks the open-ended bottom band: there is no
floor to "weak", only a ceiling.
"""

from __future__ import annotations

import json
import os
import sys
from typing import NoReturn

# This file's own schema: the shape of the --signal-scale document.
SCHEMA_SIGNAL_SCALE = 1


def fail(message: str) -> NoReturn:
    """Refuse to answer, with the reason, and exit 3.

    Mirrors helpers/history.py's env_threshold: 3 is netdiag's "the caller
    or the environment is wrong" status, never 2 (reserved for a real
    diagnosis).
    """
    print(f"signal_scale.py: {message}", file=sys.stderr)
    sys.exit(3)


def env_threshold(name: str) -> int:
    """One cutoff from lib/thresholds.sh, or a loud failure.

    No default on purpose — see this file's own docstring and
    helpers/history.py's identical env_threshold for why a Python-side
    fallback is the failure mode this guards against, not a convenience.
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


def main() -> None:
    excellent = env_threshold("THRESH_WIFI_RSSI_EXCELLENT_DBM")
    good = env_threshold("THRESH_WIFI_RSSI_G1_DBM")
    fair = env_threshold("THRESH_WIFI_RSSI_WEAK_DBM")

    bands = [
        {
            "min_dbm": excellent,
            "label": "Excellent",
            "tone": "good",
            "blurb": (
                "Your Mac has a strong radio signal to the access point. "
                "That does not test whether the router or internet path "
                "is delivering traffic."
            ),
        },
        {
            "min_dbm": good,
            "label": "Good",
            "tone": "ok",
            "blurb": (
                "Your Mac has a solid radio signal to the access point. "
                "Signal strength alone cannot confirm that websites will "
                "load."
            ),
        },
        {
            "min_dbm": fair,
            "label": "Fair",
            "tone": "warn",
            "blurb": (
                "Your radio signal is on the weaker side, but this reading "
                "still does not identify whether an internet problem is "
                "local Wi-Fi, the router, or the provider."
            ),
        },
        {
            "min_dbm": None,
            "label": "Weak",
            "tone": "bad",
            "blurb": (
                "Your radio signal is weak or obstructed. Confirm the "
                "router and internet path with a reachability check before "
                "assuming signal strength is the cause."
            ),
        },
    ]

    doc = {
        "schema": SCHEMA_SIGNAL_SCALE,
        "bands": bands,
    }
    json.dump(doc, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # One-shot writer like rules_catalog.py / capabilities.py: this
        # only silences the traceback when a consumer closes early (e.g.
        # a `| head -c1`).
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        sys.exit(1)
