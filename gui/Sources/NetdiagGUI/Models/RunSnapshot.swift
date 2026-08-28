import Foundation

/// One full `netdiag --json` run.
///
/// A partial decode by design: the CLI emits ~60 fields across 25 top-level
/// keys and this type names only what a view renders. Adding a key here is
/// cheap; the raw JSON is kept alongside for the expert layer's viewer, so
/// nothing is lost by not modelling it.
///
/// `diagnosis[].summary` is the app's *only* source of explanatory prose.
/// The CLI already writes it for a non-technical reader — "You're losing
/// packets between your Mac and your router even though the WiFi signal is
/// strong — the router itself is misbehaving. Try rebooting it (unplug for
/// 30 seconds, plug back in)." — and the app renders it verbatim. Nothing
/// in this target composes a sentence about a network.
///
/// Decoding is lenient throughout (see the extensions at the foot of this
/// file). This type no longer reads only the run that just finished: since
/// `--show`, it also reads records written by every netdiag going back to
/// v0.1, most of which predate half the keys named here.
struct RunSnapshot: Decodable, Sendable {
    var version: String?
    var timestamp: String?
    /// How much of the battery this run attempted — the closed set
    /// docs/JSON-SCHEMA.md documents under `run_mode`, the same field
    /// `HistoryDocument.Run.runMode` carries for a stored run's summary
    /// row. `nil` on records written before v0.9.0.
    var runMode: String?
    /// The id `--history`/`--show` addresses this run by, once it is
    /// stored. `null` in the four cases docs/JSON-SCHEMA.md's `run_id`
    /// section lists — most commonly `--redact`, or a mode that appends no
    /// record at all — so its absence on a live run is ordinary, not a
    /// sign anything failed.
    var runID: String?
    var interfaceInfo: InterfaceInfo = .init()
    var network: MonitorSample.NetworkIdentity = .init()
    var wifi: WiFi?
    var gateway: Gateway = .init()
    var internetLatency: InternetLatency = .init()
    var publicInfo: MonitorSample.PublicInfo = .init()
    var dns: [DNSCheck] = []
    var traceroute: Traceroute = .init()
    var bufferbloat: Bufferbloat = .init()
    var mtu: MTU = .init()
    var ipv6: IPv6 = .init()
    var wan: WAN = .init()
    var vpn: MonitorSample.VPN = .init()
    var tcpReach: [TCPReach] = []
    var wifiScan: WiFiScan?
    var wifiDisconnects: WiFiDisconnects?
    var speedtest: Speedtest?
    var ntp: NTP = .init()
    var duplicateIPs: [String] = []
    var dhcp: DHCP = .init()
    var mtr: MTR = .init()
    var timings: Timings = .init()
    var suitability: Suitability?
    /// netdiag's own background watcher, or `nil` when none is installed —
    /// which is most runs. Optional rather than defaulted for the reason
    /// the CLI emits `null`: a struct full of zeroes would say "installed,
    /// and everything about it is unknown", which is a different and much
    /// worse claim than "there isn't one". See ND-1.
    var watcher: Watcher?
    /// What this Mac itself was putting on the link while the path was
    /// measured, or `nil` under `--quick` and whenever the sample failed.
    /// Optional for the same reason `watcher` is: an object of zeroes
    /// would qualify every number in the report with a claim the run
    /// never established. See TR-1.
    var traffic: Traffic?
    var diagnosis: [Diagnosis] = []
    var mostLikelyRootCause: String?

    enum CodingKeys: String, CodingKey {
        case version, timestamp, network, wifi, gateway, dns, traceroute
        case bufferbloat, mtu, ipv6, wan, vpn, speedtest, ntp, dhcp, mtr, timings
        case suitability, diagnosis, watcher, traffic
        case runMode = "run_mode"
        case runID = "run_id"
        case interfaceInfo = "interface"
        case internetLatency = "internet_latency"
        case publicInfo = "public"
        case tcpReach = "tcp_reach"
        case wifiScan = "wifi_scan"
        case wifiDisconnects = "wifi_disconnects"
        case duplicateIPs = "duplicate_ips"
        case mostLikelyRootCause = "most_likely_root_cause"
    }

    struct InterfaceInfo: Decodable, Sendable {
        var name: String?
        var ip: String?
        var gateway: String?
        var gatewayMAC: String?
        var type: String?

        enum CodingKeys: String, CodingKey {
            case name, ip, gateway, type
            case gatewayMAC = "gateway_mac"
        }
    }

    struct WiFi: Decodable, Sendable {
        var ssid: String?
        var bssid: String?
        var security: String?
        var rssi: Int?
        var noise: Int?
        var snr: Int?
        var channel: String?
        var phy: String?
        var txRate: String?

        enum CodingKeys: String, CodingKey {
            case ssid, bssid, security, rssi, noise, snr, channel, phy
            case txRate = "tx_rate"
        }
    }

    struct Gateway: Decodable, Sendable {
        var ip: String?
        var lossPct: Double?
        var rttAvgMs: Double?
        var rttJitterMs: Double?

        enum CodingKeys: String, CodingKey {
            case ip
            case lossPct = "loss_pct"
            case rttAvgMs = "rtt_avg_ms"
            case rttJitterMs = "rtt_jitter_ms"
        }
    }

    struct InternetLatency: Decodable, Sendable {
        var target: String?
        var rttAvgMs: Double?
        var rttJitterMs: Double?
        var lossPct: Double?
        var targetAlt: String?
        var rttAvgMsAlt: Double?
        var lossPctAlt: Double?

        enum CodingKeys: String, CodingKey {
            case target
            case rttAvgMs = "rtt_avg_ms"
            case rttJitterMs = "rtt_jitter_ms"
            case lossPct = "loss_pct"
            case targetAlt = "target_alt"
            case rttAvgMsAlt = "rtt_avg_ms_alt"
            case lossPctAlt = "loss_pct_alt"
        }
    }

    struct DNSCheck: Decodable, Sendable, Identifiable {
        var resolver: String?
        var name: String?
        var answer: String?
        var ok: Bool = false
        var id: String { "\(resolver ?? "?")-\(name ?? "?")" }

        enum CodingKeys: String, CodingKey { case resolver, name, answer, ok }
    }

    struct Traceroute: Decodable, Sendable {
        var target: String?
        var hops: [Hop] = []

        enum CodingKeys: String, CodingKey { case target, hops }

        struct Hop: Decodable, Sendable, Identifiable {
            var n: Int?
            var ip: String?
            var responded: Bool = false
            var rttMs: Double?
            var lossPct: Double?
            var avgMs: Double?
            var id: Int { n ?? -1 }

            enum CodingKeys: String, CodingKey {
                case n, ip, responded
                case rttMs = "rtt_ms"
                case lossPct = "loss_pct"
                case avgMs = "avg_ms"
            }
        }
    }

    struct Bufferbloat: Decodable, Sendable {
        var gwDeltaMs: Double?
        var inetDeltaMs: Double?
        var gwGrade: String?
        var inetGrade: String?

        enum CodingKeys: String, CodingKey {
            case gwDeltaMs = "gw_delta_ms"
            case inetDeltaMs = "inet_delta_ms"
            case gwGrade = "gw_grade"
            case inetGrade = "inet_grade"
        }
    }

    struct MTU: Decodable, Sendable {
        var effective: Int?
        var pathSize: Int?

        enum CodingKeys: String, CodingKey {
            case effective
            case pathSize = "path_size"
        }
    }

    struct IPv6: Decodable, Sendable {
        var available: Bool = false
        var globalAddr: String?
        var pingLossPct: Double?
        var aaaaOk: Bool = false
        var tcpV6Ok: Bool = false
        /// This network carries IPv6 and has no IPv4 at all, by design
        /// rather than as a fault — see `lib/ipv6.sh`'s `ipv6_is_v6_only`
        /// and rule V6-3. Load-bearing for the report card: without it an
        /// absent IPv4 gateway reads as a total outage on a network that
        /// is working exactly as intended.
        var only: Bool = false
        /// macOS synthesised a 464XLAT address so IPv4-only apps keep
        /// working on that network.
        var clat: Bool = false

        enum CodingKeys: String, CodingKey {
            case available, only, clat
            case globalAddr = "global_addr"
            case pingLossPct = "ping_loss_pct"
            case aaaaOk = "aaaa_ok"
            case tcpV6Ok = "tcp_v6_ok"
        }
    }

    /// The `wan` block: what sits between this network and the public
    /// internet. Only the fields the report card's NAT topology row reads
    /// are modelled — the rest of the block reaches the expert panel as
    /// raw JSON, which is where the full detail belongs.
    struct WAN: Decodable, Sendable {
        var doubleNat: DoubleNAT = .init()
        var upnp: UPnP = .init()

        enum CodingKeys: String, CodingKey {
            case upnp
            case doubleNat = "double_nat"
        }

        struct DoubleNAT: Decodable, Sendable {
            var detected: Bool = false
            /// Home-side routers only. ISP-side private transit is normal
            /// carrier routing and deliberately does not count here — see
            /// `lib/wan.sh` and the NAT-1b rule.
            var homeCount: Int = 0
            var ispTransitCount: Int = 0

            enum CodingKeys: String, CodingKey {
                case detected
                case homeCount = "home_count"
                case ispTransitCount = "isp_transit_count"
            }
        }

        struct UPnP: Decodable, Sendable {
            /// "enabled" | "disabled" | "unknown".
            var state: String = "unknown"
        }
    }

    struct TCPReach: Decodable, Sendable, Identifiable {
        var host: String?
        var port: Int?
        var ok: Bool = false
        var elapsedMs: Double?
        var id: String { "\(host ?? "?"):\(port ?? 0)" }

        enum CodingKeys: String, CodingKey {
            case host, port, ok
            case elapsedMs = "elapsed_ms"
        }
    }

    struct WiFiScan: Decodable, Sendable {
        var currentChannel: String?
        var currentBand: String?
        var neighbourCount: Int?
        var currentChannelNeighbours: Int?

        enum CodingKeys: String, CodingKey {
            case currentChannel = "current_channel"
            case currentBand = "current_band"
            case neighbourCount = "neighbour_count"
            case currentChannelNeighbours = "current_channel_neighbours"
        }
    }

    struct WiFiDisconnects: Decodable, Sendable {
        var windowHours: Int?
        var count: Int?

        enum CodingKeys: String, CodingKey {
            case windowHours = "window_hours"
            case count
        }
    }

    struct Speedtest: Decodable, Sendable {
        var downMbps: Double?
        var upMbps: Double?
        var latencyMs: Double?
        var jitterMs: Double?
        var server: String?

        enum CodingKeys: String, CodingKey {
            case server
            case downMbps = "down_mbps"
            case upMbps = "up_mbps"
            case latencyMs = "latency_ms"
            case jitterMs = "jitter_ms"
        }
    }

    struct NTP: Decodable, Sendable {
        var driftSeconds: Double?
        var usingNetworkTime: String?
        var server: String?

        enum CodingKeys: String, CodingKey {
            case server
            case driftSeconds = "drift_seconds"
            case usingNetworkTime = "using_network_time"
        }
    }

    struct DHCP: Decodable, Sendable {
        var server: String?
        var leaseEnd: String?
        var timeRemainingS: Int?
        var dnsServers: String?

        enum CodingKeys: String, CodingKey {
            case server
            case leaseEnd = "lease_end"
            case timeRemainingS = "time_remaining_s"
            case dnsServers = "dns_servers"
        }
    }

    /// The launchd watcher's own state, as the CLI decided it — this type
    /// carries no logic beyond formatting, because `state` is already the
    /// verdict `lib/watchdog.sh` reached and re-deriving it from the raw
    /// fields beside it is how the app ends up contradicting the report.
    struct Watcher: Decodable, Sendable {
        /// `ok` · `stale` · `blocked` · `failing` · `never` · `pending`.
        /// A `String`, not an enum: an older or newer CLI is free to add
        /// a state, and a build that has never heard of it should show
        /// something neutral rather than fail to decode the whole run.
        var state: String?
        /// Absent under `--redact` — it is an absolute path under $HOME.
        var program: String?
        var intervalS: Int?
        var lastExit: Int?
        var lastRunAgeS: Int?
        var installedAgeS: Int?
        var pathBlocked: Bool?

        enum CodingKeys: String, CodingKey {
            case state, program
            case intervalS = "interval_s"
            case lastExit = "last_exit"
            case lastRunAgeS = "last_run_age_s"
            case installedAgeS = "installed_age_s"
            case pathBlocked = "path_blocked"
        }
    }

    /// The `traffic` object. Rates only — whether a rate is large enough
    /// to matter is TR-1's judgement, made in lib/diagnosis.sh against
    /// lib/thresholds.sh, and re-deriving it here is how the app ends up
    /// contradicting the report it links to.
    struct Traffic: Decodable, Sendable {
        var sampledS: Double?
        var downMbps: Double?
        var upMbps: Double?
        var topProcesses: [Process] = []

        enum CodingKeys: String, CodingKey {
            case sampledS = "sampled_s"
            case downMbps = "down_mbps"
            case upMbps = "up_mbps"
            case topProcesses = "top_processes"
        }

        struct Process: Decodable, Sendable, Identifiable {
            var name: String = ""
            var downMbps: Double?
            var upMbps: Double?
            var id: String { name }

            enum CodingKeys: String, CodingKey {
                case name
                case downMbps = "down_mbps"
                case upMbps = "up_mbps"
            }
        }
    }

    struct MTR: Decodable, Sendable {
        var hops: [Traceroute.Hop] = []
        var firstLossyHop: String?

        enum CodingKeys: String, CodingKey {
            case hops
            case firstLossyHop = "first_lossy_hop"
        }
    }

    struct Timings: Decodable, Sendable {
        var totalS: Double?
        var budgetS: Double?
        var overBudget: Bool = false
        var phases: [String: Double] = [:]

        enum CodingKeys: String, CodingKey {
            case phases
            case totalS = "total_s"
            case budgetS = "budget_s"
            case overBudget = "over_budget"
        }
    }

    struct Suitability: Decodable, Sendable {
        var webBrowsing: String?
        var videoCalls: String?
        var gaming: String?
        var largeDownloads: String?

        enum CodingKeys: String, CodingKey {
            case gaming
            case webBrowsing = "web_browsing"
            case videoCalls = "video_calls"
            case largeDownloads = "large_downloads"
        }
    }

    /// The only prose the app displays about a network fault. `summary` is
    /// rendered verbatim; `rule` is the expert layer's link into
    /// docs/DIAGNOSIS-RULES.md.
    struct Diagnosis: Decodable, Sendable, Identifiable {
        var severity: String = "info"
        var rule: String?
        var summary: String = ""
        var action: Action?
        var id: String { "\(rule ?? "?")-\(summary.prefix(24))" }

        enum CodingKeys: String, CodingKey { case severity, rule, summary, action }

        struct Action: Decodable, Sendable {
            var id: String
            var label: String
            var hint: String?
            var url: String?
        }

        var health: Health {
            switch severity {
            case "critical": return .critical
            case "warn":     return .warning
            default:         return .healthy
            }
        }
    }

    var worstSeverity: Health {
        if diagnosis.contains(where: { $0.severity == "critical" }) { return .critical }
        if diagnosis.contains(where: { $0.severity == "warn" }) { return .warning }
        return .healthy
    }

    var date: Date { ISO8601DateFormatter().date(from: timestamp ?? "") ?? Date() }

    /// The dropdown's "Last check" row wants the same badge a stored run's
    /// list row shows — reused via `HistoryDocument.Run.modeBadge(for:)`
    /// rather than re-switched here, so a live run and a `--show` record of
    /// the exact same run can never describe their `run_mode` two
    /// different ways.
    var modeBadge: String? { HistoryDocument.Run.modeBadge(for: runMode) }
}

// MARK: - Lenient decoding
//
// Every stored property below is read through `lenient`, so an absent key
// yields the default written beside the property rather than throwing.
// Written in extensions rather than in the type bodies on purpose: an
// initializer declared in a struct's body suppresses its memberwise
// initializer, and `= .init()` on the properties above depends on it.
//
// The `try?` in `lenient` also contains the blast radius. A single odd
// record — a hop table where a number arrived as a string — degrades that
// one field to its default instead of failing the whole check, which is
// the difference between a gap in a table and a check that will not open.

extension RunSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(.version)
        timestamp = c.lenient(.timestamp)
        runMode = c.lenient(.runMode)
        runID = c.lenient(.runID)
        interfaceInfo = c.lenient(.interfaceInfo, .init())
        network = c.lenient(.network, .init())
        wifi = c.lenient(.wifi)
        gateway = c.lenient(.gateway, .init())
        internetLatency = c.lenient(.internetLatency, .init())
        publicInfo = c.lenient(.publicInfo, .init())
        dns = c.lenient(.dns, [])
        traceroute = c.lenient(.traceroute, .init())
        bufferbloat = c.lenient(.bufferbloat, .init())
        mtu = c.lenient(.mtu, .init())
        ipv6 = c.lenient(.ipv6, .init())
        // `wan` and `suitability` were declared in CodingKeys, declared as
        // properties, and never assigned here — so both silently held their
        // defaults on every run since they were added. The NAT topology row
        // reads `s.wan.doubleNat.detected` and `s.wan.upnp.state`, which
        // meant the row could only ever appear because a *rule* fired, never
        // because the topology itself said so, and it rendered an empty
        // default when it did. A hand-written `init(from:)` has no compiler
        // check that every key is consumed; the parity test in
        // tests/test_gui_decoding.bats is that check.
        wan = c.lenient(.wan, .init())
        vpn = c.lenient(.vpn, .init())
        // `suitability` is decoded for parity, but nothing produces or
        // consumes it: no `suitability` key appears anywhere in
        // helpers/emit_json.py, lib/, or docs/JSON-SCHEMA.md, and no view
        // reads this property. It is a candidate for deletion rather than
        // a field to build on — left in place here only because removing a
        // public model type is a wider change than fixing a decode.
        suitability = c.lenient(.suitability)
        tcpReach = c.lenient(.tcpReach, [])
        wifiScan = c.lenient(.wifiScan)
        wifiDisconnects = c.lenient(.wifiDisconnects)
        speedtest = c.lenient(.speedtest)
        ntp = c.lenient(.ntp, .init())
        duplicateIPs = c.lenient(.duplicateIPs, [])
        dhcp = c.lenient(.dhcp, .init())
        mtr = c.lenient(.mtr, .init())
        timings = c.lenient(.timings, .init())
        watcher = c.lenient(.watcher)
        traffic = c.lenient(.traffic)
        diagnosis = c.lenient(.diagnosis, [])
        mostLikelyRootCause = c.lenient(.mostLikelyRootCause)
    }
}

extension RunSnapshot.DNSCheck {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolver = c.lenient(.resolver)
        name = c.lenient(.name)
        answer = c.lenient(.answer)
        ok = c.lenient(.ok, false)
    }
}

extension RunSnapshot.Traceroute {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = c.lenient(.target)
        hops = c.lenient(.hops, [])
    }
}

extension RunSnapshot.Traceroute.Hop {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = c.lenient(.n)
        ip = c.lenient(.ip)
        responded = c.lenient(.responded, false)
        rttMs = c.lenient(.rttMs)
        lossPct = c.lenient(.lossPct)
        avgMs = c.lenient(.avgMs)
    }
}

extension RunSnapshot.IPv6 {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.lenient(.available, false)
        globalAddr = c.lenient(.globalAddr)
        pingLossPct = c.lenient(.pingLossPct)
        aaaaOk = c.lenient(.aaaaOk, false)
        tcpV6Ok = c.lenient(.tcpV6Ok, false)
    }
}

extension RunSnapshot.TCPReach {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = c.lenient(.host)
        port = c.lenient(.port)
        ok = c.lenient(.ok, false)
        elapsedMs = c.lenient(.elapsedMs)
    }
}

extension RunSnapshot.MTR {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hops = c.lenient(.hops, [])
        firstLossyHop = c.lenient(.firstLossyHop)
    }
}

extension RunSnapshot.Timings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalS = c.lenient(.totalS)
        budgetS = c.lenient(.budgetS)
        overBudget = c.lenient(.overBudget, false)
        phases = c.lenient(.phases, [:])
    }
}

extension RunSnapshot.Diagnosis {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = c.lenient(.severity, "info")
        rule = c.lenient(.rule)
        summary = c.lenient(.summary, "")
    }
}

/// A completed run plus the things the process, not the JSON, tells us.
struct RunResult: Sendable {
    var snapshot: RunSnapshot
    /// Kept for the expert layer's JSON viewer and for "Copy shareable
    /// report", which must publish exactly what the CLI produced rather
    /// than a re-encode of this app's partial model.
    var rawJSON: String
    /// 0 healthy · 1 warnings · 2 critical · 3 script error.
    var exitCode: Int32
    var startedAt: Date
    var finishedAt: Date
    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}
