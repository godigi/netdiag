# shellcheck shell=bash
# lib/wifi_common.sh — WiFi scrapes shared by the scanner (lib/wifi.sh) and
# the live monitor (lib/monitor.sh).
#
# Why this file exists: the same three awk pipelines (hardware-port lookup,
# `ipconfig getsummary` SSID/BSSID, `wdutil info` field scrape) were
# copy-pasted into both files and had already started to drift in style if
# not yet in behaviour. One parser per upstream format means a macOS
# release that moves a label is fixed once, and the scan and the live dot
# cannot disagree about what the tool said.
#
# Every function takes its input as $1 (or an optional pre-read $2) rather
# than re-running the subprocess, so callers keep control of caching: the
# monitor reads networksetup once for the life of the process, a scan reads
# it per run.
#
# Sourced by lib/wifi.sh and lib/monitor.sh. Depends on nothing.

# The hardware-port name for a network device ("Wi-Fi", "Ethernet", …).
# $1 = device (en0), $2 = optional pre-read `networksetup -listallhardwareports`
# output. Prints "" when the device is unknown.
wifi_hw_port_for_device() {
  local d="$1" ports="${2:-}"
  if [ -z "$ports" ]; then
    ports="$(networksetup -listallhardwareports 2>/dev/null || true)"
  fi
  printf '%s\n' "$ports" | awk -v d="$d" '
    /^Hardware Port:/{port=substr($0, index($0,$3))}
    /^Device:/{if($2==d){print port; exit}}'
}

# True when the hardware-port name is a wireless one.
wifi_port_is_wireless() {
  printf '%s' "$1" | grep -qi 'Wi-Fi\|AirPort'
}

# SSID / BSSID / Security from `ipconfig getsummary <iface>` output ($1).
# Prints them TAB-separated; any field may be empty. No trimming: the
# ipconfig values are used verbatim everywhere today.
wifi_parse_ipconfig_summary() {
  printf '%s\n' "$1" | awk -F': ' '
    /^[[:space:]]*SSID[[:space:]]*:/     {ssid=$2}
    /^[[:space:]]*BSSID[[:space:]]*:/    {bssid=$2}
    /^[[:space:]]*Security[[:space:]]*:/ {sec=$2}
    END{printf "%s\t%s\t%s\n", ssid, bssid, sec}'
}

# Fields from `sudo wdutil info` output ($1). Prints seven TAB-separated
# fields: rssi, noise, channel, tx_rate, phy, ssid, bssid — any of which
# may be empty. RSSI/noise come back as bare numbers ("−55", not "−55 dBm").
# wdutil's SSID/BSSID arrive "<redacted>" without Location Services; the
# raw value is passed through so the caller applies its own policy (the
# scanner overrides only on a real value, the monitor ignores the field).
wifi_parse_wdutil() {
  printf '%s\n' "$1" | awk -F': ' '
    /^[[:space:]]*SSID[[:space:]]*:/ {
      v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); ssid=v }
    /^[[:space:]]*BSSID[[:space:]]*:/ {
      v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); bssid=v }
    /^[[:space:]]*RSSI[[:space:]]*:/ {
      v=$2; gsub(/[[:space:]]*dBm/,"",v); rssi=v }
    /^[[:space:]]*Noise[[:space:]]*:/ {
      v=$2; gsub(/[[:space:]]*dBm/,"",v); noise=v }
    /^[[:space:]]*Channel[[:space:]]*:/ {chan=$2}
    /Tx Rate/ {tx=$2}
    /PHY Mode/{phy=$2}
    END{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        rssi, noise, chan, tx, phy, ssid, bssid}'
}
