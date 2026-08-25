#!/usr/bin/env python3
"""Render one stored netdiag run as pasteable, redacted plain text.

Why this exists instead of a flag on --redact
──────────────────────────────────────────────
The app's only copy affordance (gui/.../Views/ExpertPanel.swift:246) copies
a run's raw JSON, unredacted: the machine's public IPv4 and IPv6
addresses, SSID, BSSID, gateway MAC and city all ride along in it. The
obvious fix — reuse --redact against a stored run — does not work, because
of two deliberate design decisions elsewhere in this codebase:

  1. lib/output.sh:160-163 saves REDACT, forces it to 0 to build the
     record appended to history, then restores it. The log and the
     history store always hold full detail; only stdout and --json are
     ever masked, and only for the run currently in progress.
  2. helpers/history.py:355 (is_redacted, :281) drops any record that
     *was* written under --redact from the store entirely, because a
     masked record's network.id is the literal string
     "wifi:mac=[redacted]" — shared with every other redacted run on
     every other network — and grouping on it would invent a network
     that never existed.

So there is no redacted stored copy to read, and there never will be:
redaction of a stored run has to happen at read time, against whatever
JSON `netdiag --show` hands back. That is what this file does.

The redactor below mirrors emit_json.py's _REDACT_ENV / _scrub / redact
(see helpers/emit_json.py:258-305) field for field, but pulls its secrets
out of the record itself rather than out of the process environment —
there is no live run here to source NETDIAG_* vars from, only a JSON
object read from stdin or a file.
"""

from __future__ import annotations

import argparse
import json
import sys
import textwrap

REDACTED = "[redacted]"

# Mirrors emit_json.py's _REDACT_ENV exactly, one record path per name.
# ASN/ISP and country/country_iso are deliberately absent: ISP and ASN
# name a provider, which is what a reader needs to act on the report, and
# a 2-letter country code is too short to substring-replace safely (see
# the minimum-length guard in secrets_in below). RFC1918 addresses are
# also deliberately absent: a 192.168.x.y identifies nobody, and blanking
# it would gut the router/NAT rows. network.id and network.label are
# deliberately absent too — they are composites of values already listed
# here ("wifi:ssid=Home,mac=aa:bb:…"), so the parts that identify anything
# are masked anyway when the substring scrub runs, leaving the readable
# structure ("wifi:ssid=[redacted],mac=[redacted]") intact.
_REDACT_PATHS = (
    "public.ip",
    "interface.ip",
    "wifi.ssid",
    "wifi.bssid",
    "ipv6.global_addr",
    # A fe80:: address is EUI-64-derived from the router's MAC, so leaving
    # it in would republish interface.gateway_mac sitting next to it.
    "ipv6.gateway",
    "interface.gateway_mac",
    "public.city",
)


def get_nested(d, path: str):
    """Walk a dotted path through nested dicts; None on any missing hop."""
    cur = d
    for k in path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def secrets_in(record: dict) -> list[str]:
    """The identifying substrings to scrub out of `record`, longest first.

    Longest-first matters the same way it does in emit_json.py: an SSID
    has to be masked before a shorter value that happens to sit inside it
    (e.g. an SSID that contains a street number that also appears alone
    elsewhere), or the shorter replacement would run first and leave a
    fragment of the longer secret exposed.

    Values shorter than 3 characters are dropped rather than scrubbed —
    replacing a 1- or 2-character string would corrupt unrelated text
    (English prose is full of 2-letter words) rather than protect anything.
    """
    found: set[str] = set()
    for path in _REDACT_PATHS:
        v = get_nested(record, path)
        if isinstance(v, str) and len(v) >= 3:
            found.add(v)
    return sorted(found, key=len, reverse=True)


def scrub(node, secrets: list[str]):
    """Replace every secret substring anywhere in `node`, recursively.

    Field-by-field nulling is not enough on its own: diagnosis summaries
    interpolate these values into prose ("Your WiFi channel is crowded on
    MyHouse at 203.0.113.77."), so the same string has to be caught
    wherever it landed, not just in the field it was copied out of.
    """
    if isinstance(node, dict):
        return {k: scrub(v, secrets) for k, v in node.items()}
    if isinstance(node, list):
        return [scrub(v, secrets) for v in node]
    if isinstance(node, str):
        for s in secrets:
            node = node.replace(s, REDACTED)
        return node
    return node


def redact(record: dict) -> dict:
    return scrub(record, secrets_in(record))


_NOT_MEASURED = "not measured"

# × for critical, ⚠ for warn. Anything else (currently only "info") gets a
# plain dash — this file renders whatever severities diagnosis.sh emits, it
# doesn't decide which severities exist.
_SEVERITY_MARKS = {"critical": "×", "warn": "⚠"}

_WRAP_WIDTH = 78


def _fmt_ms(v) -> str:
    if not isinstance(v, (int, float)):
        return _NOT_MEASURED
    return f"{v:g} ms"


def _latency_line(record: dict, prefix: str) -> str:
    """rtt_avg_ms for `prefix` (e.g. "gateway", "internet_latency"), with
    loss_pct appended only when it is present *and* non-zero — a healthy
    link's 0% loss is not information a reader needs restated on every
    line, and an absent measurement must read as "not measured", never as
    silently-zero loss."""
    rtt = get_nested(record, f"{prefix}.rtt_avg_ms")
    loss = get_nested(record, f"{prefix}.loss_pct")
    line = _fmt_ms(rtt)
    if isinstance(loss, (int, float)) and loss != 0:
        line += f", {loss:g}% loss"
    return line


def _router_row(record: dict) -> str:
    # The gateway's own IP rides along here. It is RFC1918 and identifies
    # nobody, so it is one of the values the scrub deliberately leaves in
    # place (see _REDACT_PATHS above) — a reader troubleshooting "is it my
    # router or my ISP" needs to see which address the router row is about.
    ip = get_nested(record, "gateway.ip")
    latency = _latency_line(record, "gateway")
    return f"{ip} — {latency}" if ip else latency


def _provider_row(record: dict):
    """None when both fields are absent, so the caller can omit the row
    entirely rather than print a line of nothing but "not measured" —
    unlike every other row, there is no fallback text for a provider."""
    isp = get_nested(record, "public.isp")
    country = get_nested(record, "public.country")
    bits = [b for b in (isp, country) if isinstance(b, str) and b]
    return " — ".join(bits) if bits else None


def _dns_row(record: dict) -> str:
    dns = record.get("dns")
    if not isinstance(dns, list) or not dns:
        return _NOT_MEASURED
    ok = sum(1 for d in dns if isinstance(d, dict) and d.get("ok"))
    return f"{ok}/{len(dns)} resolvers OK"


def _bufferbloat_row(record: dict) -> str:
    grade = get_nested(record, "bufferbloat.gw_grade")
    delta = get_nested(record, "bufferbloat.gw_delta_ms")
    if not grade and not isinstance(delta, (int, float)):
        return _NOT_MEASURED
    bits = [f"grade {grade}"] if grade else []
    if isinstance(delta, (int, float)):
        bits.append(f"{delta:+g} ms under load")
    return ", ".join(bits)


def _speed_row(record: dict) -> str:
    down = get_nested(record, "speedtest.down_mbps")
    up = get_nested(record, "speedtest.up_mbps")
    if not isinstance(down, (int, float)) and not isinstance(up, (int, float)):
        return _NOT_MEASURED
    d = f"{down:g}" if isinstance(down, (int, float)) else "?"
    u = f"{up:g}" if isinstance(up, (int, float)) else "?"
    return f"{d} Mbps down / {u} Mbps up"


def _clock_row(record: dict) -> str:
    drift = get_nested(record, "ntp.drift_seconds")
    if not isinstance(drift, (int, float)):
        return _NOT_MEASURED
    return f"{drift:+.2f} s off"


def _report_card(record: dict) -> list[str]:
    lines: list[str] = []

    def row(label: str, value: str) -> None:
        lines.append(f"  {label:<13}{value}")

    iface_name = get_nested(record, "interface.name")
    iface_type = get_nested(record, "interface.type")
    if iface_name or iface_type:
        row("Network", f"{iface_name or _NOT_MEASURED} ({iface_type or _NOT_MEASURED})")
    else:
        row("Network", _NOT_MEASURED)

    row("Router", _router_row(record))
    row("Internet", _latency_line(record, "internet_latency"))

    provider = _provider_row(record)
    if provider is not None:
        row("Provider", provider)

    row("Name lookups", _dns_row(record))

    if isinstance(record.get("wifi"), dict):
        rssi = get_nested(record, "wifi.rssi")
        row("Wi-Fi signal",
            f"{rssi} dBm" if isinstance(rssi, (int, float)) else _NOT_MEASURED)

    row("Under load", _bufferbloat_row(record))
    mtu = get_nested(record, "mtu.effective")
    row("Packet size", f"{mtu} bytes" if isinstance(mtu, (int, float)) else _NOT_MEASURED)
    row("Speed", _speed_row(record))
    row("Clock", _clock_row(record))

    return lines


def _findings(record: dict) -> list[str]:
    """Every diagnosis[].summary, verbatim. The CLI already writes these
    for a non-technical reader (see docs/DIAGNOSIS-RULES.md); rewording
    them here would be a second opinion from a file with no business
    having one."""
    diagnosis = record.get("diagnosis")
    if not isinstance(diagnosis, list) or not diagnosis:
        return ["Nothing obviously wrong — the network looked healthy."]

    lines: list[str] = []
    for d in diagnosis:
        if not isinstance(d, dict):
            continue
        mark = _SEVERITY_MARKS.get(d.get("severity"), "-")
        summary = d.get("summary") or ""
        rule = d.get("rule")
        suffix = f" [{rule}]" if rule else ""
        lines.append(textwrap.fill(f"{mark} {summary}{suffix}",
                                    width=_WRAP_WIDTH,
                                    subsequent_indent="  "))
    return lines or ["Nothing obviously wrong — the network looked healthy."]


def render(record: dict) -> str:
    """The compact Report card plus the CLI's own prose, and nothing else.

    No expert sections (traceroute, mtr, per-hop, tcp_reach, wan, ...) —
    that mirrors the rule bin/netdiag:483-488 already enforces for
    --redact: partially-redacted expert detail is worse than none, because
    it *looks* safe. Since redact() has already run by the time this is
    called, everything printed here is already scrubbed; this function
    only chooses which already-safe fields are worth a reader's time.

    No ANSI: the whole point is that this pastes cleanly into a support
    chat, a forum post, or an email.
    """
    ts = record.get("timestamp") or "unknown time"
    lines = [f"netdiag Report — {ts}", ""]
    lines.extend(_report_card(record))
    lines.append("")
    lines.append("── What we found ──")
    lines.extend(_findings(record))
    lines.append("")
    lines.append(
        "Identifying details (public IP, SSID, BSSID, gateway MAC, IPv6 "
        "address, city) have been masked. Generated by netdiag --share."
    )
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--file", type=str, default=None,
                     help="Read the run's JSON from PATH instead of stdin.")
    args = ap.parse_args()

    if args.file:
        try:
            with open(args.file, "r", encoding="utf-8") as f:
                raw = f.read()
        except OSError as e:
            print(f"netdiag-share: cannot read {args.file}: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        raw = sys.stdin.read()

    try:
        record = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"netdiag-share: input is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(record, dict):
        print("netdiag-share: input is not valid JSON: expected an object",
              file=sys.stderr)
        sys.exit(1)

    print(render(redact(record)))


if __name__ == "__main__":
    main()
