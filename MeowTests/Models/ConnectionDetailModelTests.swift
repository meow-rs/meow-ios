import Foundation
@testable import meow_ios
import os
import Testing

/// The connection detail page's tests, over a faked controller.
@MainActor
@Suite("ConnectionDetailModel", .tags(.model))
struct ConnectionDetailModelTests {
    /// A value the fake controller answers with, changed between polls.
    private final class Box<Value>: @unchecked Sendable {
        private let lock: OSAllocatedUnfairLock<Value>

        init(_ value: Value) {
            lock = OSAllocatedUnfairLock(uncheckedState: value)
        }

        var value: Value {
            lock.withLockUnchecked { $0 }
        }

        func set(_ value: Value) {
            lock.withLockUnchecked { $0 = value }
        }
    }

    private enum PollFailure {
        /// The controller is unreachable: the VPN is off.
        case offline
        case server
    }

    private let listed = Box<[Connection]>([])
    private let failure = Box<PollFailure?>(nil)
    private let now = Box(opened)
    private let proxiesAsked = Recorder<Bool>()
    private let geoAsked = Recorder<String>()
    private let closed = Recorder<String>()

    private func makeModel(_ connection: Connection) -> ConnectionDetailModel {
        let listed = listed
        let failure = failure
        let now = now
        let proxiesAsked = proxiesAsked
        let geoAsked = geoAsked
        let closed = closed
        return ConnectionDetailModel(
            connection: connection,
            sources: ConnectionDetailSources(
                connections: {
                    switch failure.value {
                    case .offline: throw URLError(.cannotConnectToHost)
                    case .server: throw MeowAPIError.http(status: 500)
                    case nil: return listed.value
                    }
                },
                rules: { ruleList() },
                proxies: {
                    proxiesAsked.append(true)
                    return proxyTable()
                },
                dnsCache: { host in dnsCache().filter { $0.name.localizedCaseInsensitiveContains(host) } },
                ipGeo: { ip in
                    geoAsked.append(ip)
                    return google()
                },
                close: { closed.append($0) },
            ),
            clock: { now.value },
        )
    }

    /// Runs the page's lookups and polling until `condition` holds.
    private func run(_ model: ConnectionDetailModel, until condition: () -> Bool) async -> Bool {
        let task = Task { await model.run() }
        defer { task.cancel() }
        return await eventually(condition)
    }

    // MARK: - Rule

    @Test
    func `finds the matched rule's place in the rule list`() async {
        let model = makeModel(connection())
        // Index 0 has the same type and payload but sends the flow DIRECT.
        #expect(await run(model) { model.ruleIndex == 1 })
    }

    @Test
    func `the routes no rule chose are told apart from rules`() {
        #expect(UnlistedRoute(connection(rule: "Final", payload: "")) == .final)
        #expect(UnlistedRoute(connection(rule: "Global", payload: "")) == .global)
        #expect(UnlistedRoute(connection(rule: "Direct", payload: "")) == .direct)
        #expect(UnlistedRoute(connection(rule: "MATCH", payload: "")) == nil)
    }

    @Test
    func `a rule matches on type, payload, and the policy it targets`() {
        let rules = ruleList()
        #expect(rules.indexOfMatch(connection(chains: ["REJECT"], rule: "MATCH", payload: "")) == 3)
        #expect(rules.indexOfMatch(connection(chains: ["DIRECT"])) == 0)
        // Reloaded config: the rule is gone.
        #expect(rules.indexOfMatch(connection(payload: "gitlab.com")) == nil)
        #expect(rules.indexOfMatch(connection(chains: [])) == nil)
    }

    // MARK: - Remote IP

    @Test
    func `a reported destination IP is the remote one, with where it is registered`() async {
        let model = makeModel(connection())
        #expect(await run(model) {
            model.remote == .known(ip: "140.82.112.4", fromDNSCache: false, geo: google())
        })
        #expect(geoAsked.all == ["140.82.112.4"])
    }

    @Test
    func `a host name dialed DIRECT is found in the DNS cache`() async {
        // Through a group whose pick is DIRECT.
        let model = makeModel(connection(destinationIP: nil, chains: ["DIRECT", "Domestic"]))
        #expect(await run(model) {
            model.remote == .known(ip: "140.82.112.4", fromDNSCache: true, geo: google())
        })
    }

    @Test
    func `a host name handed to a proxy is resolved by the proxy server`() async {
        let model = makeModel(connection(destinationIP: nil))
        #expect(await run(model) { model.remote == .resolvedByProxy })
        #expect(geoAsked.all.isEmpty)
    }

    @Test
    func `a rejected flow has no remote IP`() async {
        let model = makeModel(connection(destinationIP: nil, chains: ["REJECT"], rule: "MATCH", payload: ""))
        #expect(await run(model) { !proxiesAsked.all.isEmpty })
        #expect(model.remote == nil)
    }

    @Test
    func `a group's pick is followed down to a proxy`() {
        let proxies = proxyTable()
        #expect(proxies.leafType(of: "Proxy") == "Shadowsocks")
        #expect(proxies.leafType(of: "Domestic") == "Direct")
        // Load balancing has no single pick: the group stands for it.
        #expect(proxies.leafType(of: "Balance") == "LoadBalance")
        #expect(proxies.leafType(of: "Loop") == nil)
        #expect(proxies.leafType(of: "Gone") == nil)
    }

    @Test
    func `the DNS cache answers for exactly the host`() {
        let cache = dnsCache()
        #expect(cache.ip(of: "GitHub.com.") == "140.82.112.4")
        #expect(cache.ip(of: "api.github.com") == "140.82.112.5")
        // The entry with no address is skipped, and so is a mere substring.
        #expect(cache.ip(of: "empty.example") == nil)
        #expect(cache.ip(of: "hub.com") == nil)
    }

    // MARK: - Open and closed

    @Test
    func `polls keep the numbers counting, and a gone connection turns closed`() async {
        let model = makeModel(connection())
        let listedAt = opened.addingTimeInterval(5)
        listed.set([connection(upload: 500)])
        now.set(listedAt)
        await model.refresh()
        #expect(model.connection.upload == 500)
        #expect(model.active)

        listed.set([])
        now.set(listedAt.addingTimeInterval(1))
        await model.refresh()
        // `/connections` has no close time: the last poll that listed it.
        #expect(model.lastSeen == listedAt)
        #expect(!model.active)
        #expect(model.connection.upload == 500)

        now.set(listedAt.addingTimeInterval(2))
        await model.refresh()
        #expect(model.lastSeen == listedAt)
    }

    @Test
    func `an unreachable controller counts as closed until a poll lists it again`() async {
        let model = makeModel(connection())
        failure.set(.offline)
        await model.refresh()
        #expect(model.lastSeen == opened)

        failure.set(nil)
        listed.set([connection()])
        await model.refresh()
        #expect(model.active)
    }

    @Test
    func `a failed poll changes nothing`() async {
        let model = makeModel(connection())
        failure.set(.server)
        await model.refresh()
        #expect(model.active)
    }

    @Test
    func `closing shows the connection closed at once and stays closed`() async {
        let model = makeModel(connection())
        let closedAt = opened.addingTimeInterval(30)
        now.set(closedAt)
        await model.close()
        #expect(closed.all == ["c1"])
        #expect(model.lastSeen == closedAt)

        // A poll from before the close still lists it.
        listed.set([connection()])
        await model.refresh()
        #expect(!model.active)

        await model.close()
        #expect(closed.all == ["c1"])
    }

    // MARK: - Start time

    @Test
    func `the start time parses from RFC 3339 and epoch seconds`() {
        let expected = Date(timeIntervalSince1970: 1_782_639_660)
        #expect(connection(start: "2026-06-28T09:41:00Z").startDate == expected)
        #expect(connection(start: "2026-06-28T17:41:00+08:00").startDate == expected)
        let fractional = connection(start: "2026-06-28T09:41:00.250Z").startDate
        #expect(abs((fractional ?? .distantPast).timeIntervalSince(expected) - 0.25) < 0.001)
        // Older engines.
        #expect(connection(start: "1782639660").startDate == expected)
        #expect(connection(start: "").startDate == nil)
        #expect(makeModel(connection(start: "1782639660")).started == expected)
    }
}

// MARK: - Fixtures

/// When the page opened, by the model's clock.
private let opened = Date(timeIntervalSince1970: 1000)

private func google() -> IPGeo {
    IPGeo(country: "GOOGLE", asn: 15169, org: "Google LLC")
}

private func connection(
    destinationIP: String? = "140.82.112.4",
    chains: [String] = ["Tokyo 01", "Proxy"],
    rule: String = "DOMAIN-SUFFIX",
    payload: String = "github.com",
    upload: Int64 = 100,
    start: String = "2026-06-28T09:41:00Z",
) -> Connection {
    Connection(
        id: "c1",
        metadata: .init(
            network: "tcp",
            host: "github.com",
            destinationPort: "443",
            destinationIP: destinationIP,
            sourceIP: "127.0.0.1",
            dnsMode: "fake-ip",
        ),
        upload: upload,
        download: 200,
        start: start,
        chains: chains,
        rule: rule,
        rulePayload: payload,
    )
}

private func ruleList() -> [Rule] {
    [
        Rule(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "DIRECT"),
        Rule(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "Proxy"),
        Rule(type: "GEOIP", payload: "CN", proxy: "DIRECT"),
        Rule(type: "MATCH", payload: "", proxy: "REJECT"),
    ]
}

private func proxyTable() -> [String: Proxy] {
    [
        "Proxy": Proxy(name: "Proxy", type: "Selector", now: "Auto", all: nil, history: nil),
        "Auto": Proxy(name: "Auto", type: "URLTest", now: "Tokyo 01", all: nil, history: nil),
        "Tokyo 01": Proxy(name: "Tokyo 01", type: "Shadowsocks", now: nil, all: nil, history: nil),
        "Domestic": Proxy(name: "Domestic", type: "Selector", now: "DIRECT", all: nil, history: nil),
        "DIRECT": Proxy(name: "DIRECT", type: "Direct", now: nil, all: nil, history: nil),
        "REJECT": Proxy(name: "REJECT", type: "Reject", now: nil, all: nil, history: nil),
        "Balance": Proxy(name: "Balance", type: "LoadBalance", now: "", all: nil, history: nil),
        "Loop": Proxy(name: "Loop", type: "Selector", now: "Loop", all: nil, history: nil),
    ]
}

private func dnsCache() -> [DnsResult] {
    [
        DnsResult(name: "github.com", ips: ["140.82.112.4"], fromServer: "223.5.5.5", ttl: 412),
        DnsResult(name: "api.github.com", ips: ["140.82.112.5"], fromServer: "223.5.5.5", ttl: 389),
        DnsResult(name: "empty.example", ips: [], fromServer: nil, ttl: 0),
    ]
}
