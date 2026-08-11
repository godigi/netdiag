#!/usr/bin/env python3
"""Emit one `netdiag --monitor` sample as a single compact JSON line.

Called once per cycle from lib/monitor.sh with the sample's state exported
as NETDIAG_MON_* environment variables — the same pattern as
helpers/emit_json.py, and for the same reason: bash cannot escape a string
into JSON safely. An SSID may legally contain a quote, a backslash or a
newline, and a printf-built stream that the GUI parses forever would
eventually meet one. Interpreter startup costs ~50 ms once per cadence;
a malformed line costs the whole session.

The shape is deliberately *smaller* than a full `--json` run and is
documented separately in docs/JSON-SCHEMA.md. It is not a subset by
accident — a monitor sample answers "what is true right now", a run
answers "what is wrong and why".

Conventions match the full schema:
  * null means the probe did not run this cycle (its tier wasn't due, or
    there is no link). It never means "ran and measured zero".
  * `status.rules` are IDs from docs/DIAGNOSIS-RULES.md, evaluated in
    lib/monitor.sh against lib/thresholds.sh. Consumers render them; they
    do not re-derive them.
"""

from __future__ import annotations

import json
import os
import sys


def _env(name: str) -> str | None:
    v = os.environ.get(f"NETDIAG_MON_{name}")
    return v if v else None


def _f(name: str) -> float | None:
    v = _env(name)
    if v is None:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def _i(name: str) -> int | None:
    v = _env(name)
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def _tri(name: str) -> bool | None:
    """Three-valued: "1" true, "0" false, unset/empty None.

    _bool() would be wrong for every probe that can be skipped. Collapsing
    "not measured" to false is what turns a tier that hasn't run yet into
    "the internet is down" — the exact false-critical shape the packet-loss
    predicates in lib/common.sh exist to prevent.
    """
    v = os.environ.get(f"NETDIAG_MON_{name}", "")
    if v == "1":
        return True
    if v == "0":
        return False
    return None


def build_tcp() -> list[dict]:
    """NETDIAG_MON_TCP_LINES is one 'host|port|ok|elapsed_ms' per line."""
    raw = os.environ.get("NETDIAG_MON_TCP_LINES", "")
    out: list[dict] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) < 3:
            continue
        host, port, ok = parts[0], parts[1], parts[2]
        entry: dict = {
            "host": host,
            "port": int(port) if port.isdigit() else port,
            "ok": ok == "1",
            "elapsed_ms": None,
        }
        if len(parts) > 3 and parts[3]:
            try:
                entry["elapsed_ms"] = float(parts[3])
            except ValueError:
                pass
        out.append(entry)
    return out


def main() -> None:
    is_wifi = _env("IFACE_TYPE") == "wifi"
    link_up = os.environ.get("NETDIAG_MON_LINK_UP") == "1"
    rules = (os.environ.get("NETDIAG_MON_RULES", "") or "").split()

    sample = {
        "schema": _i("SCHEMA") or 1,
        "version": _env("VERSION"),
        "ts": _env("TS"),
        "seq": _i("SEQ") or 0,
        # Which tiers actually refreshed this cycle. Everything outside
        # this list is carried over from an earlier sample, which a
        # consumer plotting a series needs to know before it draws a point.
        "refreshed": (os.environ.get("NETDIAG_MON_REFRESHED", "") or "").split(),
        "link": {
            "up": link_up,
            "interface": _env("INTERFACE"),
            "type": _env("IFACE_TYPE"),
            "ip": _env("LOCAL_IP"),
            "gateway": _env("GATEWAY"),
            "gateway_mac": _env("GW_MAC"),
            "ssid": _env("SSID"),
            "bssid": _env("BSSID"),
        },
        # Byte-identical to what a full run records, because lib/monitor.sh
        # calls lib/netid.sh rather than reimplementing precedence. This is
        # the join key between a live sample and the charted history.
        "network": {
            "id": _env("NETWORK_ID"),
            "label": _env("NETWORK_LABEL"),
        },
        "vpn": {
            "active": os.environ.get("NETDIAG_MON_VPN_ACTIVE") == "1",
            "type": _env("VPN_TYPE"),
            "name": _env("VPN_NAME"),
        },
        "gateway": {
            "loss_pct": _f("GW_LOSS"),
            "rtt_avg_ms": _f("GW_RTT"),
        },
        "wifi": ({
            "rssi": _i("WIFI_RSSI"),
            "noise": _i("WIFI_NOISE"),
            "snr": _i("WIFI_SNR"),
            "channel": _env("WIFI_CHAN"),
        } if is_wifi else None),
        "dns": {
            "ok": _tri("DNS_OK"),
            "resolver": _env("DNS_RESOLVER"),
            "elapsed_ms": _f("DNS_MS"),
        },
        "tcp": {
            "any_ok": _tri("TCP_OK"),
            "targets": build_tcp(),
        },
        "public": {
            "ok": _tri("PUBLIC_OK"),
            "ip": _env("PUB_IP"),
            "isp": _env("PUB_ISP"),
            "asn": _env("PUB_ASN"),
            "city": _env("PUB_CITY"),
            "country": _env("PUB_CC"),
            "country_iso": _env("PUB_CC_ISO"),
            "captive_portal": _tri("CAPTIVE"),
        },
        "status": {
            "severity": _env("SEVERITY") or "ok",
            "rules": rules,
            # TCP-1 holding is the global suppressor for every loss alert.
            # Surfaced as its own boolean so a consumer doesn't have to
            # string-match the rules array to find it.
            "icmp_filtered": os.environ.get("NETDIAG_MON_ICMP_FILTERED") == "1",
            "degraded": os.environ.get("NETDIAG_MON_DEGRADED") == "1",
            "cadence_s": _i("CADENCE_S"),
        },
    }

    json.dump(sample, sys.stdout, separators=(",", ":"), default=str)
    sys.stdout.write("\n")
    # Flush per sample: this is a stream, and a consumer that has to wait
    # for a 4 KB pipe buffer to fill sees a status indicator that lags
    # reality by minutes.
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # The reader went away (the app quit, or `| head -5` closed the
        # pipe). Exit non-zero without a traceback so monitor_run's loop
        # sees it and stops cleanly instead of spinning against a dead fd.
        try:
            sys.stdout.close()
        except BrokenPipeError:
            pass
        sys.exit(1)
