import Foundation
import MeowModels

/// Simulator-only mock responses for `MeowAPI`. There is no meow engine
/// running in the simulator, so every endpoint returns canned fixtures
/// instead of hitting the loopback REST API. Split out of `MeowAPI.swift`
/// to keep that file under the repo's file-length lint budget.
extension MeowAPI {
    static var usesMockTransport: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }

    static func mockProxies() -> ProxiesResponse {
        let history: [Proxy.History] = [.init(delay: 82), .init(delay: 76)]
        let singaporeHistory: [Proxy.History] = [.init(delay: 138), .init(delay: 121)]
        let westHistory: [Proxy.History] = [.init(delay: 192), .init(delay: 168)]
        let proxies: [String: Proxy] = [
            "GLOBAL": .init(
                name: "GLOBAL",
                type: "Selector",
                now: "Auto",
                all: ["Auto", "Tokyo 01", "Singapore 02", "US West 03", "DIRECT"],
                history: nil,
            ),
            "Proxy": .init(
                name: "Proxy",
                type: "Selector",
                now: "Auto",
                all: ["Auto", "Tokyo 01", "Singapore 02", "US West 03"],
                history: nil,
            ),
            "Auto": .init(
                name: "Auto",
                type: "URLTest",
                now: "Tokyo 01",
                all: ["Tokyo 01", "Singapore 02", "US West 03"],
                history: nil,
                testUrl: "https://cp.cloudflare.com/generate_204",
            ),
            "Tokyo 01": .init(name: "Tokyo 01", type: "Shadowsocks", now: nil, all: nil, history: history, udp: true),
            "Singapore 02": .init(
                name: "Singapore 02",
                type: "VLESS",
                now: nil,
                all: nil,
                history: singaporeHistory,
                udp: true,
            ),
            // No UDP relay, so its detail page shows the UDP tests as unavailable.
            "US West 03": .init(
                name: "US West 03",
                type: "Trojan",
                now: nil,
                all: nil,
                history: westHistory,
                udp: false,
            ),
            "DIRECT": .init(name: "DIRECT", type: "Direct", now: nil, all: nil, history: nil, udp: true),
        ]
        return .init(proxies: proxies)
    }

    static func mockDelay(for proxy: String) -> Int {
        switch proxy {
        case "Tokyo 01": 76
        case "Singapore 02": 121
        case "US West 03": 168
        default: 94
        }
    }

    static func mockGroupDelay(for group: String) -> [String: Int] {
        let members = mockProxies().proxies[group]?.all ?? []
        return Dictionary(uniqueKeysWithValues: members.map { ($0, mockDelay(for: $0)) })
    }

    static func mockConnections() -> ConnectionsResponse {
        .init(
            downloadTotal: 3_842_146_304,
            uploadTotal: 486_539_264,
            connections: [
                .init(
                    id: "sim-1",
                    metadata: .init(
                        network: "tcp",
                        host: "www.gstatic.com",
                        destinationPort: "443",
                        destinationIP: "142.250.72.14",
                        sourceIP: "127.0.0.1",
                        dnsMode: "normal",
                    ),
                    upload: 42496,
                    download: 384_000,
                    start: "2026-06-28T09:41:00Z",
                    chains: ["Tokyo 01", "Proxy"],
                    rule: "DOMAIN-SUFFIX",
                    rulePayload: "gstatic.com",
                ),
                .init(
                    id: "sim-2",
                    metadata: .init(
                        network: "tcp",
                        host: "github.com",
                        destinationPort: "443",
                        destinationIP: "140.82.112.4",
                        sourceIP: "127.0.0.1",
                        dnsMode: "normal",
                    ),
                    upload: 18944,
                    download: 96512,
                    start: "2026-06-28T09:41:07Z",
                    chains: ["Auto", "Proxy"],
                    // mockRules()[1]: the detail page shows "Rule #2".
                    rule: "DOMAIN-SUFFIX",
                    rulePayload: "github.com",
                ),
                mockDirectConnection(),
            ],
        )
    }

    /// A fake-IP flow dialed DIRECT: the engine reports no destination IP,
    /// so the detail page finds it in the DNS cache.
    private static func mockDirectConnection() -> Connection {
        .init(
            id: "sim-3",
            metadata: .init(
                network: "tcp",
                host: "apple.com",
                destinationPort: "443",
                destinationIP: nil,
                sourceIP: "127.0.0.1",
                dnsMode: "fake-ip",
            ),
            upload: 3072,
            download: 15360,
            start: "2026-06-28T09:41:12Z",
            chains: ["DIRECT"],
            rule: "DOMAIN-SUFFIX",
            rulePayload: "apple.com",
        )
    }

    static func mockRules() -> RulesResponse {
        .init(rules: [
            .init(type: "DOMAIN-SUFFIX", payload: "apple.com", proxy: "DIRECT"),
            .init(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "Proxy"),
            .init(type: "GEOIP", payload: "CN", proxy: "DIRECT"),
            .init(type: "MATCH", payload: "", proxy: "Proxy"),
        ])
    }

    static func mockProviders() -> ProvidersResponse {
        let proxies = mockProxies().proxies
        let providerProxies = ["Tokyo 01", "Singapore 02", "US West 03"].compactMap { proxies[$0] }
        return .init(providers: [
            "Demo": .init(
                name: "Demo",
                type: "Proxy",
                vehicleType: "HTTP",
                proxies: providerProxies,
            ),
        ])
    }

    /// Adds up to `AppIPCBridge`'s mock totals at tick 0.
    static func mockProxyTraffic() -> [String: ByteTotals] {
        [
            "DIRECT": .init(upload: 96_468_992, download: 1_073_741_824),
            "Tokyo 01": .init(upload: 343_932_928, download: 2_469_396_480),
            "Singapore 02": .init(upload: 46_137_344, download: 299_008_000),
            "REJECT": .init(),
        ]
    }

    static func mockDnsResults(search: String?) -> [DnsResult] {
        let all: [DnsResult] = [
            .init(name: "www.gstatic.com", ips: ["142.250.72.14"], fromServer: "119.29.29.29", ttl: 298),
            .init(name: "github.com", ips: ["140.82.112.4"], fromServer: "223.5.5.5", ttl: 412),
            .init(name: "api.github.com", ips: ["140.82.112.5"], fromServer: "223.5.5.5", ttl: 389),
            .init(name: "apple.com", ips: ["17.253.144.10"], fromServer: "system", ttl: 600),
        ]
        guard let search, !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    static func mockLogStream(level: String) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            let entries = [
                LogEntry(type: level, payload: "simulator mock engine ready"),
                LogEntry(type: "debug", payload: "mock controller served /proxies"),
                LogEntry(type: "info", payload: "traffic snapshot updated"),
            ]
            let task = Task {
                var index = 0
                while !Task.isCancelled {
                    continuation.yield(entries[index % entries.count])
                    index += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
