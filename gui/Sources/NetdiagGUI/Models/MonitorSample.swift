import Foundation

/// One line of `netdiag --monitor`.
///
/// Every field is optional and every decode is lenient, for one reason: a
/// monitor sample is a *stream*, and a stream that throws on an unfamiliar
/// field stops the menu-bar indicator dead. The CLI may gain keys — it has
/// four times already — and the app must degrade to "I don't know that
/// yet" rather than to a blank icon.
///
/// Note what is *not* here: no thresholds, no severity computation, no
/// verdict strings. `status.rules` arrives pre-computed from
/// lib/monitor.sh, which reads the same lib/thresholds.sh that
/// lib/diagnosis.sh does. This type transports that decision; it never
/// makes one.
struct MonitorSample: Decodable, Sendable {
    var schema: Int?
    var version: String?
    var ts: String?
    var seq: Int?
    /// Which cadence tiers refreshed this cycle. Everything outside this
    /// list is carried over from an earlier sample — a chart drawing a
    /// point needs to know that before it plots one.
    var refreshed: [String] = []
    var link: Link = .init()
    var network: NetworkIdentity = .init()
    var vpn: VPN = .init()
    var gateway: Gateway = .init()
    var wifi: WiFi?
    var dns: DNS = .init()
    var tcp: TCP = .init()
    var publicInfo: PublicInfo = .init()
    var status: Status = .init()

    enum CodingKeys: String, CodingKey {
        case schema, version, ts, seq, refreshed, link, network, vpn
        case gateway, wifi, dns, tcp, status
        case publicInfo = "public"
    }

    struct Link: Decodable, Sendable {
        var up: Bool = false
        var interface: String?
        var type: String?
        var ip: String?
        var gateway: String?
        var gatewayMAC: String?
        var ssid: String?
        var bssid: String?

        enum CodingKeys: String, CodingKey {
            case up, interface, type, ip, gateway, ssid, bssid
            case gatewayMAC = "gateway_mac"
        }

        var isWiFi: Bool { type == "wifi" }
    }

    struct NetworkIdentity: Decodable, Sendable, Equatable {
        var id: String?
        var label: String?
    }

    struct VPN: Decodable, Sendable {
        var active: Bool = false
        var type: String?
        var name: String?
    }

    struct Gateway: Decodable, Sendable {
        /// `nil` is "not measured this cycle", never zero. The whole
        /// null-vs-0 discipline in docs/JSON-SCHEMA.md exists because
        /// treating the first as the second produced false criticals.
        var lossPct: Double?
        var rttAvgMs: Double?

        enum CodingKeys: String, CodingKey {
            case lossPct = "loss_pct"
            case rttAvgMs = "rtt_avg_ms"
        }
    }

    struct WiFi: Decodable, Sendable {
        var rssi: Int?
        var noise: Int?
        var snr: Int?
        var channel: String?
    }

    struct DNS: Decodable, Sendable {
        /// Three-valued on purpose: `nil` means the medium tier has not
        /// run yet this session.
        var ok: Bool?
        var resolver: String?
        var elapsedMs: Double?

        enum CodingKeys: String, CodingKey {
            case ok, resolver
            case elapsedMs = "elapsed_ms"
        }
    }

    struct TCP: Decodable, Sendable {
        var anyOk: Bool?
        var targets: [Target] = []

        enum CodingKeys: String, CodingKey {
            case targets
            case anyOk = "any_ok"
        }

        struct Target: Decodable, Sendable {
            var host: String?
            var port: Int?
            var ok: Bool = false
            var elapsedMs: Double?

            enum CodingKeys: String, CodingKey {
                case host, port, ok
                case elapsedMs = "elapsed_ms"
            }
        }
    }

    struct PublicInfo: Decodable, Sendable, Equatable {
        var ok: Bool?
        var ip: String?
        var isp: String?
        var asn: String?
        var city: String?
        /// Full country name ("Brazil"). `countryISO` is the alpha-2 the
        /// flag rendering needs; both come from the CLI so nothing here
        /// has to ship a country table.
        var country: String?
        var countryISO: String?
        var captivePortal: Bool?

        enum CodingKeys: String, CodingKey {
            case ok, ip, isp, asn, city, country
            case countryISO = "country_iso"
            case captivePortal = "captive_portal"
        }
    }

    struct Status: Decodable, Sendable {
        var severity: String = "ok"
        /// Rule IDs from docs/DIAGNOSIS-RULES.md. The app maps these to
        /// alerts and renders them in the expert layer. It never decides
        /// whether one should have fired.
        var rules: [String] = []
        /// TCP-1 holds: real connections work, only ping is being dropped.
        /// The global suppressor for every loss alert — see AlertEngine.
        var icmpFiltered: Bool = false
        var degraded: Bool = false
        var cadenceS: Int?

        enum CodingKeys: String, CodingKey {
            case severity, rules, degraded
            case icmpFiltered = "icmp_filtered"
            case cadenceS = "cadence_s"
        }
    }

    var timestamp: Date { ISO8601DateFormatter().date(from: ts ?? "") ?? Date() }

    var health: Health {
        guard link.up else { return .critical }
        switch status.severity {
        case "critical": return .critical
        case "warn":     return .warning
        default:         return .healthy
        }
    }
}

/// The menu-bar dot has three states. Deliberately not four: "info" is a
/// heads-up (a VPN is carrying your traffic), not a fault, and colouring it
/// differently from healthy would train the user to ignore the one colour
/// that matters.
enum Health: Sendable {
    case healthy, warning, critical

    var symbol: String {
        switch self {
        case .healthy:  return "circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .critical: return "xmark.circle.fill"
        }
    }
}
