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

# A broken sibling must not take the whole stream down: without the
# catalog we fall back to "Issue <id>" phrasing, which is worse prose
# but a live monitor.
try:
    from rules_catalog import RULES
except Exception:
    RULES = []

# Rule ID -> catalog title ("G2" -> "Router dropping packets"), so a
# rule-fired/rule-cleared summary speaks the same plain-English name the
# GUI's report card and `--rules-catalog` already use, rather than the bare
# rule ID a user has never seen. Built once at import time — RULES is a
# module-level constant, so this never changes within a process lifetime.
_RULE_TITLES: dict[str, str] = {r["id"]: r["title"] for r in RULES}


def _env(name: str) -> str | None:
    v = os.environ.get(f"NETDIAG_MON_{name}")
    if not v:
        return None
    # Foundation's JSONDecoder drops the whole line on a surrogate escape
    # (e.g. from a non-UTF-8 SSID) — a mojibake character beats a dropped
    # sample.
    return v.encode("utf-8", "replace").decode("utf-8")


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
    raw = _env("TCP_LINES") or ""
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


def _changes() -> list[dict]:
    """Field-level diff against the previous sample (NETDIAG_MON_PREV_*).

    None on either side means "not measured" on that side, and an
    unmeasured→measured transition is not a change — same convention as
    the rest of the stream, where null is absence of measurement.
    Rules are the exception: they are always evaluated, so set
    difference is safe. Summaries are user-facing prose; the GUI
    renders them verbatim (CLAUDE.md: no verdict strings in Swift).

    Invariant this relies on: a field whose null suppresses the diff
    must keep its last known value in the previous-sample snapshot
    (bash side) — otherwise a single link-down sample with empty
    values erases the comparison baseline and interface/SSID changes
    are never reported.
    """
    if _env("HAVE_PREV") != "1":
        return []
    out: list[dict] = []

    def diff(now_key, prev_key, cid, field, phrase):
        now, prev = _env(now_key), _env(prev_key)
        if now is None or prev is None or now == prev:
            return
        out.append({"id": cid, "field": field, "from": prev, "to": now,
                    "summary": phrase(prev, now)})

    vpn_now = _env("VPN_ACTIVE") == "1"
    vpn_prev_raw = _env("PREV_VPN_ACTIVE")
    vpn_prev = vpn_prev_raw == "1"
    if vpn_prev_raw is not None and vpn_now != vpn_prev:
        name = _env("VPN_NAME") or _env("PREV_VPN_NAME")
        suffix = f" ({name})" if name else ""
        out.append({
            "id": "vpn-connected" if vpn_now else "vpn-disconnected",
            "field": "vpn.active",
            "from": "1" if vpn_prev else "0",
            "to": "1" if vpn_now else "0",
            "summary": (f"VPN connected{suffix}" if vpn_now
                        else f"VPN disconnected{suffix}"),
        })
    elif vpn_now and _env("VPN_TYPE") != "utun-route":
        # lib/monitor.sh sets MON_VPN_NAME to the tunnel interface
        # (utun4, utun6, ...) for utun-route VPNs — that's not a name,
        # and it duplicates interface-changed below.
        diff("VPN_NAME", "PREV_VPN_NAME", "vpn-name-changed", "vpn.name",
             lambda a, b: f"VPN changed: {a} → {b}")

    def exit_phrase(a, b):
        if vpn_now and vpn_prev:
            return f"VPN exit moved: {a} → {b}"
        if vpn_now and not vpn_prev:
            # Just connected: "a" was the user's real location, not a
            # prior VPN exit, so don't imply the exit itself moved.
            return f"VPN exit is in {b}"
        return f"Location changed: {a} → {b}"

    diff("PUB_CC", "PREV_PUB_CC", "country-changed", "public.country",
         exit_phrase)
    diff("PUB_IP", "PREV_PUB_IP", "public-ip-changed", "public.ip",
         lambda a, b: "Public IP changed")
    diff("PUB_ISP", "PREV_PUB_ISP", "isp-changed", "public.isp",
         lambda a, b: f"Internet provider changed: {a} → {b}")
    diff("SSID", "PREV_SSID", "wifi-network-changed", "link.ssid",
         lambda a, b: f"Wi-Fi network changed: {a} → {b}")
    if _env("SSID") is not None and _env("SSID") == _env("PREV_SSID"):
        diff("BSSID", "PREV_BSSID", "wifi-roamed", "link.bssid",
             lambda a, b: "Roamed to a different Wi-Fi access point")
    diff("INTERFACE", "PREV_INTERFACE", "interface-changed",
         "link.interface",
         lambda a, b: f"Network interface changed: {a} → {b}")

    rules_now = set((_env("RULES") or "").split())
    rules_prev = set((_env("PREV_RULES") or "").split())
    for rid in sorted(rules_now - rules_prev):
        out.append({"id": "rule-fired", "field": "status.rules",
                    "from": None, "to": rid,
                    "summary": _RULE_TITLES.get(rid, f"Issue {rid} detected")})
    for rid in sorted(rules_prev - rules_now):
        title = _RULE_TITLES.get(rid)
        out.append({"id": "rule-cleared", "field": "status.rules",
                    "from": rid, "to": None,
                    "summary": (f"Resolved: {title}" if title
                                else f"Issue {rid} cleared")})
    return out


def main() -> None:
    is_wifi = _env("IFACE_TYPE") == "wifi"
    link_up = os.environ.get("NETDIAG_MON_LINK_UP") == "1"
    rules = (_env("RULES") or "").split()

    sample = {
        # Fallback exists only for standalone/test invocation; it must
        # track NETDIAG_MON_SCHEMA in lib/monitor.sh.
        "schema": _i("SCHEMA") or 2,
        "version": _env("VERSION"),
        "ts": _env("TS"),
        "seq": _i("SEQ") or 0,
        # Which tiers actually refreshed this cycle. Everything outside
        # this list is carried over from an earlier sample, which a
        # consumer plotting a series needs to know before it draws a point.
        "refreshed": (_env("REFRESHED") or "").split(),
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
        "internet": {
            "loss_pct": _f("INET_LOSS"),
            "rtt_avg_ms": _f("INET_RTT"),
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
            # Paused by SIGUSR1 — probing is suspended, so every
            # measurement in this sample is stale by definition. A
            # consumer must not plot it or alert on it.
            "paused": os.environ.get("NETDIAG_MON_PAUSED") == "1",
            "cadence_s": _i("CADENCE_S"),
        },
    }

    changes = _changes()
    if changes:
        sample["changes"] = changes

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
