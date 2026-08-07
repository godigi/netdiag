#!/usr/bin/env python3
"""Emit netdiag run state as a schema-conformant JSON object on stdout.

Called from bin/netdiag with the run's collected globals exported as
environment variables (NETDIAG_* prefix). Fields that weren't set
become JSON null.

Top-level keys follow the order specified in netdiag-prompt.md:
  version, timestamp, interface, wifi, gateway, public, dns, traceroute,
  per_hop, bufferbloat, mtu, ipv6, vpn, tcp_reach, wifi_scan,
  wifi_disconnects, speedtest, ntp, duplicate_ips, dhcp, mtr, wan,
  baseline, diagnosis, most_likely_root_cause, netdiag_extras

`wan` (v0.3+) covers NAT / WAN topology — dual-WAN load balancing,
double-NAT detection, UPnP/NAT-PMP status. Sub-keys: load_balancing,
double_nat, upnp.
"""

from __future__ import annotations

import json
import os
import sys


def _env(name: str) -> str | None:
    v = os.environ.get(f"NETDIAG_{name}")
    return v if v else None


def _maybe_float(name: str) -> float | None:
    v = _env(name)
    if v is None:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def _maybe_int(name: str) -> int | None:
    v = _env(name)
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def _bool(name: str) -> bool:
    return _env(name) == "1"


def _arrow_list(name: str) -> list[str]:
    """Split an ' → '-joined chain into a list. Empty input yields [], not ['']."""
    raw = _env(name)
    return raw.split(" → ") if raw else []


def _list_lines(name: str) -> list[str]:
    raw = os.environ.get(f"NETDIAG_{name}", "")
    return [line for line in raw.splitlines() if line.strip()]


def build_tcp_reach() -> list[dict]:
    out = []
    for line in _list_lines("TCP_REACH_LINES"):
        parts = line.split("|")
        if len(parts) < 2:
            continue
        host_port, status = parts[0], parts[1]
        host, _, port = host_port.partition(":")
        entry = {"host": host, "port": int(port) if port.isdigit() else port, "ok": status == "OK"}
        if status == "OK" and len(parts) > 2:
            try:
                entry["elapsed_ms"] = float(parts[2])
            except ValueError:
                pass
        out.append(entry)
    return out


def build_dns() -> list[dict]:
    out: list[dict] = []
    for line in _list_lines("DNS_LINES"):
        parts = line.split("|")
        if len(parts) < 4:
            continue
        out.append({
            "resolver": parts[0],
            "name": parts[1],
            "answer": parts[2] or None,
            "ok": parts[3] == "OK",
        })
    return out


def build_hops(env_name: str) -> list[dict]:
    """Parse 'n|ip|rtt_ms' (traceroute) or 'n|ip|loss|avg' (per_hop) lines."""
    out: list[dict] = []
    for line in _list_lines(env_name):
        parts = line.split("|")
        if len(parts) < 2:
            continue
        n = int(parts[0]) if parts[0].isdigit() else parts[0]
        entry: dict = {"n": n, "ip": parts[1]}
        if env_name == "PER_HOP_LINES" and len(parts) >= 4:
            try:
                entry["loss_pct"] = float(parts[2]) if parts[2] else None
            except ValueError:
                entry["loss_pct"] = None
            try:
                entry["avg_ms"] = float(parts[3]) if parts[3] else None
            except ValueError:
                entry["avg_ms"] = None
        elif len(parts) >= 3:
            try:
                entry["rtt_ms"] = float(parts[2]) if parts[2] else None
            except ValueError:
                entry["rtt_ms"] = None
        out.append(entry)
    return out


def build_diagnosis() -> list[dict]:
    """NETDIAG_DIAGNOSIS_LINES is one 'severity|summary' per line."""
    out: list[dict] = []
    for line in _list_lines("DIAGNOSIS_LINES"):
        sev, _, summary = line.partition("|")
        if not summary:
            summary, sev = sev, "warn"
        out.append({"severity": sev, "summary": summary})
    return out


def build_baseline() -> dict | None:
    raw = os.environ.get("NETDIAG_BASELINE_JSON", "")
    if not raw.strip():
        return None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return {
        "compared_runs": parsed.get("compared_runs", 0),
        "regressions": parsed.get("regressions", []),
    }


def build_mtr() -> dict:
    """MTR ran iff PER_HOP_LINES has entries. duration_s is the nominal value
    for `mtr -r -c 60 -i 0.2` (12 s); the fallback per-hop loop is roughly
    1-2 s after parallelisation."""
    per_hop = build_hops("PER_HOP_LINES")
    return {
        "target": "1.1.1.1",
        "duration_s": 12 if per_hop else None,
        "hops": per_hop,
        "first_lossy_hop": _env("MTR_FIRST_LOSSY_HOP"),
    }


def build_wan() -> dict:
    """NAT / WAN topology section (v0.3+). All three sub-objects are present
    even when the underlying probe was skipped — fields are nullable instead.
    """
    lb_asns = (_env("WAN_LB_ASNS") or "").split()
    lb_ips = (_env("WAN_LB_IPS") or "").split()
    double_nat_chain = (_env("WAN_DOUBLE_NAT_CHAIN") or "").split()
    return {
        "load_balancing": {
            "distinct_asns": lb_asns,
            "distinct_ips": lb_ips,
            "active": _bool("WAN_LB_ACTIVE"),
        },
        # `detected` counts home-side routers only. ISP-side 10/8 transit is
        # normal carrier routing and is reported separately so consumers can
        # tell "you chained two routers" from "your ISP uses private transit".
        "double_nat": {
            "detected": _bool("WAN_DOUBLE_NAT"),
            "rfc1918_chain": double_nat_chain,
            "home_chain": _arrow_list("WAN_NAT_HOME_CHAIN"),
            "home_count": _maybe_int("WAN_NAT_HOME_COUNT") or 0,
            "isp_transit_chain": _arrow_list("WAN_NAT_ISP_CHAIN"),
            "isp_transit_count": _maybe_int("WAN_NAT_ISP_COUNT") or 0,
        },
        "upnp": {
            "state": _env("WAN_UPNP_STATE"),
            "device": _env("WAN_UPNP_DEVICE"),
            "url": _env("WAN_UPNP_URL"),
            "tested_via": _env("WAN_UPNP_TESTED_VIA"),
        },
    }


def main() -> None:
    is_wifi = _bool("IS_WIFI")
    target = _env("TARGET")

    data: dict = {
        "version": _env("VERSION") or "0.4.1",
        "timestamp": _env("TIMESTAMP"),
        "interface": {
            "name": _env("INTERFACE"),
            "ip": _env("LOCAL_IP"),
            "gateway": _env("GATEWAY"),
            "type": "wifi" if is_wifi else "wired",
        },
        "wifi": ({
            "ssid": _env("WIFI_SSID"),
            "bssid": _env("WIFI_BSSID"),
            "security": _env("WIFI_SEC"),
            "rssi": _maybe_int("WIFI_RSSI"),
            "noise": _maybe_int("WIFI_NOISE"),
            "snr": _maybe_int("WIFI_SNR"),
            "channel": _env("WIFI_CHAN"),
            "phy": _env("WIFI_PHY"),
            "tx_rate": _env("WIFI_TX"),
        } if is_wifi else None),
        "gateway": {
            "ip": _env("GATEWAY"),
            "loss_pct": _maybe_float("GW_LOSS"),
            "rtt_avg_ms": _maybe_float("GW_LATENCY"),
            "rtt_jitter_ms": _maybe_float("GW_JITTER"),
        },
        "internet_latency": {
            "target": "1.1.1.1",
            "rtt_avg_ms": _maybe_float("INET_RTT_AVG"),
            "rtt_jitter_ms": _maybe_float("INET_RTT_JITTER"),
            "loss_pct": _maybe_float("INET_LOSS"),
        },
        "public": {
            "ip": _env("PUB_IP"),
            "asn": _env("PUB_ASN"),
            "isp": _env("PUB_ISP"),
            "city": _env("PUB_CITY"),
            "country": _env("PUB_CC"),
            "captive_portal": _bool("CAPTIVE_PORTAL"),
        },
        "dns": build_dns(),
        "traceroute": {
            "target": "1.1.1.1",
            "hops": build_hops("TRACE_LINES"),
        },
        "per_hop": build_hops("PER_HOP_LINES"),
        "bufferbloat": {
            "idle_gw_rtt_ms": _maybe_float("BUFFERBLOAT_IDLE_GW_RTT"),
            "loaded_gw_rtt_ms": _maybe_float("BUFFERBLOAT_LOADED_GW_RTT"),
            "idle_inet_rtt_ms": _maybe_float("BUFFERBLOAT_IDLE_INET_RTT"),
            "loaded_inet_rtt_ms": _maybe_float("BUFFERBLOAT_LOADED_INET_RTT"),
            "gw_delta_ms": _maybe_float("BUFFERBLOAT_GW_DELTA"),
            "inet_delta_ms": _maybe_float("BUFFERBLOAT_INET_DELTA"),
            "gw_grade": _env("BUFFERBLOAT_GW_GRADE"),
            "inet_grade": _env("BUFFERBLOAT_INET_GRADE"),
        },
        "mtu": {
            "effective": _maybe_int("MTU_EFFECTIVE"),
            "path_size": _maybe_int("MTU_PATH_SIZE"),
        },
        "ipv6": {
            "available": _bool("IPV6_AVAILABLE"),
            "global_addr": _env("IPV6_GLOBAL_ADDR"),
            "gateway": _env("IPV6_GATEWAY"),
            "ping_loss_pct": _maybe_float("IPV6_PING_LOSS"),
            "aaaa_ok": _bool("IPV6_AAAA_OK"),
            "trace_hops": _maybe_int("IPV6_TRACE_HOPS"),
            "tcp_v6_ok": _bool("IPV6_TCP_OK"),
        },
        "vpn": {
            "active": _bool("VPN_ACTIVE"),
            "type": _env("VPN_TYPE"),
            "name": _env("VPN_NAME"),
        },
        "tcp_reach": build_tcp_reach(),
        "wifi_scan": ({
            "current_channel": _env("WIFI_SCAN_CURRENT_CHANNEL"),
            "current_band": _env("WIFI_SCAN_CURRENT_BAND"),
            "neighbour_count": _maybe_int("WIFI_SCAN_NEIGHBOR_COUNT"),
            "current_channel_neighbours": _maybe_int("WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS"),
        } if is_wifi else None),
        "wifi_disconnects": ({
            "window_hours": _maybe_int("WIFI_DISCONNECT_WINDOW_HOURS"),
            "count": _maybe_int("WIFI_DISCONNECT_COUNT"),
        } if is_wifi else None),
        "speedtest": ({
            "down_mbps": _maybe_float("SPEEDTEST_DOWN_MBPS"),
            "up_mbps": _maybe_float("SPEEDTEST_UP_MBPS"),
            "latency_ms": _maybe_float("SPEEDTEST_LATENCY_MS"),
            "jitter_ms": _maybe_float("SPEEDTEST_JITTER_MS"),
            "server": _env("SPEEDTEST_SERVER"),
        } if _env("SPEEDTEST_DOWN_MBPS") else None),
        "ntp": {
            "drift_seconds": _maybe_float("NTP_DRIFT_S"),
            "using_network_time": _env("NTP_USING_NETWORK_TIME"),
            "server": _env("NTP_SERVER"),
        },
        "duplicate_ips": (_env("ARP_DUPLICATE_IPS").split()
                          if _env("ARP_DUPLICATE_IPS") else []),
        "dhcp": {
            "server": _env("DHCP_SERVER"),
            "lease_start": _env("DHCP_LEASE_START"),
            "lease_end": _env("DHCP_LEASE_END"),
            "time_remaining_s": _maybe_int("DHCP_TIME_REMAINING_S"),
            "dns_servers": _env("DHCP_DNS_SERVERS"),
        },
        "mtr": build_mtr(),
        "wan": build_wan(),
        "hosts_file": {
            "custom_count": _maybe_int("HOSTS_CUSTOM_COUNT"),
            "suspicious_redirects": [
                line.strip() for line in
                (os.environ.get("NETDIAG_HOSTS_SUSPICIOUS_LINES", "") or "").splitlines()
                if line.strip()
            ],
        },
        "baseline": build_baseline(),
        "diagnosis": build_diagnosis(),
        "most_likely_root_cause": _env("MOST_LIKELY_ROOT_CAUSE"),
        "netdiag_extras": {
            "arp_gw_incomplete": _bool("ARP_GW_INCOMPLETE"),
            "target": target,
            "target_ping": ({
                "loss_pct": _maybe_float("TARGET_PING_LOSS"),
                "rtt_avg_ms": _maybe_float("TARGET_PING_RTT"),
            } if target else None),
            "target_traceroute": ({
                "target": target,
                "hops": build_hops("TARGET_TRACE_LINES"),
            } if target else None),
        },
    }
    json.dump(data, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
