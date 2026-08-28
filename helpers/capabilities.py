#!/usr/bin/env python3
"""Emit `netdiag --capabilities` as a single JSON object.

Called once from bin/netdiag's --capabilities mode with every value
already resolved in bash and passed in as NETDIAG_CAP_* environment
variables — the same pattern lib/monitor.sh uses to reach
helpers/monitor_sample.py, and lib/thresholds.sh uses to reach
helpers/history.py's --show. bash cannot escape a string into JSON
safely, so nothing here is hand-assembled into a JSON literal in the
shell; this helper is the only thing that writes braces and quotes.

This is a capabilities *handshake*, not a diagnosis: every value below is
a fact about this install (a version, a boolean, a schema number), never
a verdict. Nothing here reads lib/thresholds.sh.

`schemas` mirrors the schema number already embedded in five other
outputs, and declares two more that don't carry one yet:
  * monitor       — lib/monitor.sh's _mon_emit() sets
    NETDIAG_MON_SCHEMA, read by helpers/monitor_sample.py.
  * show          — helpers/history.py's build_detail(), literal
    "schema": 1.
  * history       — helpers/history.py's main() --history branch,
    literal "schema": 1.
  * rules_catalog — helpers/rules_catalog.py's own SCHEMA_RULES_CATALOG,
    literal "schema": SCHEMA_RULES_CATALOG.
  * signal_scale  — helpers/signal_scale.py's own SCHEMA_SIGNAL_SCALE,
    literal "schema": SCHEMA_SIGNAL_SCALE.
  * run           — helpers/emit_json.py (the --json output) embeds no
    schema field today; defaults to 1 here so a consumer always has a
    number.
  * progress      — the --progress event stream (docs/JSON-SCHEMA.md)
    embeds no schema field either, for the same reason.
Bump the constant below the day either of the last two actually grows a
field, so this file never has to be discovered as the odd one out.
"""

from __future__ import annotations

import json
import os
import sys

# This file's own schema: the shape of the --capabilities document.
SCHEMA_CAPABILITIES = 1

# Per-mode schema numbers — see the module docstring for where each one
# actually lives. Named constants so there is exactly one place to bump
# per source, not a literal buried in the dict below.
SCHEMA_RUN = 1            # no embedded field yet (see docstring)
SCHEMA_MONITOR = 2        # lib/monitor.sh: NETDIAG_MON_SCHEMA
SCHEMA_HISTORY = 2        # helpers/history.py main(): "schema"
SCHEMA_SHOW = 1           # helpers/history.py build_detail(): "schema"
SCHEMA_RULES_CATALOG = 4  # helpers/rules_catalog.py: SCHEMA_RULES_CATALOG
SCHEMA_SIGNAL_SCALE = 1   # helpers/signal_scale.py: SCHEMA_SIGNAL_SCALE
SCHEMA_PROGRESS = 1       # no embedded field yet (see docstring)

# Not closed — a follow-up task appends to this list as new CLI surface
# ships. Order is not meaningful.
FEATURES = [
    "capabilities",
    "version",
    "progress",
    "monitor",
    "history",
    "show",
    "redact",
    "speed-only",
    "dns-only",
    "bufferbloat-only",
    "ping-only",
    "watcher",
    # The event journal and the agent that records it. A consumer
    # checking for "events" is asking whether this build can answer
    # "what happened at 03:14", which older builds cannot at all.
    "events",
    "recorder",
    "rules-catalog",
    "signal-scale",
]


def _env(name: str) -> str | None:
    v = os.environ.get(f"NETDIAG_CAP_{name}")
    return v if v else None


def _bool(name: str) -> bool:
    return os.environ.get(f"NETDIAG_CAP_{name}") == "1"


def main() -> None:
    doc = {
        "schema": SCHEMA_CAPABILITIES,
        "version": _env("VERSION"),
        "schemas": {
            "run": SCHEMA_RUN,
            "monitor": SCHEMA_MONITOR,
            "history": SCHEMA_HISTORY,
            "show": SCHEMA_SHOW,
            "rules_catalog": SCHEMA_RULES_CATALOG,
            "signal_scale": SCHEMA_SIGNAL_SCALE,
            "progress": SCHEMA_PROGRESS,
        },
        "features": FEATURES,
        "deps": {
            "bash": _env("BASH_VERSION"),
            "python3": _env("PYTHON3_VERSION"),
            "jq": _bool("JQ"),
            "speedtest": _env("SPEEDTEST"),
            "mtr": _bool("MTR"),
            "gping": _bool("GPING"),
        },
    }
    json.dump(doc, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # One-shot writer, so unlike monitor_sample.py this isn't about a
        # long-lived stream — it only silences the traceback when a
        # consumer closes early (e.g. `netdiag --capabilities | head -c1`).
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        sys.exit(1)
