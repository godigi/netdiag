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

# WiFi (lib/wifi.sh, lib/wifi_scan.sh, lib/wifi_disconnect.sh)
IS_WIFI=0
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

# VPN (lib/vpn.sh)
VPN_ACTIVE=0
VPN_TYPE=""
VPN_NAME=""

# Gateway reachability (lib/gateway.sh)
GW_LOSS=""
GW_LATENCY=""
GW_JITTER=""           # stddev from ping summary, ms

# Internet-side ping (lib/internet_ping.sh)
INET_RTT_AVG=""
INET_RTT_JITTER=""
INET_LOSS=""

# Public reach / target ping (lib/public.sh)
PUBLIC_OK=0
PUB_IP=""
PUB_ASN=""
PUB_ISP=""
PUB_CITY=""
PUB_CC=""
CAPTIVE_PORTAL=0
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
SYS_RES=""
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
NEXTHOP_LOSS=""
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
