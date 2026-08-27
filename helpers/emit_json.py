#!/usr/bin/env python3
"""Emit netdiag run state as a schema-conformant JSON object on stdout.

Called from bin/netdiag with the run's collected globals exported as
environment variables (NETDIAG_* prefix). Fields that weren't set
become JSON null.

Top-level keys follow the order specified in docs/JSON-SCHEMA.md:
  version, timestamp, run_mode, run_id, interface, wifi, gateway, public,
  dns, traceroute, per_hop, bufferbloat, mtu, ipv6, vpn, tcp_reach,
  wifi_scan, wifi_disconnects, speedtest, ntp, duplicate_ips, dhcp, mtr,
  wan, baseline, diagnosis, most_likely_root_cause, netdiag_extras

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


def _is_set(name: str) -> bool:
    """True iff NETDIAG_<name> is present in the environment at all,
    including present-but-empty — the case _env() folds to None. Distinct
    from `_env(name) is not None`: this answers "did the caller set this
    var", not "did it carry a value". Owns the "NETDIAG_" prefix the same
    way _env() does, so a presence check never has to hardcode it again.
    """
    return f"NETDIAG_{name}" in os.environ


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
    """Parse 'n|ip|rtt_ms' (traceroute) or 'n|ip|loss|avg' (per_hop) lines.

    `n` is the real hop number from traceroute/mtr, so the sequence can have
    gaps in `ip`: a hop that never answered is emitted with an empty address
    and surfaces here as ip=null, responded=false. Consumers walking the
    path must not assume hop N is at index N-1, nor that every entry has an
    address. mtr spells the same condition "???".
    """
    out: list[dict] = []
    for line in _list_lines(env_name):
        parts = line.split("|")
        if len(parts) < 2:
            continue
        n = int(parts[0]) if parts[0].isdigit() else parts[0]
        ip = parts[1] if parts[1] and parts[1] != "???" else None
        entry: dict = {"n": n, "ip": ip, "responded": ip is not None}
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


VALID_SEVERITIES = ("critical", "warn", "info")


def build_diagnosis() -> list[dict]:
    """NETDIAG_DIAGNOSIS_LINES is one 'severity|rule|summary' per line.

    `rule` names the entry in docs/DIAGNOSIS-RULES.md that fired, so JSON
    consumers can group or filter by rule instead of string-matching prose
    that is deliberately rewritten for readability.

    Records written by netdiag < 0.5 have no rule field. Those parse as
    'severity|summary'; detect that by checking whether the first field is
    a known severity and the second looks like a rule ID rather than a
    sentence.
    """
    out: list[dict] = []
    for line in _list_lines("DIAGNOSIS_LINES"):
        parts = line.split("|", 2)
        if len(parts) == 3 and parts[0] in VALID_SEVERITIES:
            sev, rule, summary = parts
        elif len(parts) >= 2 and parts[0] in VALID_SEVERITIES:
            # Legacy two-field form: severity|summary, no rule recorded.
            sev, rule, summary = parts[0], None, "|".join(parts[1:])
        else:
            sev, rule, summary = "warn", None, line
        out.append({"severity": sev, "rule": rule, "summary": summary})
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
        "network_id": parsed.get("network_id"),
        "skipped_other_networks": parsed.get("skipped_other_networks", 0),
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


def build_timings() -> dict:
    """Per-phase wall-clock, plus the spec budget this run was measured against.

    `over_budget` is the checkable form of the spec's "<= 30 s full run,
    <= 8 s --quick" promise — previously asserted but never measured.
    """
    phases: dict[str, float] = {}
    for line in _list_lines("TIMING_LINES"):
        name, _, secs = line.partition("|")
        try:
            phases[name] = float(secs)
        except ValueError:
            continue
    total = _maybe_float("RUN_ELAPSED_S")
    budget = 8.0 if _bool("QUICK") else 30.0
    return {
        "total_s": total,
        "budget_s": budget,
        "over_budget": (total is not None and total > budget),
        "phases": phases,
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


REDACTED = "[redacted]"

# Values that identify a person or a place. ASN and ISP are kept: they
# name a provider, which is needed to reason about the fault. Country code
# is kept (2 chars — too short to substring-replace safely). RFC1918
# addresses are kept: a 192.168.x.y tells a reader nothing about who you
# are, and blanking them would gut the NAT and ARP sections.
#
# NETWORK_ID / NETWORK_LABEL are deliberately absent: they're composites of
# values already in this list ("wifi:ssid=Home,mac=aa:bb:…"), so the parts
# that identify anything get masked anyway, leaving the readable structure
# intact. Listing them here would instead make generic placeholders like
# "unknown network" into secrets and blank them wherever they appeared.
#
# IPV6_GATEWAY is included despite being link-local and unroutable: a
# fe80:: address is EUI-64-derived from the router's MAC, so leaving it in
# republishes the GW_MAC sitting next to it in this same tuple.
_REDACT_ENV = ("PUB_IP", "LOCAL_IP", "WIFI_SSID", "WIFI_BSSID",
               "IPV6_GLOBAL_ADDR", "IPV6_GATEWAY", "GW_MAC", "PUB_CITY")


def _scrub(node, secrets: list[str]):
    """Replace every secret substring anywhere in the structure.

    Field-by-field nulling isn't enough on its own: diagnosis summaries and
    the baseline's regression descriptions interpolate these values into
    prose, so the same string has to be caught wherever it ended up.
    """
    if isinstance(node, dict):
        return {k: _scrub(v, secrets) for k, v in node.items()}
    if isinstance(node, list):
        return [_scrub(v, secrets) for v in node]
    if isinstance(node, str):
        for s in secrets:
            node = node.replace(s, REDACTED)
        return node
    return node


def redact(data: dict) -> dict:
    # Substrings shorter than 3 chars are skipped — replacing them would
    # corrupt unrelated text rather than protect anything.
    secrets = sorted(
        {v for name in _REDACT_ENV if (v := _env(name)) and len(v) >= 3},
        key=len, reverse=True,   # longest first: mask the SSID before a
    )                            # shorter value that happens to be inside it
    return _scrub(data, secrets)


def main() -> None:
    is_wifi = _bool("IS_WIFI")
    target = _env("TARGET")

    data: dict = {
        # The CLI always supplies VERSION. A direct helper invocation should
        # expose missing metadata as null rather than inventing an old
        # version that looks like a real record.
        "version": _env("VERSION"),
        "timestamp": _env("TIMESTAMP"),
        # How much of the battery this run actually attempted. Null only
        # when this helper is invoked by hand — bin/netdiag always sets it.
        # Without it a --quick run and a full one are the same record, and
        # a --speed-only spot check counted toward a network's check total
        # while having formed no opinion about the network at all.
        "run_mode": _env("RUN_MODE"),
        # The id `netdiag --history` will hand back for this same run once
        # it lands in baseline.jsonl: "<timestamp>.<8 hex>", computed in
        # lib/output.sh by importing helpers/history.py's own canonical()
        # and run_id() rather than reimplementing them, so this value and
        # the one --history derives later can never disagree.
        #
        # null whenever lib/output.sh did not append a record this run —
        # --no-baseline and focused modes other than --speed-only
        # (--speed-only does append, per v0.9.0) — and also, unconditionally,
        # under --redact: see
        # redact() below for why that second case isn't left to the
        # ordinary secret-scrub.
        #
        # Dropped from the dict entirely (see below main()) rather than
        # left null when NETDIAG_RUN_ID was never set at all — the build
        # that becomes the appended baseline.jsonl record never sets it,
        # deliberately, so this key can never be part of the bytes
        # history.py hashes to produce the very id it would carry.
        "run_id": _env("RUN_ID"),
        "interface": {
            "name": _env("INTERFACE"),
            "ip": _env("LOCAL_IP"),
            "gateway": _env("GATEWAY"),
            "gateway_mac": _env("GW_MAC"),
            "type": "wifi" if is_wifi else "wired",
            # Association state, deliberately separate from `gateway`
            # above. `gateway` answers "is there a default route"; these
            # answer "is this Mac joined to anything", and conflating the
            # two is what made N1 tell users on hotel WiFi that their WiFi
            # was off. See lib/linkstate.sh and DIAGNOSIS-RULES.md#n1c.
            "link_status": _env("LINK_STATUS"),
            "link_up": os.environ.get("NETDIAG_LINK_UP", "") == "1",
            # True when the only IPv4 address on the link is a 169.254
            # one macOS assigned itself because no DHCP server answered.
            # A third state, not a flavour of link_up: `ip` is populated
            # and `link_up` is false, which without this flag reads as a
            # contradiction rather than as the DHCP failure it is. [DH-3]
            "self_assigned_ip": os.environ.get(
                "NETDIAG_LINK_SELF_ASSIGNED", "") == "1",
            # The router the DHCP server offered, present whether or not
            # the kernel installed a route to it — so on a network that
            # withholds a route there is still an address to point a
            # browser at.
            "dhcp_router": _env("LINK_DHCP_ROUTER"),
        },
        # Scopes baseline history. Two runs are only comparable when their
        # network.id matches — see helpers/baseline.py and lib/netid.sh.
        "network": {
            "id": _env("NETWORK_ID"),
            "label": _env("NETWORK_LABEL"),
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
            "target": _env("INET_TARGET") or "1.1.1.1",
            "rtt_avg_ms": _maybe_float("INET_RTT_AVG"),
            "rtt_jitter_ms": _maybe_float("INET_RTT_JITTER"),
            "loss_pct": _maybe_float("INET_LOSS"),
            # Second independent anycast target. L1 escalates packet loss
            # to critical only when both agree, so a consumer reproducing
            # the diagnosis needs both numbers, not just the primary.
            "target_alt": _env("INET_TARGET_ALT") or "8.8.8.8",
            "rtt_avg_ms_alt": _maybe_float("INET_RTT_AVG_ALT"),
            "loss_pct_alt": _maybe_float("INET_LOSS_ALT"),
        },
        "public": {
            "ip": _env("PUB_IP"),
            "asn": _env("PUB_ASN"),
            "isp": _env("PUB_ISP"),
            "city": _env("PUB_CITY"),
            "country": _env("PUB_CC"),
            # ISO-3166 alpha-2. Distinct from `country`, which is the full
            # name: a consumer rendering a flag or picking a locale needs
            # the code, and deriving it would mean shipping a country
            # table in every consumer.
            "country_iso": _env("PUB_CC_ISO"),
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
        "timings": build_timings(),
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
    if _bool("REDACT"):
        data = redact(data)
        # run_id is a pointer into the *private* copy of this run that
        # lib/output.sh always writes to baseline.jsonl, redacted or not —
        # see build_json_private there. _scrub has nothing to catch it
        # with (it isn't built from any _REDACT_ENV value), so it is
        # nulled explicitly: a report built to leave the machine should
        # not carry a working key back into data it otherwise took pains
        # to mask, even though that data lives only on this machine.
        data["run_id"] = None

    if not _is_set("RUN_ID"):
        # Dropped, not left null. The build that becomes the appended
        # baseline.jsonl record (lib/output.sh's build_json_private) never
        # sets this var — see its own HISTORY_APPEND block — precisely so
        # this key cannot exist in that build's output at all: a key that
        # carries a run's id cannot also sit inside the bytes history.py
        # hashes to produce that same id. Checked last, after the REDACT
        # branch above, so it wins even if some future caller set REDACT
        # without also setting NETDIAG_RUN_ID.
        del data["run_id"]

    json.dump(data, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
