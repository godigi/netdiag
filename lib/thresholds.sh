# shellcheck shell=bash
# lib/thresholds.sh — every numeric threshold a diagnosis rule fires on.
#
# Why this file exists: netdiag now has two things that judge a network.
# The scanner (lib/diagnosis.sh, one verdict per run) and the monitor
# (lib/monitor.sh, one verdict every few seconds) must agree on what
# "lossy", "weak" and "drifted" mean, or the menu-bar app contradicts the
# report it links to — the user sees a red dot and a clean scan, and stops
# trusting both. The thresholds were inline literals in diagnosis.sh, so
# there was no way for a second consumer to read them.
#
# The GUI is explicitly forbidden from re-deriving any of these. It renders
# rule IDs the CLI hands it; the numbers live here and only here.
#
# Every constant names the rule(s) it decides, so a reader who sees `[G1]`
# in expert output can find the cutoff in one grep. The rationale for each
# rule is in docs/DIAGNOSIS-RULES.md; this file holds the values, not the
# argument for them.
#
# Sourced before lib/common.sh and lib/globals.sh in bin/netdiag, and
# independently by lib/monitor.sh. Nothing here may depend on another
# module.
#
# Read across modules that shellcheck can't follow from here.
# shellcheck disable=SC2034

# ── Packet loss ──────────────────────────────────────────────────────────
# Shared by the gateway rules (G1/G2/G3) and the internet-side rules
# (L1/L2) so the Report card and the diagnoses can never disagree about
# what counts as lossy.
#
# Both floors are expressed in whole dropped packets out of the 20 each
# probe sends, so each threshold lands on a value the probe can actually
# report: the quantum is 5%, warn is two drops, critical is four.
#
#   warn (L2, G3):        2+ drops of 20  → 10%
#   critical (L1, G1/G2): 4+ drops of 20  → 20%
#
# Why warn is two drops and not one: this is a judgement call, not a
# measurement. A clean link here reports 0.0% on both targets in every
# trial, so a 5% floor would not fire falsely on *this* network — but a
# single transient drop in twenty is an ordinary event on real links, and
# warning on it across the whole user base would be noise. Two drops is a
# firmer signal and still well clear of the 20% critical.
#
# (An earlier revision justified this floor with a measured 5% "noise
# level" at 0.1 s spacing. That reading was an artefact of ping's -t flag
# truncating the probe before the last reply arrived — see the header of
# lib/internet_ping.sh. With -t removed the noise level is 0.0%, and the
# thresholds now rest on the judgement above rather than on that number.)
LOSS_WARN_PCT=10
LOSS_CRIT_PCT=20

# G1/G2 — "you are losing packets to your own router". Deliberately a
# separate name from LOSS_CRIT_PCT even though the values match today:
# they answer different questions (how lossy is the LAN leg vs the WAN
# leg) and a future revision may want to move one without the other.
THRESH_GW_LOSS_CRIT_PCT=20

# 20 packets × 0.2 s ≈ 4 s per probe. The two internet targets are probed
# concurrently, so the wall-clock cost is one probe's worth. Both counts
# assume the caller passes no -t: on macOS that flag is a deadline for the
# whole run and silently truncates the probe to whatever fits.
LOSS_PROBE_COUNT=20
LOSS_PROBE_INTERVAL=0.2

# The monitor's per-cycle gateway probe. Ten packets, not the three or five
# a "quick liveness check" suggests, and the reason is quantisation rather
# than accuracy: at 3 packets the only reportable losses are 0/33/67/100%,
# so one dropped packet reads as 33% — past the 20% critical floor. At 5 it
# reads as exactly 20%, which still trips it. At 10 the quantum is 10%, so
# one drop lands in G3's warn band and it takes two to reach critical:
# the same shape the scanner's 20-packet probe produces. Cost is 2 s of a
# 10 s cycle, averaging one packet per second.
MONITOR_PING_COUNT=10
MONITOR_PING_INTERVAL=0.2

# The monitor's per-cycle internet-side probe (lib/monitor.sh's
# _mon_probe_internet). Twenty packets, matching LOSS_PROBE_COUNT rather
# than the gateway probe's ten, and the reason is the bug this replaces:
# that probe sent five packets, where one dropped packet reads as exactly
# LOSS_CRIT_PCT — so a single routine ICMP drop at a rate-limiting resolver
# fired L1 as an immediate critical, flashed the app's red card for one
# cycle, and cleared on the next. Cost is ~4 s of a 10 s cycle; the
# gateway probe's 2 s runs alongside it, and the loop sleeps only the
# remainder.
MONITOR_INET_PING_COUNT=20

# How many recent probes each loss figure accumulates over (both legs).
# Per-probe percentages move by their quantum no matter how large the
# burst is — 20 packets still makes one drop read 5% and then back to 0%,
# which is movement of the probe, not of the network. The monitor
# therefore reports lost×100÷sent over a rolling window of the last N
# probes, refreshed every fast cycle. Five × twenty packets is a
# 100-packet denominator: one dropped packet moves the reported figure one
# point, real loss ramps smoothly toward the thresholds, and routine noise
# contributes a fraction of a percent that decays out within ~a minute.
MONITOR_LOSS_WINDOW_PROBES=5

# A single cycle's loss is a blip, not a condition: at MONITOR_PING_COUNT=10
# one dropped packet reads as 10%, exactly LOSS_WARN_PCT. Requiring the same
# band on consecutive cycles turns a lost packet into a fact about the link
# rather than an alarm. Applies to the monitor only — a full scan's
# 20-packet probe already averages over more.
THRESH_MON_LOSS_CONFIRM_CYCLES=2

# TCP-1 — TCP connections succeed while ping reports heavy loss, i.e. the
# path filters ICMP. Set well above LOSS_CRIT_PCT: below this a real lossy
# link and a filtered one look the same, and calling a degraded network
# "just filtered ICMP" is the more damaging mistake of the two.
THRESH_ICMP_FILTERED_LOSS_PCT=50

# ICMP-1 — total loss to *both* public targets while curl and TCP both
# succeed. Real 100% loss would take curl with it, so this is a middlebox
# dropping ICMP wholesale, not an outage.
THRESH_ICMP_TOTAL_LOSS_PCT=100

# ── WiFi ─────────────────────────────────────────────────────────────────
# Read by helpers/signal_scale.py (netdiag --signal-scale) as the top edge
# of its four-band "Excellent/Good/Fair/Weak" scale — the word a GUI shows
# instead of a bare dBm number nobody without a radio background can read
# at a glance. -55 dBm is one bar short of a link to the router itself:
# strong enough that nothing on the wireless leg is ever the bottleneck.
THRESH_WIFI_RSSI_EXCELLENT_DBM=-55
# W1 — "your signal is weak" on its own.
THRESH_WIFI_RSSI_WEAK_DBM=-75
# G1 — the stricter cutoff used only to attribute *gateway loss* to the
# radio rather than the router. Easy to miss that these differ: a link at
# -72 dBm is not weak enough to complain about by itself (W1 stays quiet)
# but is weak enough to explain packets going missing (G1 fires instead of
# G2, and the user is told to move rather than to reboot the router).
THRESH_WIFI_RSSI_G1_DBM=-70
# W2 — signal-to-noise ratio, dB. Below this, interference rather than
# distance is the story.
THRESH_WIFI_SNR_LOW_DB=20
# WS-1 — how many other networks may share your channel before it counts
# as congested.
THRESH_WIFI_CHANNEL_NEIGHBOURS=3
# WD-1 — disconnects within WIFI_DISCONNECT_WINDOW_HOURS before the link
# counts as flapping.
THRESH_WIFI_DISCONNECTS=3

# ── IPv6 ─────────────────────────────────────────────────────────────────
# V6-1 — ping6 loss above this counts as broken IPv6 (given IPv4 works).
THRESH_IPV6_LOSS_PCT=20

# ── Path MTU ─────────────────────────────────────────────────────────────
# M1 — effective MTU below 1400 is a warning (standard PPPoE is 1492/1480,
# standard WireGuard is 1420); under 1280 (IPv6 minimum) it is a critical,
# because at that point ordinary HTTPS responses stop fitting.
THRESH_MTU_STANDARD=1400
THRESH_MTU_CRIT=1280

# ── Clock ────────────────────────────────────────────────────────────────
# NT-1 — drift in seconds. Past the critical floor, certificate validity
# windows fail and every https:// URL refuses to connect; the warn band is
# the range where some authenticated services object and most don't.
THRESH_NTP_DRIFT_CRIT_S=30
THRESH_NTP_DRIFT_WARN_S=1

# ── DNS ──────────────────────────────────────────────────────────────────
# D3 — warn when the primary resolver takes > 250 ms to answer. Public resolvers
# like Cloudflare (1.1.1.1) and Google (8.8.8.8) answer in 10-30 ms; taking > 250 ms
# makes every new website and link click noticeably stall before loading.
THRESH_DNS_LATENCY_WARN_MS=250

# ── DHCP ─────────────────────────────────────────────────────────────────
# DH-1 — warn when the lease has less than an hour left. Renewal is
# normally invisible; it is only interesting when the router happens to be
# rebooting or out of addresses at that moment.
THRESH_DHCP_LEASE_WARN_S=3600

# ── Comparing one stored run against its network's history ───────────────
# Read by helpers/history.py in --show mode, the only place a single past
# run is judged against every other run on the same network. It is judgement
# of the same kind the rules above make — "is this number normal here?" — so
# it lives here, and bin/netdiag exports both values into the environment
# before calling the helper. The helper refuses to run without them rather
# than carrying a default: a stale default still produces a plausible
# verdict, which is the worst way for a threshold to drift.
#
# Below this many samples of a metric, the spread is the sample's noise
# rather than the network's character. The comparison says
# insufficient_data instead of backing a confident "typical" with four
# readings — the same refusal to guess that keeps "not measured" out of the
# zero bucket everywhere else in this project.
THRESH_COMPARE_MIN_SAMPLES=10

# How wide the notable band is at each end of the distribution, in
# percentile points: the outer tenth either way is remarked on, the middle
# 80% is "typical". One symmetric cutoff rather than a separate "better"
# and "worse" percentile, because a directional pair reads naturally for
# latency and inverts for throughput — where the *low* percentile is the
# bad end — and a number whose meaning flips per metric is one that will
# eventually be applied the wrong way round. Direction is applied once,
# when a tail is turned into a verdict.
THRESH_COMPARE_TAIL_PCTL=10

# ── Speed regression confirmation (BL-1) ──────────────────────────────────
# Read by helpers/baseline.py, the fourth thing in the project that judges
# whether a number is normal, and plumbed through the environment exactly
# like THRESH_COMPARE_* above: lib/output.sh exports both before calling the
# helper, which refuses to run without them rather than carrying a default.
#
# A speed test result depends on who else is using the link at that exact
# moment, not just on the network's own health, so one slow run is
# ordinary noise — someone else streaming, a busy time of day — not a
# regression. THRESH_SPEED_CONFIRM_RUNS measured runs in a row, all below
# factor × median, turn that noise into a fact about the network. 2 is the
# smallest number that is actually a confirmation rather than a single
# reading counted twice.
THRESH_SPEED_DROP_FACTOR=0.5
THRESH_SPEED_CONFIRM_RUNS=2

# ── Bufferbloat grading ──────────────────────────────────────────────────
# Waveform/DSLReports cutoffs for added latency under load, in ms:
# A < 5, B < 30, C < 60, D < 200, F ≥ 200. B1/B2 warn at grade C and go
# critical at D or F. Read by grade_bufferbloat in lib/common.sh.
THRESH_BUFFERBLOAT_A_MS=5
THRESH_BUFFERBLOAT_B_MS=30
THRESH_BUFFERBLOAT_C_MS=60
THRESH_BUFFERBLOAT_D_MS=200
