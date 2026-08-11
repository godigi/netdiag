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
struct RunSnapshot: Decodable, Sendable {
    var version: String?
    var timestamp: String?
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
    var diagnosis: [Diagnosis] = []
    var mostLikelyRootCause: String?

    enum CodingKeys: String, CodingKey {
        case version, timestamp, network, wifi, gateway, dns, traceroute
        case bufferbloat, mtu, ipv6, vpn, speedtest, ntp, dhcp, mtr, timings
        case diagnosis
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
    }

    struct Traceroute: Decodable, Sendable {
        var target: String?
        var hops: [Hop] = []

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

        enum CodingKeys: String, CodingKey {
            case available
            case globalAddr = "global_addr"
            case pingLossPct = "ping_loss_pct"
            case aaaaOk = "aaaa_ok"
            case tcpV6Ok = "tcp_v6_ok"
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

    /// The only prose the app displays about a network fault. `summary` is
    /// rendered verbatim; `rule` is the expert layer's link into
    /// docs/DIAGNOSIS-RULES.md.
    struct Diagnosis: Decodable, Sendable, Identifiable {
        var severity: String = "info"
        var rule: String?
        var summary: String = ""
        var id: String { "\(rule ?? "?")-\(summary.prefix(24))" }

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
