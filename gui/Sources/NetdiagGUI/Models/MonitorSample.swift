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
    var internet: Internet = .init()
    var wifi: WiFi?
    var dns: DNS = .init()
    var tcp: TCP = .init()
    var publicInfo: PublicInfo = .init()
    var status: Status = .init()

    /// Field-level differences from the previous sample, phrased by the
    /// CLI (schema 2+). Absent — and therefore empty — when nothing
    /// changed. `kind` is the stream's stable `id` string; `from`/`to`
    /// are nullable (rule transitions carry null on one side).
    var changes: [Change] = []

    struct Change: Decodable, Sendable, Equatable {
        var kind: String = ""
        var field: String?
        var from: String?
        var to: String?
        var summary: String = ""

        enum CodingKeys: String, CodingKey {
            case kind = "id"
            case field, from, to, summary
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, version, ts, seq, refreshed, link, network, vpn
        case gateway, internet, wifi, dns, tcp, status, changes
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

        enum CodingKeys: String, CodingKey {
            case id, label
        }
    }

    struct VPN: Decodable, Sendable {
        var active: Bool = false
        var type: String?
        var name: String?

        enum CodingKeys: String, CodingKey {
            case active, type, name
        }
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

    struct Internet: Decodable, Sendable {
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

        enum CodingKeys: String, CodingKey {
            case rssi, noise, snr, channel
        }
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
        /// SIGUSR1 suspended probing. Every measurement in such a sample is
        /// carried over from before the pause, so a chart must not plot it
        /// and an alert must not fire on it.
        var paused: Bool = false
        var cadenceS: Int?

        enum CodingKeys: String, CodingKey {
            case severity, rules, degraded, paused
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

/// Lenient, in an extension so the memberwise initializer survives — the
/// same discipline `RunSnapshot` uses, for a sharper reason. Swift's
/// synthesized decode throws `keyNotFound` rather than falling back to the
/// default written beside a property, so a netdiag one version behind on
/// any one of these keys would fail the decode of the *whole* sample and
/// stop the menu-bar indicator dead. `status.paused` is the current
/// example: it did not exist before the pause protocol.
extension MonitorSample {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.lenient(.schema)
        version = c.lenient(.version)
        ts = c.lenient(.ts)
        seq = c.lenient(.seq)
        refreshed = c.lenient(.refreshed, [])
        link = c.lenient(.link, Link())
        network = c.lenient(.network, NetworkIdentity())
        vpn = c.lenient(.vpn, VPN())
        gateway = c.lenient(.gateway, Gateway())
        internet = c.lenient(.internet, Internet())
        wifi = c.lenient(.wifi)
        dns = c.lenient(.dns, DNS())
        tcp = c.lenient(.tcp, TCP())
        publicInfo = c.lenient(.publicInfo, PublicInfo())
        status = c.lenient(.status, Status())
        changes = c.lenient(.changes, [])
    }
}

extension MonitorSample.Change {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(.kind, "")
        field = c.lenient(.field)
        from = c.lenient(.from)
        to = c.lenient(.to)
        summary = c.lenient(.summary, "")
    }
}

extension MonitorSample.Link {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        up = c.lenient(.up, false)
        interface = c.lenient(.interface)
        type = c.lenient(.type)
        ip = c.lenient(.ip)
        gateway = c.lenient(.gateway)
        gatewayMAC = c.lenient(.gatewayMAC)
        ssid = c.lenient(.ssid)
        bssid = c.lenient(.bssid)
    }
}

extension MonitorSample.NetworkIdentity {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id)
        label = c.lenient(.label)
    }
}

extension MonitorSample.VPN {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = c.lenient(.active, false)
        type = c.lenient(.type)
        name = c.lenient(.name)
    }
}

extension MonitorSample.Gateway {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lossPct = c.lenient(.lossPct)
        rttAvgMs = c.lenient(.rttAvgMs)
    }
}

extension MonitorSample.Internet {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lossPct = c.lenient(.lossPct)
        rttAvgMs = c.lenient(.rttAvgMs)
    }
}

extension MonitorSample.WiFi {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rssi = c.lenient(.rssi)
        noise = c.lenient(.noise)
        snr = c.lenient(.snr)
        channel = c.lenient(.channel)
    }
}

extension MonitorSample.DNS {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.lenient(.ok)
        resolver = c.lenient(.resolver)
        elapsedMs = c.lenient(.elapsedMs)
    }
}

extension MonitorSample.TCP.Target {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = c.lenient(.host)
        port = c.lenient(.port)
        ok = c.lenient(.ok, false)
        elapsedMs = c.lenient(.elapsedMs)
    }
}

extension MonitorSample.TCP {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anyOk = c.lenient(.anyOk)
        targets = c.lenient(.targets, [])
    }
}

extension MonitorSample.PublicInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.lenient(.ok)
        ip = c.lenient(.ip)
        isp = c.lenient(.isp)
        asn = c.lenient(.asn)
        city = c.lenient(.city)
        country = c.lenient(.country)
        countryISO = c.lenient(.countryISO)
        captivePortal = c.lenient(.captivePortal)
    }
}

extension MonitorSample.Status {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = c.lenient(.severity, "ok")
        rules = c.lenient(.rules, [])
        icmpFiltered = c.lenient(.icmpFiltered, false)
        degraded = c.lenient(.degraded, false)
        paused = c.lenient(.paused, false)
        cadenceS = c.lenient(.cadenceS)
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

    /// What VoiceOver reads for the menu-bar item. The dot carries the whole
    /// state of the app in one glyph, so it needs words as well as a colour.
    var accessibilityLabel: String {
        switch self {
        case .healthy:  return "Network healthy"
        case .warning:  return "Network warning"
        case .critical: return "Network problem"
        }
    }
}
