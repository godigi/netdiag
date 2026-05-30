#!/usr/bin/env python3
"""Emit netdiag run state as a schema-conformant JSON object on stdout.

Called from bin/netdiag with the run's collected globals exported as
environment variables (NETDIAG_* prefix). Fields that weren't set
become JSON null.

Schema matches netdiag-prompt.md section "JSON-output schema details".
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


def _list_lines(name: str) -> list[str]:
    raw = os.environ.get(f"NETDIAG_{name}", "")
    return [line for line in raw.splitlines() if line.strip()]


def build_tcp_reach() -> list[dict]:
    """NETDIAG_TCP_REACH_LINES contains one 'host:port|OK|ms' or 'host:port|FAIL' per line."""
    out = []
    for line in _list_lines("TCP_REACH_LINES"):
        parts = line.split("|")
        if len(parts) < 2:
            continue
        host_port = parts[0]
        status = parts[1]
        host, _, port = host_port.partition(":")
        entry = {"host": host, "port": int(port) if port.isdigit() else port, "ok": status == "OK"}
        if status == "OK" and len(parts) > 2:
            try:
                entry["elapsed_ms"] = float(parts[2])
            except ValueError:
                pass
        out.append(entry)
    return out


def build_diagnosis() -> list[dict]:
    """NETDIAG_DIAGNOSIS_LINES has one diagnosis string per line."""
    return [{"severity": "warn", "summary": line} for line in _list_lines("DIAGNOSIS_LINES")]


def main() -> None:
    data = {
        "version": _env("VERSION") or "0.2.0",
        "timestamp": _env("TIMESTAMP"),
        "interface": {
            "name": _env("INTERFACE"),
            "ip": _env("LOCAL_IP"),
            "gateway": _env("GATEWAY"),
            "type": "wifi" if _bool("IS_WIFI") else "wired",
        },
        "wifi": {
            "ssid": _env("WIFI_SSID"),
            "bssid": _env("WIFI_BSSID"),
            "security": _env("WIFI_SEC"),
            "rssi": _maybe_int("WIFI_RSSI"),
            "noise": _maybe_int("WIFI_NOISE"),
            "snr": _maybe_int("WIFI_SNR"),
            "channel": _env("WIFI_CHAN"),
            "phy": _env("WIFI_PHY"),
            "tx_rate": _env("WIFI_TX"),
        } if _bool("IS_WIFI") else None,
        "vpn": {
            "active": _bool("VPN_ACTIVE"),
            "type": _env("VPN_TYPE"),
            "name": _env("VPN_NAME"),
        },
        "gateway": {
            "ip": _env("GATEWAY"),
            "loss_pct": _maybe_float("GW_LOSS"),
            "rtt_avg_ms": _maybe_float("GW_LATENCY"),
        },
        "public": {
            "ip": _env("PUB_IP"),
            "asn": _env("PUB_ASN"),
            "isp": _env("PUB_ISP"),
            "city": _env("PUB_CITY"),
            "country": _env("PUB_CC"),
            "captive_portal": _bool("CAPTIVE_PORTAL"),
        },
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
        "dns": [
            {"resolver": parts[0], "name": parts[1], "answer": parts[2] if len(parts) > 2 else None,
             "ok": (parts[3] == "OK") if len(parts) > 3 else None}
            for parts in (line.split("|") for line in _list_lines("DNS_LINES"))
            if len(parts) >= 2
        ],
        "ipv6": {
            "available": _bool("IPV6_AVAILABLE"),
            "global_addr": _env("IPV6_GLOBAL_ADDR"),
            "gateway": _env("IPV6_GATEWAY"),
            "ping_loss_pct": _maybe_float("IPV6_PING_LOSS"),
            "aaaa_ok": _bool("IPV6_AAAA_OK"),
            "trace_hops": _maybe_int("IPV6_TRACE_HOPS"),
            "tcp_v6_ok": _bool("IPV6_TCP_OK"),
        },
        "tcp_reach": build_tcp_reach(),
        "wifi_scan": {
            "current_channel": _env("WIFI_SCAN_CURRENT_CHANNEL"),
            "current_band": _env("WIFI_SCAN_CURRENT_BAND"),
            "neighbour_count": _maybe_int("WIFI_SCAN_NEIGHBOR_COUNT"),
            "current_channel_neighbours": _maybe_int("WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS"),
        } if _bool("IS_WIFI") else None,
        "wifi_disconnects": {
            "window_hours": _maybe_int("WIFI_DISCONNECT_WINDOW_HOURS"),
            "count": _maybe_int("WIFI_DISCONNECT_COUNT"),
        } if _bool("IS_WIFI") else None,
        "speedtest": {
            "down_mbps": _maybe_float("SPEEDTEST_DOWN_MBPS"),
            "up_mbps": _maybe_float("SPEEDTEST_UP_MBPS"),
            "latency_ms": _maybe_float("SPEEDTEST_LATENCY_MS"),
            "jitter_ms": _maybe_float("SPEEDTEST_JITTER_MS"),
            "server": _env("SPEEDTEST_SERVER"),
        } if _env("SPEEDTEST_DOWN_MBPS") else None,
        "ntp": {
            "drift_seconds": _maybe_float("NTP_DRIFT_S"),
            "using_network_time": _env("NTP_USING_NETWORK_TIME"),
            "server": _env("NTP_SERVER"),
        },
        "dhcp": {
            "server": _env("DHCP_SERVER"),
            "lease_start": _env("DHCP_LEASE_START"),
            "lease_end": _env("DHCP_LEASE_END"),
            "time_remaining_s": _maybe_int("DHCP_TIME_REMAINING_S"),
            "dns_servers": _env("DHCP_DNS_SERVERS"),
        },
        "duplicate_ips": _env("ARP_DUPLICATE_IPS").split() if _env("ARP_DUPLICATE_IPS") else [],
        "arp_gw_incomplete": _bool("ARP_GW_INCOMPLETE"),
        "mtr": {
            "first_lossy_hop": _env("MTR_FIRST_LOSSY_HOP"),
        },
        "target": _env("TARGET"),
        "target_ping": {
            "loss_pct": _maybe_float("TARGET_PING_LOSS"),
            "rtt_avg_ms": _maybe_float("TARGET_PING_RTT"),
        } if _env("TARGET") else None,
        "diagnosis": build_diagnosis(),
    }
    json.dump(data, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
