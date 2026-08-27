# shellcheck shell=bash
# lib/globals.sh — initialise every cross-module variable the modules and
# helpers/emit_json.py expect to read.
#
# Keeping these declarations in one place makes the data flow auditable:
# search for a variable name and you'll find where it's written (one
# module's *_run function) and where it's read (diagnosis.sh, output.sh,
# emit_json.py, baseline.py, summary.py).
#
# Every variable in this file is read by at least one other module or
# helper; shellcheck can't follow the cross-file flow so blanket-disable
# the "unused" warning here.
# shellcheck disable=SC2034

# Interface / gateway (set by lib/iface.sh)
INTERFACE=""
LOCAL_IP=""
GATEWAY=""
GW_COUNT=0

# Link state (lib/linkstate.sh, consumed by lib/iface.sh) — deliberately
# separate from GATEWAY above, which means one specific thing: "the
# gateway of the default route". These say whether the Mac is joined to
# anything at all, which is a different question and the one N1 was
# answering wrong. See lib/linkstate.sh's header.
LINK_DEVICE=""           # active device, found without the routing table
LINK_STATUS=""           # ifconfig's own word: active | inactive | ""
LINK_IP=""               # IPv4 address on LINK_DEVICE
LINK_DHCP_ROUTER=""      # router the DHCP server offered, route or no route
LINK_UP=0                # 1 = active device holding a real address
LINK_SELF_ASSIGNED=0     # 1 = active, but the only address is 169.254 [DH-3]
LINK_MEDIA_MBPS=""       # negotiated wired rate, Mb/s; empty on WiFi [ETH-1]
LINK_MEDIA_MAX_MBPS=""   # top rate the port advertises, Mb/s [ETH-1]
LINK_DUPLEX=""           # full | half | "" [ETH-2]
LINK_MEDIA_FULL_DUPLEX_CAPABLE=0  # 1 = port advertises full duplex [ETH-2]
LINK_SERVICE=""          # macOS service name carrying the link [MET-1]
LINK_METERED=0           # 1 = tethered / hotspot; data costs money [MET-1]
LINK_METERED_CERTAIN=0   # 1 = macOS named it; 0 = inferred from subnet [MET-1]

# WiFi (lib/wifi.sh, lib/wifi_scan.sh, lib/wifi_disconnect.sh)
IS_WIFI=0
# The *_CHECKED flags separate "measured and negative" from "never ran".
# Focused runs (--mtu-only / --wifi-only) skip most modules, so without
# these a skipped check reads as a failed one — a WiFi link was reported
# as "wired" under --mtu-only purely because wifi_run had not executed.
WIFI_CHECKED=0
WIFI_SSID=""
WIFI_BSSID=""
WIFI_SEC=""
WIFI_RSSI=""
WIFI_NOISE=""
WIFI_SNR=""
WIFI_CHAN=""
WIFI_PHY=""
WIFI_TX=""
WIFI_SCAN_CURRENT_CHANNEL=""
WIFI_SCAN_CURRENT_BAND=""
WIFI_SCAN_NEIGHBOR_COUNT=0
WIFI_SCAN_CURRENT_CHANNEL_NEIGHBORS=0
WIFI_DISCONNECT_COUNT=0
WIFI_DISCONNECT_WINDOW_HOURS=1
WIFI_DISCONNECT_LINES=""  # condensed event lines, stored in the record
WIFI_PRIVILEGED=0        # 1 = the sudo-only radio fields were readable
WIFI_NAME_HIDDEN=0       # 1 = macOS withheld the SSID [WI-1]

# VPN (lib/vpn.sh)
VPN_ACTIVE=0
VPN_TYPE=""
VPN_NAME=""

# Gateway reachability (lib/gateway.sh)
GW_LOSS=""
GW_LATENCY=""
GW_JITTER=""           # stddev from ping summary, ms

# The packet-loss thresholds (LOSS_WARN_PCT, LOSS_CRIT_PCT) and the probe
# geometry (LOSS_PROBE_COUNT, LOSS_PROBE_INTERVAL) moved to
# lib/thresholds.sh, which bin/netdiag sources before this file. They left
# because lib/monitor.sh needs the same numbers without dragging in the
# whole global namespace: this file initialises run *state*, thresholds.sh
# declares run *policy*, and only the second is safe to source standalone.

# Internet-side ping (lib/internet_ping.sh)
INET_RTT_AVG=""
INET_RTT_JITTER=""
INET_LOSS=""
# A second, independent anycast resolver. Cloudflare and Google rate-limit
# ICMP under load, so a single lossy target is as likely to be the target's
# policy as the user's network. L1 escalates to critical only when both
# agree; one lossy and one clean is a warning at most.
INET_TARGET="1.1.1.1"
INET_TARGET_ALT="8.8.8.8"
INET_LOSS_ALT=""
INET_RTT_AVG_ALT=""

# Public reach / target ping (lib/public.sh)
PUBLIC_OK=0
# See WIFI_CHECKED above: --wifi-only never runs public_run, and the 0
# default used to fire the "nothing on the internet responded" critical.
PUBLIC_CHECKED=0
PUB_IP=""
PUB_ASN=""
PUB_ISP=""
PUB_CITY=""
PUB_CC=""                # full country name from ifconfig.co ("Brazil")
PUB_CC_ISO=""            # ISO-3166 alpha-2 ("BR") — what a flag or locale needs
CAPTIVE_PORTAL=0
CAPTIVE_PORTAL_CODE=""   # observed HTTP status — CP-1's evidence
TARGET_PING_LOSS=""
TARGET_PING_RTT=""

# Bufferbloat (lib/bufferbloat.sh)
BUFFERBLOAT_IDLE_GW_RTT=""
BUFFERBLOAT_LOADED_GW_RTT=""
BUFFERBLOAT_IDLE_INET_RTT=""
BUFFERBLOAT_LOADED_INET_RTT=""
BUFFERBLOAT_GW_DELTA=""
BUFFERBLOAT_INET_DELTA=""
BUFFERBLOAT_GW_GRADE=""
BUFFERBLOAT_INET_GRADE=""

# PMTU (lib/mtu.sh)
MTU_PATH_SIZE=""
MTU_EFFECTIVE=""

# DNS (lib/dns.sh)
DNS_OK=0
SYS_RES=""               # first configured nameserver — what dig is aimed at
SYS_RES_ALL=""           # every configured nameserver, deduped, in order
SYS_RES_MS=""            # primary resolver response latency in ms
DNS_NXDOMAIN_HIJACK_IP="" # IP returned for non-existent domain (if hijacked)
IPV6_DNS_FAIL=""         # unresponsive IPv6 nameserver (if any)
DNS_LINES=""             # one "resolver|name|answer|OK|FAIL" per line

# IPv6 (lib/ipv6.sh)
IPV6_AVAILABLE=0
IPV6_GLOBAL_ADDR=""
IPV6_GATEWAY=""
IPV6_PING_LOSS=""
IPV6_AAAA_OK=0
IPV6_TRACE_HOPS=""
IPV6_TCP_OK=0

# TCP reach (lib/tcp_reach.sh)
TCP_REACH_ANY_OK=0
TCP_REACH_LINES=""       # one "host:port|OK|ms" or "host:port|FAIL" per line

# Speed test (lib/speedtest.sh)
SPEEDTEST_DOWN_MBPS=""
SPEEDTEST_UP_MBPS=""
SPEEDTEST_LATENCY_MS=""
SPEEDTEST_JITTER_MS=""
SPEEDTEST_SERVER=""

# NTP (lib/ntp.sh)
NTP_DRIFT_S=""
NTP_USING_NETWORK_TIME=""
NTP_SERVER=""

# Traceroute / per-hop (lib/traceroute.sh, lib/mtr.sh)
HOPS=()
TRACE_LINES=""           # one "n|ip|rtt_ms" per line (1.1.1.1 traceroute)
TARGET_TRACE_LINES=""    # same shape, for the optional TARGET traceroute
PER_HOP_LINES=""         # one "n|ip|loss_pct|avg_ms" per line
MTR_FIRST_LOSSY_HOP=""

# DHCP (lib/dhcp.sh)
DHCP_SERVER=""
DHCP_LEASE_START=""
DHCP_LEASE_END=""
DHCP_TIME_REMAINING_S=""
DHCP_DNS_SERVERS=""

# ARP (lib/arp.sh)
ARP_DUPLICATE_IPS=""
ARP_GW_INCOMPLETE=0
GW_MAC=""                # gateway's hardware address; feeds NETWORK_ID

# Network identity (lib/netid.sh) — scopes baseline history so moving
# between networks doesn't register as a regression.
NETWORK_ID=""
NETWORK_LABEL=""

# /etc/hosts (lib/hosts.sh)
HOSTS_CUSTOM_COUNT=0
HOSTS_SUSPICIOUS_LINES=""

# NAT / WAN topology (lib/wan.sh) — v0.3 additions
WAN_LB_ASNS=""           # space-separated list, set if dual-WAN probe ran
WAN_LB_IPS=""            # space-separated list of distinct public IPs
WAN_LB_ACTIVE=0          # 1 = > 1 distinct ASN observed
WAN_DOUBLE_NAT_CHAIN=""  # space-separated RFC1918 hops before the first public one
WAN_DOUBLE_NAT=0         # 1 = > 1 *home-side* router chained (ISP 10/8 transit excluded)
WAN_NAT_HOME_CHAIN=""    # "→"-joined home-side hops (192.168/16, 172.16/12)
WAN_NAT_HOME_COUNT=0
WAN_NAT_ISP_CHAIN=""     # "→"-joined ISP-transit hops (10/8)
WAN_NAT_ISP_COUNT=0
WAN_UPNP_STATE="unknown" # enabled | disabled | unknown
WAN_UPNP_DEVICE=""
WAN_UPNP_URL=""
WAN_UPNP_TESTED_VIA=""   # miniupnpc | ssdp | nat-pmp

# Output / baseline (lib/output.sh)
DIAGNOSIS_LINES=""       # one "SEV|MSG" per line (SEV ∈ critical/warn/info)
BASELINE_JSON=""         # raw JSON from helpers/baseline.py
MOST_LIKELY_ROOT_CAUSE=""
