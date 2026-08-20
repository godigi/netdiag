# Changelog

All notable changes to `netdiag` are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The monitor auto-starts a 2 s "investigation" burst the moment the
  CLI's verdict turns from ok/info to warn/critical — before an alert's
  dwell has elapsed and before any triggered scan lands.** The user's
  mental model is that the app starts pinging constantly and fast the
  instant something looks wrong, and this is what delivers it: the
  monitor restarts at the 2 s latency-test floor for 60 s, so gateway
  and internet ping arrive every 2 s rather than every 5 s while the
  problem is being confirmed. After the burst, sustained degraded (3 s)
  takes over for as long as severity stays warn/critical. Fires only on
  the genuine ok/info → warn/critical edge, not on every warn/critical
  sample, so a sustained outage gets one surge at onset and a steady 3 s
  after, not a restart every minute. Suppressed while a scan is running
  (a scan pauses the monitor and saturates the link; 2 s samples would
  measure the scan's own traffic) and while paused or stopped.
- **The app gained a `--verify` mode: a runnable test harness for the
  GUI logic that `swift test` cannot provide on this toolchain.** The
  Command Line Tools ship Swift Testing's `Testing.framework` but not
  the `xctest` host, so a test target compiles here but `swift test`
  exits 0 having run nothing — and a separate executable target cannot
  import `NetdiagGUI` because SwiftPM does not export an executable's
  symbols to importers. `--verify` runs inside the app process itself
  (full internal access, no public-izing), reachable as `swift run
  NetdiagGUI --verify` or via the bundled binary: it asserts every
  `StageResolver` severity → stage mapping and every precedence guard,
  offscreen-renders a stage-card stand-in per stage to PNG, prints
  PASS/FAIL per check and exits non-zero on any failure. Wired into
  `AppDelegate.applicationWillFinishLaunching` so it exits before the
  monitor starts or any UI appears. The `Package.swift` test target also
  gained the `-F` framework search path that lets `import Testing`
  resolve at compile time on the CLT.

- **The Networks tab is searchable, and ordered by recency.** A toolbar
  search field filters the list by the things a person actually
  recognises a network by — display name, raw label, SSID, gateway, ISP
  — with case- and diacritic-insensitive matching so "comcast" finds
  "Comcast" and "café" finds "Cafe" without typing either precisely.
  macOS hides the SSID without Location Services, so the SSID is only
  present when permission was granted at scan time; searching by the
  user-assigned rename still works without it. The list is also
  recency-ordered now (most-recently-seen first, falling back to
  run-count and then name for stable ties): you go to that tab to find
  the network you just left or the one you are on, not the one you have
  used the most over all time.

- **The Live charts snap a highlight to the point under the cursor.**
  Hovering (or dragging) anywhere along a panel's x-axis in the Live tab
  snaps a white highlight to the nearest measured point and floats its
  value and wall-clock time above it; moving off the chart clears it.
  The chart body was extracted into its own `LiveChart` so each panel
  owns its own selection state — one `@State` per panel rather than one
  shared across three charts that would cross-talk. The nearest-point
  scan is O(points) per move, which is fine because the window is
  bounded to one hour (at most a few hundred samples), so the linear
  scan is cheaper than maintaining an index would be.

- **The GUI reads the Wi-Fi network name from CoreWLAN, not the CLI.**
  TCC attributes `ipconfig getsummary` — the bundled CLI's SSID source —
  to `/usr/sbin/ipconfig` rather than this `.app`, so a Location Services
  grant to netdiag unredacts the GUI's own CoreWLAN `ssid()` call but
  leaves the CLI's reading empty or redacted. Without this, a user who
  had granted Location saw "Wi-Fi (SSID hidden by macOS)" in the
  dropdown even though the permission was live. The coordinator now
  reads the SSID via CoreWLAN once per monitor sample (never in a view
  body — it is a real syscall on an always-visible menu), adopts it as
  the current network's display name the moment it is available
  (overwriting only the ugly MAC-keyed `wifi:mac=…` placeholder, never a
  user rename or a real sudo-captured SSID), and `wifiDisplayName`
  prefers the live SSID over the CLI's redacted label. A user-assigned
  rename still wins over everything. One consequence: a network the
  user has granted Location for no longer sits in the Networks tab
  labelled `wifi:mac=…` forever — its real SSID is recorded as its
  custom name the first sample it is seen.
- **The Dock icon and Cmd-Tab slot appear only while a window is open.**
  The app ships as `LSUIElement` — no Dock icon, no switcher slot, which
  is right for an always-on menu-bar monitor. But a window opened on
  purpose should behave like a normal window while it is on screen: the
  activation policy flips to `.regular` the moment the first real
  `Window` scene (dashboard, settings, onboarding) appears and back to
  `.accessory` the instant the last one closes, so the Dock icon
  vanishes again when you are done but the menu-bar dot stays. Driven by
  `onAppear`/`onDisappear` on each window's root view rather than
  `NSWindow` notifications, which fire unreliably for SwiftUI `Window`
  scenes and left the Dock icon stuck or the switcher slot missing.
  Opening a window also activates the app so it arrives in front rather
  than behind whatever was frontmost, and so the switcher picks up a
  policy that just changed to `.regular` at runtime.

- **`netdiag --signal-scale`** — one JSON object with the four Wi-Fi
  signal bands this install's thresholds define: Excellent / Good / Fair
  / Weak, each a dBm floor, a tone, and a one-sentence explanation. Exists
  because a raw RSSI number ("-62 dBm") means nothing to almost anyone —
  a consumer now has the CLI's own word to show instead, with the dBm
  kept as a secondary detail rather than dropped. Boundaries are
  `lib/thresholds.sh`'s `THRESH_WIFI_RSSI_EXCELLENT_DBM` (new, -55),
  `THRESH_WIFI_RSSI_G1_DBM` (-70, already backing rule G1) and
  `THRESH_WIFI_RSSI_WEAK_DBM` (-75, already backing rule W1) — reused
  rather than duplicated, and read through the environment the way
  `helpers/history.py`'s `--show` reads `THRESH_COMPARE_*`. New
  `helpers/signal_scale.py`; `tests/test_signal_scale.bats` covers shape,
  band ordering, boundaries moving with the thresholds, and refusal to
  run without them. (GUI) A new `SignalScaleStore` fetches and caches it
  exactly the way `RulesCatalogStore` does; `DropdownView`'s Wi-Fi
  instrument cell and a Wi-Fi row restored to `HomeView` (see below) both
  render the CLI's label as the value and the dBm as the unit, tinted by
  the band's tone — never a Swift-authored word or a dBm comparison in
  Swift.
- **`--rules-catalog` gains a `metrics` glossary (schema 1 → 2).** A
  sibling array to `rules`: one entry per jargon term the report card
  shows (`router`, `internet`, `dns`, `wifi_signal`, `bufferbloat`,
  `mtu`, `speed`, `clock`, `packet_loss`, `latency`, `jitter`), each a
  `key`/`label`/1–2 sentence `help` explaining the term to someone who's
  never heard it — same qualitative-only discipline as `blurb`, no
  embedded numeric threshold. (GUI) `RunReportView`'s report card is
  restructured into columns — label (with a `questionmark.circle`
  `HelpHint` fed by this glossary), this run's value, the network's
  median, and a short verdict chip (`Typical`/`Better`/`Worse`/`Best`/
  `Worst`, straight from the comparison's own `verdict` token, full CLI
  sentence on hover) — instead of one long CLI sentence sitting inline on
  every row.
- **`HomeView` regains a Wi-Fi row (network name + signal).** Investigated
  where "the dashboard used to have the Wi-Fi name and signal" actually
  lived: never on `HomeView`/its tabbed-window predecessor at any commit
  — only the pre-redesign single-panel `DropdownView` (commit `9aebf71`
  and earlier) had a combined `wifiGlanceInfo` row, and that panel split
  into today's separate main window and menu-bar dropdown well before
  this branch. Not a regression, not a permission-only gate — the row
  simply never existed on Home. Restored it: name from a new
  `NetdiagCoordinator.wifiDisplayName` (the exact logic `DropdownView`'s
  `cleanNetworkName` had, moved to the coordinator so both views share
  one answer instead of two that could drift), signal from the same
  word-plus-dBm treatment as the dropdown, with the identical CoreWLAN
  fallback when the monitor's RSSI is null and Location Services is
  authorized. When it isn't authorized, the existing restriction banner
  is unchanged — no blank row underneath it.
- **`--monitor` schema 2: samples describe their own changes.** When a
  tracked field differs from the previous sample — public IP, country,
  ISP, VPN state/name, Wi-Fi network or AP, interface, or a diagnosis
  rule firing/clearing — the emitted line carries a `changes` array
  (`{id, field, from, to, summary}`) with the phrasing authored by the
  CLI, so every consumer tells the same story. Null means "not
  measured" and never counts as a change; the key is absent when
  nothing changed; rule summaries use the rules catalog's plain-English
  titles ("Router dropping packets"), not bare IDs. Gate on
  `--capabilities` `schemas.monitor >= 2`.
- **The menu-bar dropdown was rebuilt around monitoring** (GUI): an
  adaptive stage (healthy / alert / testing / paused / version-skew)
  over a fixed 4×2 instrument grid, a labeled internet-ping heartbeat
  strip with min/avg/max, and a change timeline fed by a new persistent
  event log (monitor changes + fired alerts, coalescing repeats).
  Location shows only the country flag — hover reveals the public IP,
  click copies it. One primary action remains ("Check My Connection");
  the dashboard's Activity section is now a real event list.
- **Releases are published from this file.** New
  `.github/workflows/release.yml` turns a pushed `v*` tag into a GitHub
  Release whose notes are the matching section below, extracted by a new
  `helpers/changelog_section.py`. Before it, publishing a Release was a
  step a human had to remember, and the memory failed for three months:
  eleven tags were pushed and two became Releases, so the repo's front
  page advertised v0.2.1 from May as "Latest" while `install.sh` was
  fetching v0.9.1. The workflow refuses a tag whose version disagrees with
  `bin/netdiag`'s `NETDIAG_VERSION`, or that has no section here — the two
  drifts this repo has actually suffered — and can be re-run by hand
  against an existing tag to repair its notes. `CONTRIBUTING.md` gains the
  eight-step release checklist it enforces.
- **`tests/test_changelog.bats`** — 11 structural guards on this file,
  because every defect below was invisible until someone went looking and
  none of them broke a build: a duplicate heading, a version documented
  with no tag, a heading with no link reference, a section truncated
  mid-sentence, and a version string in `bin/netdiag` with nothing here
  describing it.

### Changed

- **The Networks tab was redesigned into a two-column master-detail
  layout.** The previous design was a `NavigationStack` of network cards
  — each card carried its stats inline and a "Browse Checks" link that
  pushed a second screen for the run list, which pushed a third for a
  single run. Three screens deep to read one check. The tab is now a
  list of network names on the left (clickable, searchable, arrow-key
  cycleable — just the name and a green dot for the connected one, no
  stats on the row) and everything about the selected network on the
  right: the name with rename/merge/unmerge controls, the stats row
  (checks, problems, median RTT, date range), and the checks list
  itself — inline, no navigation push. Clicking a check swaps the right
  pane to its detail with a back button; still one screen, the list
  column never moves. Opens with the current network selected by
  default. A "Problems only" checkbox replaces the segmented picker that
  lived on the pushed screen.
- **Network names now prefer the SSID and strip the ISP "via" suffix.**
  `HistoryStore.displayName` was returning the CLI's raw label, which is
  the ISP name + " via " + gateway when no SSID was captured — so the
  Networks tab titled every network "SPACEX-STARLINK via 192.168.50.1"
  rather than anything a person recognises. It now prefers a recorded
  SSID (available when Location was granted at scan time), then a
  cleaned label with the " via <gateway>" suffix stripped, so
  "SPACEX-STARLINK via 192.168.50.1" reads "SPACEX-STARLINK". The full
  label stays in the document and is still searched by.
- **The dropdown's stage card now reflects the CLI's verdict the moment a
  rule fires, not 15–25 s later when the alert's dwell elapses.** Until
  now the card read "All good — watching" for the entire dwell window of
  whichever alert would eventually fire, even though the menu-bar dot
  had already turned amber/red and the change timeline below the card
  already showed the drop — a green card over a red timeline that read
  as a bug, and the opposite of "very reactive the moment it starts
  detecting packet loss or bad Wi-Fi". The stage mapping was extracted
  into a pure `StageResolver.resolve(_:)` and given a new `.watching`
  state: `warn` severity turns the card amber with "Watching — something
  needs attention", `critical` turns it red with "Detecting a network
  problem", both carrying the CLI's own blurb for the worst firing rule
  (the same source `headline` already uses) and a tertiary line
  explaining why no alert has fired yet ("Confirming before notifying
  you…"). An already-active alert still wins over `.watching`, so once
  the dwell elapses the card carries the alert's prose as before. The
  `info` severity (VPN on, ICMP filtered) still reads healthy — it is
  not a fault. Precedence (scan > user-pause > skewed > alert > watching
  > healthy) is preserved and now unit-checked.
- **The live probe interval is shown in the heartbeat strip, and it
  updates the moment the monitor's cadence does.** Reads the sample's
  own `status.cadence_s`, so it reads "every 5s" while healthy, "every
  3s" once degraded engages, and "every 2s · test" during a latency-test
  burst — changing the instant the monitor's cadence changes rather than
  from a settings snapshot. A user watching the card turn red now sees
  the probe rate ramp up at the same time, the evidence that the app is
  investigating.
- **Default cadence lowered: fast 10 s → 5 s, degraded 5 s → 3 s.** An
  always-on monitor's healthy probe was too slow to read as "watching",
  and the degraded tier sat at the same 5 s the latency test uses —
  leaving no ramp between healthy and a full burst. The fast tier now
  probes every 5 s by default, degraded every 3 s, and the 2 s burst
  (below) is the floor for active investigation. User-tunable still;
  existing installs keep whatever they have saved.
- **The heartbeat strip dropped its redundant "internet ping · live"
  label.** The strip's shape is the headline; the label repeated what
  the strip already shows, and a min/avg/max pinned to the right read
  as a caption to nothing. The numbers now sit directly under the
  strip's left edge; only "monitoring off" remains as a label, for when
  there is no shape to read.
- **The dropdown's link-path bar, glance panel, quick-action grid, and
  contextual remedy row were retired**; their facts moved into the
  instrument grid and the alert stage. The footer regained Open
  Dashboard and Pause/Resume Monitoring after user testing.

### Fixed

- **The Networks tab did 3 full merge+sort passes on every redraw.** The
  body evaluated `mergedNetworks` (merge + sort by run-count) for the
  emptiness check, then `visibleNetworks` → `mergedNetworksByRecency`,
  which called `mergedNetworks` (merge + sort by run-count *again*) and
  re-sorted by recency — three O(networks) merge passes and two redundant
  sorts per render, over ~2,000 runs on a real store. The merge is now
  factored into `mergedNetworksUnsorted` (O(networks), no sort); both
  `mergedNetworks` and `mergedNetworksByRecency` sort from that shared
  base. The emptiness check now reads `document.networks.isEmpty` (no
  merge at all) instead of `mergedNetworks.isEmpty`, so a render with no
  search pays one merge + one sort, not three.
- **The Networks tab flashed "No networks recorded yet" during the
  initial load.** The `.task` that calls `store.load()` ran after the
  first body, so the view rendered the empty-state before the history
  arrived. `store.isLoading` existed but was never read. The tab now
  shows a spinner and "Loading networks…" while `isLoading` is true and
  the document is still empty, falling through to the real empty-state
  only once the load finishes.
- **The merge sheet listed networks in a different order than the tab.**
  The sheet used `mergedNetworks` (run-count order) while the tab used
  `mergedNetworksByRecency` (recency order), so a network near the top
  of the tab was in a different position in the sheet. Both now use
  recency order.
- **The search "no match" message showed the raw untrimmed query.**
  Typing "  comcast  " printed `No networks match   comcast  ` with the
  whitespace intact. The query is now trimmed and quoted.
- **A real internet outage read as a green dot for up to a minute.**
  fast tier pings the internet every cycle, but the TCP and public probes
  that distinguish a real outage (L1, critical) from an ICMP-filtering
  hotel network (ICMP-1, info) run on the 60 s medium and 300 s slow tiers
  and are carried over stale between refreshes. So for up to a minute into
  an outage TCP and public still read "ok" from before the drop,
  `_mon_rules` concludes ICMP-1, severity stays info, the menu-bar dot
  stays green, and no connection-lost alert fires — a manual scan was the
  only thing that forced fresh probes, which is why alerts appeared only
  after "Check My Connection" was pressed. `monitor_run` now forces a
  fresh TCP and public probe the moment the fast tier sees critical
  internet loss with a quiet gateway, so `_mon_rules` decides L1 vs
  ICMP-1 on fresh data within one cycle and degraded engages immediately.
  Gated on the tier not having already run that cycle, so a cycle that
  hit its own timers pays nothing extra, and during a sustained outage
  the forced path fires only on cycles the scheduled tiers skipped. A
  `test_monitor.bats` case guards the structural fix: the condition
  exists, keys on the shared threshold variables (not inline numbers),
  and gates the forced re-probe on the tier not having already run.
- **The paused-monitor test no longer fails in CI on a slow runner.** It
  slept a fixed 4 s, sent `SIGUSR1`, slept 3 s more and read the stream's
  last line — so on a loaded runner it read an empty file and died with a
  JSON decode error, leaving a red `bats` badge on a public README for
  three days. It now polls for the pause marker with the same `wait_until`
  helper the three tests directly above it already use, and whose comment
  documents this exact failure. The neighbouring SIGHUP test got the same
  treatment for its pre-pause wait: pausing a monitor that had not probed
  yet would have passed while asserting nothing.
- **This file had a second `## [Unreleased]` heading**, buried between
  `[0.5.2]` and `[0.5.1]`, holding notes — the one-line installer,
  `docs/JSON-SCHEMA.md`, `CONTRIBUTING.md`, CI smoke tests, the removal of
  `netdiag-prompt.md` — that had actually shipped in 0.6.0. They have been
  merged into `[0.6.0]`, where the commits that made them live. Its
  trailing "Known" note about `VPN-1` never firing went with them: 0.6.0
  is the release that fixed it.
- **`[0.9.1]`'s heading was written over the last line of the entry above
  it**, which ended mid-sentence at "and a real `--json --quick` run is".
  Restored from `3458283~1`.
- **`[0.9.1]` was missing half of what it shipped.** `--version`,
  `--capabilities`, `--rules-catalog`, `run_id` and `metric_stats` were
  all committed before `3458283` and are therefore inside the `v0.9.1`
  tag, but sat under `[Unreleased]` because that release was tagged
  without rolling the section over. Moved into `[0.9.1]`, verified by
  `git merge-base --is-ancestor` against every entry rather than by
  reading dates. Left where they were, the next release would have
  claimed them as its own.
- **Four documented versions had no tag at all** — 0.1.0, 0.4.1, 0.5.0
  and 0.9.1 — so their entries described something a reader could not
  check out, and `install.sh` fetched a v0.9.1 that `git` had never heard
  of. All four are now annotated tags on their release commits, dated to
  match. Every heading also gained the Keep a Changelog link reference it
  was missing, so each version links to its own diff.

## [0.9.1] - 2026-08-15

Adds GitHub auto-update checks to the GUI, new layperson-tailored
diagnostics for DNS and IPv6, router gateway admin quick access, and speed
test retention — plus the four CLI surfaces a GUI needs before it can
trust the binary it is talking to: `--version`, `--capabilities`,
`--rules-catalog`, and `run_id`/`metric_stats` in the JSON.

Those CLI entries were documented under `[Unreleased]` until well after
this release shipped, because 0.9.1 was tagged without rolling the section
over. They are recorded here, where the commits actually are: every one of
them is contained in `v0.9.1`. `.github/workflows/release.yml` now refuses
a tag whose notes are still sitting under `[Unreleased]`, so the same
omission fails the build rather than surviving into the docs.

### Added

- **GitHub Auto-Update Capability**: Daily automated background update checks against `godigi/netdiag` releases and in-app updating/relaunching from Settings.
- **`D3` Diagnostic**: Slow DNS resolver latency warning with actionable recommendation for Cloudflare (1.1.1.1) / Google (8.8.8.8).
- **`D4` Diagnostic**: DNS NXDOMAIN hijacking and ISP search redirection detection.
- **`V6-2` Diagnostic**: Dead IPv6 DNS resolver fallback delay warning.
- **`double-nat` Alert**: Plain-English alert and recommendation for chained home routers (Double NAT).
- **Router Gateway Admin Access**: Clickable router gateway IP in dropdown to instantly open the router admin page.
- **Speed Test Retention**: Retains speed test metrics permanently in memory and dropdown view across scans.

- **`netdiag --version`** — prints `netdiag VERSION` and exits 0.
- **`netdiag --capabilities`** — a JSON handshake describing this
  install: per-mode schema numbers, a `features` list, and which
  optional dependencies (`jq`, `mtr`, `gping`, `speedtest`/`speedtest-cli`)
  are actually on `PATH`. Lets a GUI detect what its CLI supports before
  it relies on a feature, instead of parsing `--version`'s semver and
  guessing.
- **`netdiag --rules-catalog`** — one JSON object cataloguing every rule
  the diagnosis engine and the monitor can emit: `title`, `category`,
  descriptive `severity`, `scope` (`scan` / `monitor` / `both`), a
  plain-English `blurb`, and a `doc` anchor into
  `docs/DIAGNOSIS-RULES.md`. The GUI holds no diagnostic logic, so the
  plain-English layer next to a rule-ID chip has to come from the CLI —
  this is that source. `tests/test_rules_catalog.bats` diffs the catalog
  against every `add_diag`/`_mon_add_rule` call site so the two can't
  drift apart silently.
  - `--capabilities`'s `schemas` now also reports `rules_catalog`, the one
    divergence from its own "never the odd one out" docstring — every
    other output that embeds a `"schema"` field was already listed.
- **`--json` gains `run_id`** — the same `"<timestamp>.<8 hex>"` id
  `netdiag --history`/`--show` will later derive for this exact run,
  computed at run time so a GUI can deep-link to "the check that just
  ran" from an alert without waiting for the next `--history` poll.
  `lib/output.sh` computes it by importing `helpers/history.py`'s own
  `canonical()`/`run_id()` rather than reimplementing the hash, from the
  precise record about to be appended — so the two can never disagree —
  and the record written to `baseline.jsonl` is unchanged: the build that
  gets stored never carries a `run_id` key at all, not even `null`,
  because a key holding a run's id can't also sit inside the bytes that
  id is hashed from. `null` when nothing was appended this run
  (`--no-baseline`, `--mtu-only`, `--wifi-only`) and, for a different
  reason, under `--redact`: the record really is stored — the private,
  unredacted build always is — but the id is a pointer back into that
  private copy, and the "shareable" rendition shouldn't carry a working
  key into data it otherwise took pains to mask.
- **`--history` gains `metric_stats`** on every network: `{median, p10,
  p90}` for each of the 13 charted metrics, over the exact population
  `metric_samples` already counts. Reuses `--show`'s own
  `quantile()`/median arithmetic rather than a second implementation, and
  carries no `value`, `direction` or `verdict` — facts about the network,
  not a judgement of any one run, which stays `--show`'s job. Below
  `THRESH_COMPARE_MIN_SAMPLES` the whole per-metric block is `null` rather
  than a partial object, mirroring `--show`'s `insufficient_data`; a plain
  `netdiag --history` now needs `THRESH_COMPARE_MIN_SAMPLES`/
  `THRESH_COMPARE_TAIL_PCTL` in the environment for this reason, the same
  way `--show` always has.

### Changed

- **jq is no longer required for the speed test.** The ~10 `jq -r` calls
  that parsed Ookla's and `speedtest-cli`'s final result JSON are now one
  call to `helpers/speedtest_result.py`, a stdlib-only parser that reads
  the result object on stdin and writes `down_mbps`/`up_mbps`/
  `latency_ms`/`jitter_ms`/`server` as one tab-separated line — same
  deny-by-default discipline the fd-3 progress translation already used
  for the same reason: an Ookla result carries `interface.internalIp`
  (a dual-stack Mac's public IPv6 address), `externalIp`, `macAddr` and a
  `result.url`, none of which may reach stdout. `speedtest_will_run()`
  and `speedtest_run()` no longer gate on `command -v jq` at all, so a
  machine with only bash 5 and python3 now gets a real speed test instead
  of a "brew install jq" hint. `lib/headline.sh`'s Report card drops the
  matching hint row for the same reason. `mtr`'s sudo-only per-hop view
  and Tailscale's VPN name are the only things jq still touches; both are
  optional enhancers, not defaults, and are unchanged.
  - New `tests/test_speedtest_parse.bats` (17 cases) drives the helper
    against fixtures for both flavors — a hand-checked bandwidth
    conversion (60875000 bytes/s → 487.0 Mbps), absent-field and
    malformed-input handling, and a privacy test asserting the identifying
    Ookla fields never reach stdout — plus two structural checks that
    neither speed-test function's source still mentions jq.
  - CI gained a broken-jq smoke test: `jq` is shadowed by a failing stub
    earlier in `PATH` than either Homebrew prefix — jq is present and
    resolves, it just fails — and a real `--json --quick` run is
    asserted to exit anything but 3 and to parse with `python3`.

## [0.9.0] - 2026-08-12

Makes a check watchable while it runs. A full check takes ~55 s and
showed a spinner for all of them; the monitor held an hour of samples
nothing drew; and there was no way to ask one question without waiting
for all 28 checks.

### Added

- **`netdiag --progress`** — a JSON event stream on **fd 3**: a `plan`
  naming the phases a mode will attempt, then `start`/`done`/`skip` per
  phase, then a closing `run` event. Emitted from `run_timed` and
  `launch_parallel`, so all 28 checks report and so does every check
  added later.
  - Not stdout, which must stay exactly one object, and not stderr:
    `launch_parallel` captures each parallel check's stderr into a
    per-check file that nothing reads until the check finishes — which is
    when progress stops being useful. fd 3 survives that redirect and was
    unused across the whole tree.
  - A plan, not a percentage. `--json` produces nothing until the end, so
    there is no quantity a percentage could be a percentage *of*.
  - Every event is clamped well under `PIPE_BUF`, because parallel
    subshells share fd 3 and only sub-`PIPE_BUF` pipe writes are atomic.
    Clamping happens *before* escaping — a cut landing between a
    backslash and the character it escapes stops the line being JSON.
- **Live speed-test progress**, newly possible: Ookla's `--format=jsonl`
  streams, where the `speedtest-cli` shim it replaced emitted nothing
  until the end. 201 events in a real run.
- **`netdiag --speed-only`** — one measurement without the other 27
  checks, recorded to history.
- **`run_mode`** on every record: `full`, `quick`, `speed-only`,
  `mtu-only`, `wifi-only`. A `--quick` run and a full check were
  previously indistinguishable in history, which overstated what a
  network's run count actually measured. `helpers/history.py` gains
  `check_count` beside `run_count`; partial modes contribute their
  metrics but not to severity or incident counts.
- **App: a Live tab** — gateway RTT, internet RTT and router loss over
  the last hour, drawn from samples the monitor was already keeping.
- **App: scan progress replaces the spinner**, and on-demand speed and
  latency tests in the dropdown.

### Fixed

- **Cancelling a scan reported "netdiag returned something unreadable".**
  Terminating the child yields a signal status and empty stdout, which
  the runner classified as corrupt output rather than as cancellation.
- **The elapsed-seconds counter froze during a scan** — it recomputed
  only on observation, and the monitor that drove observation is paused
  for the duration of every scan.
- **The expert panel's sparklines drew straight lines across monitor
  pauses**, claiming measurements that were never taken.

### Notes

- Ookla's `testStart` line carries `interface.internalIp` — the
  machine's public IPv6 address. The translation to fd 3 extracts four
  fields by name and rebuilds the object; it never passes through and
  never filters known-bad keys. A fixture asserts the leak, and a real
  217-event run was scanned for every identifying field in that line.
- The declared plan is kept in sync with the code by a bats guard that
  plants a phase into a copy of `bin/netdiag` and proves it catches it.

## [0.8.0] - 2026-08-11

Makes the run history readable. `~/net-diag/baseline.jsonl` already held the
complete JSON of every check ever run — 1,986 finished reports, each with
its own diagnosis prose — and the app could open exactly one of them: the
most recent. Now you can open any of them, and see how it compares to what
is normal for that network.

### Added

- **`netdiag --show=<id>`** — one stored run in full, plus a `comparison`
  block scoring each of its metrics against every other run on the same
  network: median, p10/p90, percentile, and a verdict. ~0.14 s against a
  1,986-record store.
- **Stable run ids** on `--history` output: the timestamp, a dot, and eight
  hex characters of the record's content hash. `ts` alone cannot address a
  run — `helpers/history.py` has always deduped on *(timestamp, content)*
  precisely because two runs can land in the same second.
- **`THRESH_COMPARE_MIN_SAMPLES` and `THRESH_COMPARE_TAIL_PCTL`** in
  `lib/thresholds.sh`. One symmetric tail rather than a "worse" and a
  "better" percentile: a directional pair reads correctly for latency and
  inverts for throughput, where the *low* percentile is the bad one.
- **App: browse every check on a network** — Networks → Browse checks → a
  run, showing the same report card as the Status tab plus the comparison.

### Fixed

- The menu-bar health dot rendered grey in every state. `MenuBarExtra` hands
  its label to an `NSStatusItem`, which template-renders SF Symbols and
  discards `foregroundStyle` — so the one glyph carrying the app's whole
  status said nothing. Now rasterised with an explicit palette colour.
- Stored records are decoded leniently. Swift's synthesized `Decodable`
  throws on a missing key rather than using the default beside the property,
  and only **60 of 1,986** stored records carry `network` or `timings` — the
  rest predate those fields. A strict decode opened 3% of the history and
  called the remainder corrupt.

### Notes

- `helpers/history.py` is now the third file `tests/test_thresholds.bats`
  guards against inline numeric cutoffs, alongside `lib/diagnosis.sh` and
  `lib/monitor.sh`. It judges now, so it lives under the same rule.
- Percentile ranks average ties. Counting them as "at or below" puts a
  0 %-loss run — the usual case — at the 100th percentile of a
  lower-is-better metric and calls a flawless check *worse than usual*.

## [0.7.0] - 2026-08-11

Adds a native macOS menu-bar app, and the two CLI surfaces it is built on.
The app is a **client, not a second brain**: it holds no thresholds and
writes no diagnosis prose. Everything it says comes from the CLI.

### Added

- **`netdiag --monitor`** — a long-lived process emitting one compact JSON
  object per line on stdout, flushed per sample, until stopped. The
  machine-readable sibling of `--watch`: where `--watch` re-runs `--quick`
  and prints prose for a person, `--monitor` streams for a program, writes
  no log and no history record, and probes on three cadence tiers instead
  of one — fast (gateway ping, VPN, link) 10 s, medium (DNS, TCP/443,
  RSSI) 60 s, slow (public IP, ISP, country, captive portal) 300 s plus
  immediately on a network change. Sample shape documented separately in
  `docs/JSON-SCHEMA.md`; intervals overridable with
  `--monitor-{fast,degraded,medium,slow}-interval`.
  - Each sample carries `status.rules`: the `DIAGNOSIS-RULES.md` IDs that
    would fire, evaluated in bash against `lib/thresholds.sh`. For any
    given network state the monitor and a full run name the **same** rule
    IDs, asserted by bats across eleven conditions. Consumers render the
    list; they never re-derive it.
  - The gateway probe sends **10** packets, not the 3 a liveness check
    suggests. This is quantisation, not accuracy: at 3 packets the only
    reportable losses are 0/33/67/100 %, so one dropped packet reads as
    33 % — past the 20 % critical floor. At 10 the quantum is 10 %, so one
    drop lands in G3's warn band and it takes two to go critical, matching
    the shape of the scanner's 20-packet probe.
  - Samples are emitted through a Python helper rather than bash `printf`.
    An SSID may legally contain a quote, a backslash or a newline, and a
    JSON-escaping bug in a stream parsed forever is a far worse trade than
    ~50 ms of interpreter startup per cycle.
- **`netdiag --history[=N]`** — the whole run store as one normalized,
  network-grouped object. 5.4 MB of full snapshots becomes 467 KB.
  - Grouping is **not** exact-string matching on `network.id`, because
    that does not work on real data: of 1,972 records here, 1,926 predate
    `lib/netid.sh` and carry no id at all, all 46 that do are
    `wifi:mac=…` because macOS has redacted the SSID throughout v0.5.x,
    and every legacy record's `wifi.ssid` is the literal `<redacted>`.
    Groups key on the `mac=` component, backfill idless records through
    `netid.sh`'s own precedence (marked `synthesized`), and bridge weak
    groups into MAC groups only when gateway **and** ISP agree. Genuine
    ambiguity is left for the app's manual merge — a wrong merge silently
    corrupts a chart, a missing one is visible and fixable.
  - Every metric reports its sample count, because sparse series are the
    normal case: `gateway_rtt_ms` has 1,959 samples here and `wifi.rssi`
    has 1. A chart that omits the count presents one reading as a trend.
- **`lib/thresholds.sh`** — every numeric cutoff a rule fires on, moved out
  of inline literals. There are now two things that judge a network, and
  if they drift the app shows a green dot over a red report. A test fails
  the build on an inline cutoff in either file. It also makes W1's −75 dBm
  and G1's −70 dBm visibly distinct rather than four lines apart.
- **`public.country_iso`** in both `--json` and `--monitor`. `country` is
  the full name ("Brazil"); rendering a flag or picking a locale needs the
  ISO-3166 alpha-2, and deriving it would mean shipping a country table in
  every consumer.
- **`gui/` — netdiag.app.** SwiftUI menu-bar client, SwiftPM, macOS 14+,
  builds with Command Line Tools and no Xcode. Continuous monitoring, a
  twelve-alert engine with dwell/cooldown/auto-resolve, Swift Charts over
  the full history, per-network rename and merge, and four disclosure
  layers from a menu-bar dot to a raw-JSON viewer. `make -C gui run` is
  the dev loop; `make -C gui identity` creates the stable signing identity
  that keeps TCC grants alive across rebuilds.

### Fixed

- **`--redact` no longer corrupts the history store.** `output_run`
  appended the emitted JSON to `baseline.jsonl` *after* redaction, so
  every `--redact` run wrote a record whose `network.id` was the literal
  string `wifi:mac=[redacted]`. That id is the join key
  `helpers/baseline.py` scopes history by, so such a record can never
  match a real one: it is dead weight that also burns a slot under the
  retention cap. Eleven exist in the author's history, two written by
  v0.5.2. The comparison input, the history append and the archive now
  read an unredacted build; only the `--json` copy that actually leaves
  the machine is masked.
- **Retention no longer deletes the history it exists to keep.**
  `prune_history` ran `tail -n` over the file and discarded the head. At
  the launchd watcher's 96 runs/day the 2000-line cap is about three
  weeks, and the lines it dropped were always the oldest — the only ones a
  multi-month chart is made of. The head now rolls into
  `baseline-archive.jsonl`, appended *before* the truncate so a crash
  between the two duplicates records rather than losing them.
  `--history` reads both and dedupes; `baseline.py` still reads only the
  live file, so per-run cost stays bounded.

### Notes

- The monitor is paused with **`SIGUSR1`** and resumed with `SIGUSR2`,
  handled in-process. `SIGSTOP` from the parent — the obvious mechanism,
  and what the plan specified — is actively unsafe here: POSIX delivers
  `SIGHUP`+`SIGCONT` to a process group that becomes newly orphaned while
  any member is stopped, and a stopped monitor still has live children
  (the 2 s gateway ping, `with_timeout`'s killer subshells). Measured
  under the GUI, the monitor died 2.1 s into every pause — exactly one
  ping probe — and the app then restarted it *during the scan the pause
  existed to protect*. It never reproduced from a terminal, because a
  controlling terminal keeps the group non-orphaned, which is precisely
  how it would have shipped.
- **`--monitor` exits when the process that started it goes away.** Found
  the same way: `SIGKILL` the app and the monitor was still probing 30 s
  later, re-parented to launchd with nobody reading it. Relying on `EPIPE`
  from a closed stdout is not enough, because a pipe fd survives in ways
  the child cannot audit, so the parent is now checked each cycle with
  `kill -0` — a builtin, and the only thing that works, since bash
  captures `$PPID` once at startup and still reports a dead pid after
  re-parenting. An unbounded network probe with no reader is the single
  most likely reason an always-on tool gets uninstalled, and it is
  invisible: nothing in the UI can show a process the app has forgotten.

## [0.6.1] - 2026-08-11

### Fixed

- **`--quick` is back inside its 8 s budget: 10.6 s → 3.8 s.** A single
  `traceroute6` in `lib/ipv6.sh` accounted for 7.4 s of that 10.6 — 70% of
  the wall clock of the mode whose entire purpose is a fast "is it up?"
  answer. It now only runs outside `--quick`. What it produces,
  `IPV6_TRACE_HOPS`, feeds **no diagnosis rule**: it reaches the JSON and
  one `info` line that default compact output doesn't print. `--quick`
  leaves it empty, which renders as JSON `null` — "not measured", never a
  fabricated `0`. Full runs are unaffected and still report the hop count.
  - `parallel_batch` under `--quick` drops from 7.9 s to 1.1 s. The batch
    is bounded by its slowest member, and `ipv6_run` was that member by a
    factor of twelve; the other three surviving checks total 0.6 s.
- **`traceroute6` is now bounded by `with_timeout` in every mode**, not
  just skipped in the fast one. It was the only probe in the module with
  no wall-clock bound — `ping6`, `dig` and `nc` are all capped — and at
  `-m 12` hops × `-w 2` s it is a 24 s worst case on a path that
  black-holes IPv6. An unbounded probe that can silently dominate a run is
  the same shape as the `ping -t` bug fixed in 0.6.0. A test now asserts
  every probe in the module carries a bound.

## [0.6.0] - 2026-08-11

netdiag could measure internet-side packet loss but could not diagnose it.
`INET_LOSS` had been recorded, written to JSON, and used to colour a
Report-card row since v0.4.0 — and no rule ever read it. Because
`ok()`/`warn()`/`bad()` are pure printers and only `add_diag` moves
`MAX_SEVERITY`, a connection dropping 40% of its packets printed a red
"Latency" row directly above the words "Nothing obviously wrong — your
network looks healthy" and exited 0.

That is the exact failure users describe as "the internet is down":
everything technically works, nothing finishes. `P1`/`P2` could not cover
it, because they require the public reach check to have *failed*, and
under heavy-but-partial loss `curl` still succeeds — TCP simply
retransmits its way through.

### Added

- **`L1` — severe internet-side packet loss is now a critical.** Fires
  when both public targets exceed 20% loss while the gateway is clean,
  pointing past the user's own equipment to the line, modem, or ISP.
- **`L2` — moderate internet-side loss (10–19%) is a warning.**
- **`G3` — gateway loss of 10–19% is a warning.** `G1`/`G2` start at 20%,
  and nothing covered the band beneath them, so 15% loss to the user's own
  router also exited 0.
- **`ICMP-1` — total loss to both targets while TCP and curl work** is
  reported as upstream ping filtering, not an outage, and suppresses
  `L1`/`L2`. Real 100% loss would have taken curl with it.
- **A second, independent loss target (8.8.8.8).** `L1` escalates to
  critical only when both it and 1.1.1.1 agree; one lossy target and one
  clean one is far more likely to be that anycast operator's ICMP policy
  than a fault on the line. JSON gains `internet_latency.target_alt`,
  `.rtt_avg_ms_alt`, and `.loss_pct_alt`.
- **A "Packet loss" row on the Report card**, showing both targets.
- **`VPN-1` now actually fires.** `docs/DIAGNOSIS-RULES.md` and the README
  had both promised the rule since v0.1.0 while `lib/vpn.sh` only printed
  a section line — no `add_diag` call existed anywhere, so an active VPN
  never reached the Diagnosis section. It is `info` severity, so it cannot
  change the exit code; the point is to stop users blaming their router
  for the tunnel's latency.
- **A one-line install.** `curl -fsSL .../install.sh | bash` now works.
  `install.sh` previously symlinked `$REPO_ROOT/bin/netdiag`, so it only
  ran inside an existing clone and could not be piped from curl at all.
  It now detects that it has no checkout to point at, fetches one into
  `~/.local/share/netdiag`, and `git pull`s it on re-run. Run from inside
  a clone it uses that clone and never touches the network. Adds
  `--uninstall`, and creates the `--prefix` directory instead of failing
  with a bare `ln: No such file or directory`.
- **`docs/JSON-SCHEMA.md`** documenting every top-level key of `--json`
  as actually emitted, the `null` (didn't run) vs `[]` (ran, found
  nothing) convention, and the `dhcp.dns_servers` string-not-array wart.
- **`CONTRIBUTING.md`.**
- **CI smoke tests** — a real `netdiag --json` run whose exit status and
  JSON shape are checked, and an install/uninstall round-trip.

### Changed

- **The speed test runs by default.** "Is my internet slow?" is the
  question most runs are opened to settle, and answering it with "not
  tested (run with `--speed`)" made the default report useless for it.
  `--no-speed` opts out; `--quick` skips it; an explicit `--speed` still
  forces it under `--quick`.
  - This makes a default run substantially slower — measured at ~95 s on
    this machine, of which the speed test alone is ~58 s. Use `--no-speed`
    (~35 s) when the run needs to be quick. `CLAUDE.md`'s stated budget has
    been updated to match rather than left as an aspiration.
- **The speed test now runs last, after the Report card and the diagnoses
  have already printed.** It is the most expensive phase by a wide margin,
  and nothing in the diagnosis stage reads its result — only the JSON
  emitter does, and that still runs afterwards, so `--json` and the log
  are unchanged. Previously the user watched a spinner for a minute before
  seeing anything at all, including when the answer was "your router is
  dropping packets" and they could have acted on it immediately. The
  Report card's Speed row says "measuring now — result prints below" while
  it is pending. The test still cannot be parallelised: it saturates the
  link deliberately and would corrupt every latency, loss, and bufferbloat
  number it overlapped, so last is the only safe place for it.
- **Loss probes send 20 packets instead of 8**, putting the reportable
  quantum at 5% so the new thresholds land on a whole number of dropped
  packets. At 8 packets one drop was 12.5% and no threshold below that
  was expressible at all.
- **`internet_ping_run` no longer runs in the parallel batch.** Measuring
  loss while DNS, TCP, NTP, the WiFi scan and two WAN probes compete for
  the same interface measures the tool, not the network. It now runs
  serially on a quiet link, before the bufferbloat probe saturates it.
- **Loss thresholds are shared constants** (`LOSS_WARN_PCT`,
  `LOSS_CRIT_PCT`) used by both the rules and the Report card, so a
  coloured row always has a matching diagnosis beneath it. The Router row
  previously went yellow at 1% while the lowest gateway rule fired at 20%.

### Fixed

- **`ping -t` was corrupting every loss measurement.** On macOS, `-t` is a
  deadline for the *whole run*, not a per-packet TTL — which is what
  `-c 8 -t 2` looks like it means. `ping -c 20 -i 0.2 -t 2` transmitted
  **10** packets, silently discarding half the probe; `ping -c 20 -i 0.1
  -t 2` reported a permanent **5.0% loss** because the final reply landed
  after the deadline. Removing the flag gives 20/20 and 0.0% on both
  targets in every trial. Both loss probes now bound themselves with
  `with_timeout`, which cannot corrupt the measurement, and a test greps
  for the flag's return.
- **The speed test never ran on machines with only `speedtest-cli`.** The
  Python package installs a `speedtest` shim alongside `speedtest-cli`, and
  the code took `command -v speedtest` to mean Ookla's CLI, handing it
  `--format=json --accept-license --accept-gdpr`, which it rejects. The
  fallback sat in an `elif` on that same test, so it was unreachable:
  those machines reported "test ran but returned no result" every time.
  Detection now reads the `--version` banner instead of trusting the
  filename. Latent while the test was opt-in; a guaranteed failure on
  every run once it wasn't.
- **`add_diag` reported failure when adding a second diagnosis of the same
  severity.** Its `case` arms are `[ … ] && assign`, so the guard
  evaluating false became the function's exit status. Harmless under
  `bin/netdiag`'s `set -u`, but any `set -e` caller aborted mid-rule-set
  and silently truncated the diagnosis list.
- **`P1`/`P2` required the gateway to show *exactly* zero loss.** An
  outage measured alongside, say, 8% gateway loss matched neither them nor
  `G1`/`G2`, so a total loss of internet produced no diagnosis at all. The
  guard is now "the router is not the problem" rather than "the router is
  flawless", and distinguishes a clean gateway from an unmeasured one.
- **`.github/workflows/shellcheck.yml`** no longer carries a stale
  `nimbalyst-local` entry in `ignore_paths`, left over from another
  project.
- **README no longer documents output the tool doesn't produce.** The
  sample-output block showed a `── Diagnosis ──` section and wording
  retired in v0.4.0; it now quotes the real Report card. The Roadmap
  still listed the v0.3.0 module refactor as upcoming work. The rule
  list was missing `N1`, `N1b`, `DI-2`, `WAN-1b`, `NAT-1b` and `BL-1`,
  and listed `UP-1` without noting it is deliberately never emitted.
- **`examples/sample-output.{txt,json}`** regenerated from real
  `--redact` runs; the previous pair predated the current output format.

### Removed

- **`netdiag-prompt.md`**, the original build spec. Its JSON schema moved
  to `docs/JSON-SCHEMA.md` (rewritten against what the emitter actually
  produces — the spec's copy had drifted, e.g. `ping6_loss_pct` vs the
  real `ping_loss_pct`, and predated the `wan`, `hosts_file`, `timings`
  and `network` keys). Its acceptance criteria moved into `CLAUDE.md`.
  Still in git history.

## [0.5.2] - 2026-08-11

Fixes found by running netdiag against a live dual-stack network. All three
share a shape: a measurement silently failed, and the failure was rendered
as a confident statement about the user's network instead of as missing
data. Two of them told the user something untrue about their own setup.

### Fixed

- **The progress line no longer flickers between two captions.**
  `_progress_spinner_pid` holds exactly one pid, so starting a spinner
  while one was already running overwrote the only handle on the old one.
  It was never killed and kept repainting its own label every 100 ms, so
  the terminal alternated between "Public reachability" and the live
  section at 10 Hz for the rest of the run. `hdr` stopped the previous
  spinner, but the two direct `progress_spin_start` callers in
  `bin/netdiag` did not. `progress_spin_start` is now idempotent.
- **A finished run no longer strands a spinner on your terminal.** Because
  nothing tracked the orphan, it outlived the orchestrator and went on
  writing over the shell prompt; three such processes were found still
  running from earlier sessions. `progress_spin_stop` now also runs from
  the `EXIT` trap, so Ctrl-C and early aborts clean up too.
- **DH-2 no longer accuses you of a DNS override you never made.** On any
  network with IPv6 router adverts, macOS puts the router's link-local at
  `nameserver[0]` and the DHCP-handed IPv4 server at `nameserver[1]`. The
  check compared only `nameserver[0]`, and compared it against DHCPv4
  option 6, which cannot carry IPv6 addresses — so it reported "somebody
  manually overrode it" while the router's own DNS was in use the whole
  time. It now compares the full resolver list, ignores link-local entries
  (which are router-advertised and cannot be set by hand), and matches
  whole addresses: `grep -F` also meant a system resolver of
  `192.168.15.1` "matched" a DHCP list of `192.168.15.10`, hiding a real
  override. Same fix in the `DNS` section warning.
- **IPv6 is no longer reported as broken on every machine that has it.**
  macOS `ping6`'s `-W` is a boolean in the `[-DdfHmnNoqrRtvwW]` cluster —
  it selects the old 03-draft node-information format, it is not a
  timeout. `-W 2000` made `ping6` read `2000` as the hostname, so it
  exited with "nodename nor servname provided" before sending a packet;
  `2>/dev/null` hid the message and the empty result was defaulted to
  100% loss. Every IPv6-capable run therefore raised V6-1 and a warning
  Report row, with the self-contradicting evidence "loss 100%, AAAA OK,
  TCP6 OK". `with_timeout` now supplies the bound, and an unparseable
  result is recorded as unknown rather than as total loss.

### Added

- `tests/test_regressions.bats` — 19 guards covering all three bugs,
  including the spinner-lifecycle invariant, whole-address override
  matching, and a `ping6` flag check that runs against loopback so it
  needs no network.

## [0.5.1] - 2026-08-11

Fixes found by running every CLI mode on a live network. Three of the four
share a root cause: focused runs skip most modules, and the consumers
could not tell an untouched global default from a real measurement.

### Fixed

- **`--wifi-only` no longer reports a false critical and exits 2.** On a
  perfectly healthy connection it printed "Your Mac has a router but
  nothing on the public internet responded" and returned exit 2. Rule N1b
  keyed off `PUBLIC_OK`, but `--wifi-only` never runs `public_run`, so the
  `PUBLIC_OK=0` default from `lib/globals.sh` read as a measured failure.
  The rule now also requires `PUBLIC_CHECKED=1`. Since exit 2 is the
  machine-readable "something is critically wrong" contract, this misfired
  on every scripted `--wifi-only` caller.
- **N1b names the flag you actually passed.** Its text hardcoded
  "without --mtu-only" even when the active focus was `--wifi-only`.
- **`--mtu-only` no longer calls a WiFi link "wired".** The Report card
  treated `IS_WIFI != 1` as wired, but `--mtu-only` never runs `wifi_run`,
  so the flag never left its `0` default. The medium is now omitted when
  it was not measured. `--json` was already correct (`interface.type`).
- **`--redact` no longer leaks the gateway MAC.** `IPV6_GATEWAY` was left
  intact in both the human output and `.ipv6.gateway`, but a `fe80::`
  address is EUI-64-derived from the router's MAC — so a redacted report
  still published the same `GW_MAC` masked one field over. Added to the
  redaction set in `lib/common.sh` and `helpers/emit_json.py`.
- **shellcheck passes again.** `_netdiag_on_exit` carries a
  `disable=SC2317` for its trap-only dispatch; shellcheck 0.11.0 reports
  that case as SC2329 instead, so `ludeeus/action-shellcheck@master`
  (which tracks latest) failed on every push. Both codes are now listed.

### Known

- A full run measured 36 s against the spec's 30 s budget and `--quick`
  8.9 s against 8 s, on a link with ~76 ms RTT to the internet. How much
  is script overhead versus link latency is not yet separated — needs a
  re-measure on a low-latency connection before it is treated as a
  regression.

## [0.5.0] - 2026-08-07

Second correctness pass, plus the instrumentation needed to check the
spec's runtime budget. Clears the remaining known bugs from the v0.4.1
review.

### Fixed

- **Baseline history is now scoped per network.** `baseline.jsonl` was one
  flat stream across every network the machine had ever been on, so a
  laptop moving between home, office and a café tripped "gateway RTT ×4
  spike", "ISP changed", "WiFi channel changed" and "path MTU changed" on
  essentially every location change — each an `add_diag warn` that bumped
  the exit code to 1. Runs are now compared only against prior runs on the
  same network, identified by gateway MAC → SSID → gateway IP (see
  `lib/netid.sh`). Filtering happens *before* the last-N window, so a batch
  of runs elsewhere can't push a network's own history out of range.
  Pre-0.5.0 records have no identity and are skipped rather than pooled in.
- **`~/net-diag/` is bounded.** Nothing pruned it before: the launchd
  watcher adds 96 log files and 96 JSONL records a day, forever, and both
  Python helpers parsed the entire JSONL on every run. Now capped at the
  newest 200 logs and 2000 history records, overridable via
  `NETDIAG_KEEP_LOGS` / `NETDIAG_KEEP_HISTORY` (`0` disables).
- **Traceroute hop numbers are traceroute's own again.** The parser
  counted replies, so every hop after a `* * *` timeout was renumbered and
  the JSON disagreed with what the user sees running traceroute by hand.
  Worse, closing the gap made two private hops separated by a timeout look
  adjacent, which could fake a double-NAT. Non-responding hops now keep
  their slot and surface as `ip: null, responded: false`.
- **The PMTU probe retries.** One probe per size meant a single dropped
  packet at 1472 reported a clamped MTU — and rule M1 escalates a sub-1400
  result to *critical*. Now three packets per size (`ping` exits 0 on any
  reply), which is also faster in the worst case than the old single-probe
  walk down the whole ladder.

### Added

- **`--redact`** masks public IP, SSID, BSSID, IPv6 address, gateway MAC
  and city on stdout and in `--json`, so a report can be pasted into a
  forum or ticket. ASN and ISP are kept (they name a provider, not a
  person); RFC1918 addresses are kept (blanking them would gut the NAT and
  ARP sections). Masking is substring-based, so a value is caught even
  where a diagnosis sentence interpolated it. The on-disk log keeps full
  detail — it's local, and only what you share gets masked. Implies
  compact output: section bodies stream out before every value that needs
  masking has been discovered, and a partially redacted transcript is
  worse than none because it looks safe.
- **Timing instrumentation.** The spec's "≤ 30 s full, ≤ 8 s `--quick`"
  was asserted but never measured. Every phase is now wrapped in
  `run_timed`; the JSON gains a `timings` object (`total_s`, `budget_s`,
  `over_budget`, per-phase breakdown) and `--expert` prints a Timing
  section.
- **Rule IDs on every diagnosis.** `add_diag` now takes the rule ID (`W1`,
  `NAT-1`, `BL-1`, …) matching a heading in `docs/DIAGNOSIS-RULES.md`. It
  rides into the JSON as `diagnosis[].rule` so output is greppable and
  groupable instead of string-matched against prose that gets rewritten
  for readability. `--expert` prefixes each diagnosis with `[RULE]`;
  default output stays prose-only.
- `network` (`id`, `label`) and `interface.gateway_mac` in the JSON;
  `baseline.network_id` and `baseline.skipped_other_networks`.
- **39 tests, including the first coverage of `helpers/*.py`** —
  `emit_json.py` is the widest interface in the project and had none, so a
  renamed global silently produced `null` and nothing noticed. Covers the
  JSON's top-level shape, rule-ID parsing (with the pre-0.5 fallback and a
  summary containing `|`), hop gaps, the NAT split, timings, redaction,
  and every branch of the baseline network scoping.

### Changed

- JSON shape (additive except as noted): `diagnosis[]` entries gain
  `rule`; hop entries gain `responded` and report `ip: null` instead of an
  empty string for a non-responding hop; new `network` and `timings`
  objects.
- `_print_diagnosis_paragraph` takes a rule ID as its second argument.

## [0.4.1] - 2026-08-07

Correctness pass. No new checks — this fixes cases where netdiag reported
something confidently wrong, and closes three gaps against the spec in
`netdiag-prompt.md`.

### Fixed

- **A Mac with no network reported "healthy" and exited 0.** Every
  diagnosis rule guards on a measurement that only exists once there's a
  link (`[ -n "$GW_LOSS" ]` and friends), so with WiFi off *nothing* fired
  and the run ended with "Nothing obviously wrong — your network looks
  healthy". New rule **N1** fires on an empty default route, states the
  obvious, and makes the exit code 2. See `docs/DIAGNOSIS-RULES.md`.
- **`sntp` drift was parsed positionally.** `awk '{print $1}'` assumed the
  offset led the result line, but ntp 4.2.8 — what macOS ships — prefixes
  it with a timestamp. On that format netdiag reported a clock "off by
  2026-08-07 seconds" (the date, compared as a *string*, silently passed
  the `> 1` threshold). The field is now located by the `+/-` token, and
  validated numeric before use.
- **Double-NAT contradicted itself on ISP transit.** Carriers routinely
  run 10/8 between the CPE and their edge. The chain walker counted those
  hops, so the Report card showed a yellow "double-NAT detected" directly
  above a diagnosis explaining it wasn't a problem. The home/ISP split now
  happens in `wan_double_nat_run`, before the card is built:
  `WAN_DOUBLE_NAT` means *home-side* double-NAT, and ISP transit gets a
  neutral row.
- **Usage errors exited 2**, colliding with "≥ 1 critical diagnosis". An
  unknown flag, a second positional TARGET, or a bare `--log` now exit 3.
  An `EXIT` trap also remaps unplanned aborts (a `set -u` violation exits
  1 or 127 depending on the failure) to 3, so exit 1 always means
  "warnings only" and never "the script broke".
- **`--quick` ran the baseline diff**, contrary to acceptance criterion 3.
  It cost two `python3` starts plus a full parse of `baseline.jsonl` — the
  most expensive thing left in a quick run. The comparison is now skipped;
  the snapshot is still appended, so the `--quick`-driven launchd watcher
  keeps building history.
- The Report card's DNS row and rule **D1** both keyed off `DNS_OK`, which
  defaults to 0 — a run that skipped DNS reported lookups as failing when
  none were attempted. Both now require evidence the check ran.
- `traceroute` output was piped `| log_pipe | sed`, so the log got
  un-indented text and, in compact mode, `sed` ran on empty input. The
  indent now precedes the log stage.
- Non-numeric `wdutil` scrapes no longer reach `$((rssi - noise))` (a
  syntax error) or the `[ -ge ]` ladder ("integer expression expected").
- `install.sh --prefix` with no argument aborted on `$2` unbound under
  `set -u` instead of printing a usable message.

### Added

- **`--mtu-only`** and **`--wifi-only`**, listed in the documented CLI
  surface since v0.1 but never implemented — `netdiag --mtu-only` hit the
  unknown-flag path. Each runs one section plus its prerequisites, then
  the Report card and diagnoses over what it produced. The card filters to
  the focused section, so a partial run can't report on checks it skipped.
  Both suppress the baseline diff: a partial run isn't comparable to a
  full one, and recording it would poison the history.
- `wan.double_nat` in the JSON gains `home_chain`, `home_count`,
  `isp_transit_chain`, and `isp_transit_count`.
- `is_numeric` in `lib/common.sh` — the guard to use before feeding a
  scraped value to `[ -lt ]`, `$(( ))`, or an awk comparison.
- 24 tests: the `sntp` formats (both), `is_numeric`, the home/ISP chain
  split, the N1 floor case, and the exit-code contract.

### Changed

- shellcheck is clean at default severity again. The 11 pre-existing
  `SC2317` findings (trap handlers and the parallel-subshell function
  overrides, all reached by indirect dispatch) now carry justified
  disables, so the CI job reflects real problems.

## [0.4.0] - 2026-06-01

UX-focused release. The default report dropped from 130 lines of dense
section bodies to a ~30-line "Report card + What we found" — scannable
in a second, plain-English diagnoses underneath. `gping` is no longer
the default at-end action. `--quick` now actually meets its 8-second
spec budget (was 17 s). A live progress spinner replaces the previous
silent wait. New always-on latency / jitter / hosts-file / VPN /
internet-ping rows give the user more at-a-glance signal.

### Added

- **Compact "Report" card** by default — one column-aligned row per
  metric category (Network, Router, Internet, Latency, DNS, IPv6,
  Speed, Bufferbloat, Packet size, NAT topology, Router config, WiFi
  channel, Hosts file, VPN, Clock). Severity-sorted so warnings are at
  the top, healthy items grouped under them, neutral/skipped at the
  bottom. Dim labels keep the value column the visual anchor.
- **`What we found`** section replaces `Diagnosis`. Each diagnosis is
  rendered as a wrapped paragraph (70-col `fmt`) with a blank line
  between entries — readable instead of a wall of text.
- **`--expert` flag** restores the v0.3 verbose section-by-section
  output for power users. Default mode hides those bodies; expert
  mode shows everything plus the Report card + diagnoses.
- **`--gping` flag** + interactive prompt. gping no longer launches by
  default. Pass `--gping` to opt in, or answer the post-report
  `Launch live ping monitor? [y/N]` (5-second default-no timeout).
  The prompt is suppressed under `--quiet`, `--json`, `--watch`,
  `--watch-child`, or non-TTY stdin/stdout.
- **Progress spinner on stderr** during every section. The orchestrator
  was previously silent for 25-40 s in default mode; now each section's
  name animates while it runs (`⠋ Bufferbloat (loaded vs idle latency)…`).
  Stays out of stdout so JSON / piped consumers aren't affected.
- **Always-on internet latency probe** (`lib/internet_ping.sh`). 8-packet
  burst to 1.1.1.1, captures avg RTT + stddev (jitter) + loss. Report
  row: `Latency · 1.1.1.1 · 14 ms · ±7.2 ms jitter`. New JSON object:
  `internet_latency.{target,rtt_avg_ms,rtt_jitter_ms,loss_pct}`.
- **Gateway jitter.** `lib/gateway.sh` parses ping's stddev too. Report
  row gains `± X ms jitter`; JSON `gateway.rtt_jitter_ms` added.
- **`/etc/hosts` sanity check** (`lib/hosts.sh`). Counts non-default
  entries and flags any that redirect well-known consumer domains
  (facebook / google / netflix / amazon / apple / microsoft / github /
  …) to 127.0.0.1 / 0.0.0.0 / ::1 — usually an ad-blocker or
  parental-control tool, occasionally malware. New JSON object:
  `hosts_file.{custom_count,suspicious_redirects}`.
- **VPN row is now always shown.** Previously only when active.
  Defaults to `· VPN · not active`; when active, points the user at
  the Internet row for the exit-country lookup.
- **`tell()` helper** in `lib/common.sh` for "always visible" lines
  (the `netdiag` banner, "Report saved to" footer) that survive the
  new section-body gating.

### Changed

- **`--quick` now meets its 8-second budget** (was 17.6 s). Under
  `--quick`: NTP probe, internet ping, and default traceroute are
  skipped, and the gateway ping is cut from 10 to 5 packets. Side
  effect: NAT-1 (double-NAT) doesn't fire under `--quick` because it
  depends on TRACE_LINES — run without `--quick` for the NAT topology
  check.
- **`--quiet` semantics tightened.** Prints only the header + `What
  we found`. Drop the Report card too so the diagnoses are pipe-clean
  for mail / tickets.
- **Diagnosis text rewritten in plain English** across every rule
  (`lib/diagnosis.sh`, `lib/wan.sh`, `lib/output.sh` baseline-regression).
  Pattern: visible symptom first, plain cause, concrete action, with
  technical term parenthetical for power users. E.g. "Bufferbloat at
  gateway (grade D, +230 ms under load) — router lacks SQM/fq_codel.
  VOIP/Zoom will glitch under load." →
  "Your router chokes under load — whenever someone's downloading or
  uploading, Zoom / FaceTime / WhatsApp calls will glitch and games
  will lag badly (extra +230 ms delay, bufferbloat grade D). Fix:
  enable \"Smart Queue Management\" or \"QoS\" in your router's
  admin page, or replace the router with one that supports it."
- **Section ordering tweaked** to L2 → L3 → app: WiFi → Gateway →
  ARP → DHCP → Public, instead of the prior DHCP-before-Gateway order.
- **Bufferbloat / Speed / Packet size / Latency rows show "skipped"**
  under `--quick` so the Report card stays the same shape across
  modes (used to silently omit those rows).
- **NTP soft-warning tier.** Clock drift between 1 s and 30 s now
  warns instead of being silently ignored; previously only the > 30 s
  band fired any diagnosis.

### Fixed

- **mktemp template bug.** `mktemp ".../netdiag-out.XXXXXX.json"`
  doesn't substitute the X's on macOS because the suffix isn't at the
  end — the literal-named file was being created once, then every
  subsequent run failed with "File exists" and emitted no JSON.
  Dropped the `.json` suffix.
- **gping crash on non-tty stdout.** gping renders a TUI and dies
  with "Device not configured (os error 6)" when piped to `tee` or
  redirected to a file. `gping_run` now also requires `[ -t 1 ]`.
- **Long IP-pair wraps cleanly in diagnoses.** The
  `(192.168.50.1 → 192.168.1.254)` notation now breaks at the spaces
  around `→` rather than spilling past the 70-col cap (sanitization
  regex fix).
- **Hosts row no longer marooned at the end** of the Report card.
  Severity-sort places it among the other healthy items.

## [0.3.0] - 2026-05-30

The "architecture + NAT/WAN topology" release. `bin/netdiag` was a single
1238-line bash file in v0.2.x; this release splits it into 23 modules
under `lib/`, adds a parallel-launch helper so independent checks run
concurrently, introduces a `with_timeout` wrapper to keep any one probe
from blocking the whole run, and ships a new NAT / WAN topology section
covering dual-WAN, double-NAT, and UPnP/NAT-PMP status.

### Added

- **Modular layout (lib/\*.sh).** Each section is its own module with a
  documented "Reads / Writes / Entry" header. `bin/netdiag` is now a
  ~230-line orchestrator. `lib/common.sh` holds shared printing,
  diagnosis accumulator, timeout wrapper, and parallel-launch helpers;
  `lib/globals.sh` centralises every cross-module variable.
- **Parallel batch.** DNS, IPv6, TCP reach, NTP, WiFi neighborhood,
  WiFi disconnect history, dual-WAN probe, and UPnP probe now run as
  background jobs collected via a fan-in helper. Per-section stdout is
  buffered so output order stays canonical even though execution is
  concurrent. On this Starlink link the parallel batch is bound by
  `system_profiler SPAirPortDataType` (~15 s); the previously-sequential
  work that used to fill that window is now overlapped.
- **`with_timeout SECS cmd…` helper.** macOS has no `timeout(1)`; this
  is a small shell wrapper that kills the wrapped command after SECS
  and returns 124 on timeout (matches GNU `timeout`). Applied to DNS
  `dig`, TCP `nc`, `traceroute`, `mtr`, and `sntp`.
- **NAT / WAN topology section** (`lib/wan.sh`, ~215 LOC):
  - **WAN-1 / WAN-1b — dual-WAN / load-balancing probe.** Three
    parallel `curl -s https://ifconfig.co/json` requests; flags if
    they return more than one distinct ASN or more than one public IP
    within the same ASN. Surfaces "outbound is being load-balanced
    across N ISPs" as a `warn` (or single-ASN multi-IP as `info` —
    likely CGNAT round-robin).
  - **NAT-1 — double-NAT detection.** Walks the traceroute output and
    counts consecutive RFC1918 hops before the first CGNAT or public
    address. > 1 → `warn` with the chain printed. Pure parse; no extra
    network call.
  - **UP-1 — UPnP / NAT-PMP status.** Prefers Homebrew `miniupnpc`
    (`upnpc -s`); falls back to a raw SSDP M-SEARCH via `nc -u`, then a
    NAT-PMP probe to gateway:5351. Reports `enabled` / `disabled` /
    `unknown`; `info` severity (disabled is the safer default but
    games / Plex / Steam often need it).
  - **JSON schema additions** — new top-level `wan` object with
    `load_balancing.{distinct_asns,distinct_ips,active}`,
    `double_nat.{detected,rfc1918_chain}`, and
    `upnp.{state,device,url,tested_via}`. Additive only; v0.2.x
    consumers see the same other keys.
- **Bats fixtures + parser unit tests** (`tests/test_parse.bats`).
  24 tests covering `grade_bufferbloat` thresholds, traceroute
  parser (`*` skip + banner skip + renumbering), mtr first-lossy-hop
  detection, ARP duplicate detection (with synthetic `arp_dup.txt`),
  DHCP lease-end date math, PMTU computation, and the new double-NAT
  RFC1918 chain walker. Fixtures captured from this Mac
  (`tests/fixtures/{wdutil_info,ipconfig_getsummary,traceroute,arp_an,
  system_profiler}.txt`) are sanitized — MACs, SSIDs, BSSIDs replaced
  with synthetic values.
- **`tests/integration_sudo.sh`** — interactive one-shot that asks for
  sudo once, then exercises the mtr-under-sudo branch end-to-end
  (`bats` can't drive sudo so this lives outside the suite).

### Fixed

- **`traceroute -n` parser dropped hop 1.** The awk skipped NR=1
  expecting a banner, but macOS writes the "traceroute to ..." banner
  to stderr and netdiag was redirecting stderr — so NR=1 was actually
  hop 1. Now matches on `$1 == "traceroute"` so it skips the banner
  only when it's actually present. This v0.2.x bug was latent because
  no v0.2 rule walked the trace data; the new NAT-1 rule surfaced it.
- **`with_timeout` orphaned `sleep` could pin command substitution.**
  The killer subshell's `sleep` inherited stdout, so `$(with_timeout
  ...)` would block for the full timeout even after the wrapped
  command had completed. Killer subshell output now goes to /dev/null.

### Changed

- **JSON `version` is now `"0.3.0"`** (was `"0.2.0"` — the
  `emit_json.py` default).

## [0.2.1] - 2026-05-30

Bugfix release driven by a 13-test pass of v0.2.0 on a real Starlink link.
Surfaced spec violations (exit codes, JSON schema), broken budgets (full
run > 30 s, `--quick` > 8 s under `--quiet`, `--quick TARGET` > 24 s), and
a noisy WiFi-disconnect counter. All fixed; no new features.

### Fixed

- **Exit codes per spec (`0`/`1`/`2`/`3`).** Each diagnosis is now tagged
  `info` / `warn` / `critical` via a new `add_diag` helper that updates
  a `MAX_SEVERITY` global. The script `exit "$MAX_SEVERITY"` at the end.
  Previously every run exited 0 regardless.
- **JSON output now matches `netdiag-prompt.md`'s schema** — top-level
  keys in the spec's order, full `traceroute.{target,hops[]}`,
  `per_hop[]`, `mtr.{target,duration_s,hops[],first_lossy_hop}`,
  `baseline.{compared_runs,regressions[]}`, and
  `most_likely_root_cause` fields. Non-spec extras (`arp_gw_incomplete`,
  `target`, `target_ping`, target traceroute) moved under `netdiag_extras`.
- **WiFi disconnect count over-counted ~3×** because the regex caught
  `disassoc=` substrings inside airportd dictionary dumps. Tightened to
  `disassociated|deauthenticated|link[[:space:]]+down|disconnect[[:space:]]+reason|reassociating`.
- **30 s budget**: full run (parallelised per-hop fallback loop) dropped
  from 32.6 s to ~27.6 s on this Starlink link.
- **8 s `--quick` budget**: `--quick` now also gates WiFi disconnect
  history and the optional `TARGET` traceroute. `--quick` → 7.3 s;
  `--quick TARGET` → 5.5 s (was 24.4 s).
- **Diagnosis ordering** is now severity-descending (critical → warn →
  info), preserving insertion order within each tier. The first emitted
  line is surfaced as `most_likely_root_cause` in the JSON.
- **`--watch` UX**: SIGINT/SIGTERM trap prints "stopped after N
  iteration(s)" and points at the baseline file. Child invocations get
  a new internal `--watch-child` flag that suppresses the per-iteration
  "Report saved to" line.
- **Diagnosis text rendering** now matches the severity: critical fires
  red `✗`, warn fires yellow `⚠`, info fires gray `·` (was always red).
- **PMTU rule split** into critical (< 1400) vs warn (< 1500), reflecting
  the real severity gradient.

## [0.2.0] - 2026-05-30

The full 14-enhancement build out from `netdiag-prompt.md`, plus JSON
output, the continuous-monitoring trio (--watch / --summary /
--install-watcher), and a baseline-regression detector.

### Added — diagnostic checks

- **Bufferbloat** (feature 1): 10 s / 100 MB curl from
  `speed.cloudflare.com` saturates the link while
  ping samples to the gateway and `1.1.1.1` produce a Waveform/DSLReports
  A–F grade per side. Diagnoses B1 (router SQM) and B2 (ISP CPE) split
  the blame.
- **PMTU black-hole probe** (feature 2): walks DF-set ping payloads
  downward to find the largest that gets through; flags effective MTU
  < 1500 (rule M1).
- **mtr continuous loss** (feature 3): `mtr -j -c 60 -i 0.2` parsed via
  `jq` to identify the first hop with > 2 % loss (rule MT1). Falls back
  to the original per-hop loop when mtr / jq / sudo isn't available.
- **IPv6 parity** (feature 4): global v6, gateway, ping6, AAAA,
  traceroute6 hop count, TCP/443 to `ipv6.google.com`. Rule V6-1 fires
  on v6-broken-while-v4-works (Happy Eyeballs masks it).
- **VPN detection** (feature 5): `scutil --nc list`, `tailscale status`,
  default-route via utun*/wg*. Surfaced at top via rule VPN-1.
- **TCP reach panel** (feature 6): parallel `nc -G 3 -z` to a 5-host
  panel + TARGET:443; rule TCP-1 flags "ICMP filtered, TCP fine."
- **WiFi neighbourhood** (feature 7): `system_profiler
  SPAirPortDataType -detailLevel full` channel utilisation. Rule WS-1
  fires when > 3 neighbours share the current channel.
- **WiFi disconnect history** (feature 8): `log show --predicate
  'subsystem CONTAINS[c] "wifi" OR "airport"' --last 1h`; rule WD-1
  on > 3 disconnects in window.
- **Speed test** (feature 9): opt-in `--speed`. Tries Ookla `speedtest`
  first, falls back to open-source `speedtest-cli`. Both go through `jq`.
- **NTP drift** (feature 10): `sntp -t 3 time.apple.com`; rule NT-1 at
  |drift| > 30 s (TLS handshakes start failing).
- **Baseline diff** (feature 11): every run appends to
  `~/net-diag/baseline.jsonl`; current snapshot compared against the
  median of the last 10. Regressions tagged spike / drop / drift /
  change and surfaced as additional diagnoses.
- **Custom TARGET** (feature 12): `netdiag github.com` adds the host to
  DNS, TCP-reach, traceroute, and a dedicated ping.
- **Duplicate-IP / ARP** (feature 13): rule DI-1 on duplicates or
  `(incomplete)` gateway entry.
- **DHCP lease detail** (feature 14): server, lease window, time
  remaining, DHCP-handed DNS. Rules DH-1 (lease expires within 1 h)
  and DH-2 (DHCP DNS ≠ system resolver).

### Added — output and operation

- `--json` emits one schema-conformant JSON object on stdout
  (helpers/emit_json.py). Suppresses human output unless `--log PATH`
  is also passed.
- `--quiet` shows only the Diagnosis section + final report line.
- `--log PATH` overrides the default `~/net-diag/<timestamp>.log`.
- `--baseline` / `--no-baseline` control the comparison + history append.
- `--watch[=SEC]` runs every SEC seconds in the foreground.
- `--summary[=HOURS]` aggregates `baseline.jsonl` into a human report
  (helpers/summary.py).
- `--install-watcher` / `--uninstall-watcher` drop a launchd plist that
  runs netdiag every 15 min in the background.
- `--no-bufferbloat` opts out of the bandwidth-heavy probe on metered
  links.

### Added — packaging

- Requires bash 5 (Homebrew). `bin/netdiag` re-execs under
  `/opt/homebrew/bin/bash` or `/usr/local/bin/bash`, fails clean with
  install hint if neither is present. `install.sh` learns
  `brew install bash` when missing.
- Two Python helpers: `helpers/emit_json.py`, `helpers/baseline.py`,
  `helpers/summary.py`. Stock /usr/bin/python3 on macOS 14+; no extra
  packages.
- `docs/ARCHITECTURE.md` records the bash/Python split.
- `docs/DIAGNOSIS-RULES.md` documents every rule with rationale.
- `examples/sample-output.{txt,json}` captured from a live Starlink run
  (SSID/BSSID/public IP redacted).

### Changed

- Help block moved off the fragile `sed -n '2,10p'` extraction to a
  heredoc that survives future inserts above.
- Argument parser is strict about unknown `--*` flags (silently
  accepting was masking typos).

## [0.1.0] - 2026-05-30

Initial repo skeleton — the 297-line starter script wrapped in proper
repo structure, MIT licence, and GitHub Actions CI for `shellcheck`
(Ubuntu) and `bats-core` (macOS).

<!-- Every heading above resolves to a tag below. Keep them in step: a
     version with no tag has no diff a reader can follow, which is how
     0.1.0, 0.4.1, 0.5.0 and 0.9.1 ended up documented but unreachable. -->

[Unreleased]: https://github.com/godigi/netdiag/compare/v0.9.1...HEAD
[0.9.1]: https://github.com/godigi/netdiag/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/godigi/netdiag/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/godigi/netdiag/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/godigi/netdiag/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/godigi/netdiag/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/godigi/netdiag/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/godigi/netdiag/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/godigi/netdiag/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/godigi/netdiag/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/godigi/netdiag/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/godigi/netdiag/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/godigi/netdiag/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/godigi/netdiag/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/godigi/netdiag/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/godigi/netdiag/releases/tag/v0.1.0
