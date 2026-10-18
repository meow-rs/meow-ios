import Foundation
import MeowModels
import Observation

/// What one proxy carried this session, under the name the engine knows it by.
struct PolicyTraffic: Equatable, Identifiable {
    let name: String
    let totals: ByteTotals

    var id: String {
        name
    }
}

/// Surge's Statistics page: the running session's start and uptime, its
/// traffic by the kind of network it left on (the extension's snapshots),
/// and by the proxy that carried it (`GET /statistics`, polled every second
/// while the page is shown).
@MainActor
@Observable
final class StatisticsModel {
    static let pollInterval: Duration = .seconds(1)

    /// The proxies that carried traffic this session, by name. Nil for an
    /// engine that does not count per proxy, or until it first answers.
    private(set) var policies: [PolicyTraffic]?

    @ObservationIgnored private let proxyTraffic: @Sendable () async throws -> [String: ByteTotals]?

    init(proxyTraffic: @escaping @Sendable () async throws -> [String: ByteTotals]?) {
        self.proxyTraffic = proxyTraffic
    }

    convenience init(api: MeowAPI) {
        self.init(proxyTraffic: { try await api.getProxyTraffic() })
    }

    /// Polls while `connected` until cancelled; down, there is no session,
    /// and the engine is not asked.
    func run(connected: Bool) async {
        guard connected else {
            policies = nil
            return
        }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func refresh() async {
        do {
            policies = try await proxyTraffic().map(Self.byName)
        } catch {
            // A failed request keeps the last answer on screen rather than
            // dropping the section for a second.
        }
    }

    /// By name, capitals first as Surge lists them ("DIRECT" before
    /// "daniel"); a proxy that carried nothing is left out.
    static func byName(_ traffic: [String: ByteTotals]) -> [PolicyTraffic] {
        traffic
            .filter { $0.value.total > 0 }
            .map { PolicyTraffic(name: $0.key, totals: $0.value) }
            .sorted { $0.name.unicodeScalars.lexicographicallyPrecedes($1.name.unicodeScalars) }
    }

    /// The split of the session that began at `startedAt`, zero until its
    /// first snapshot: the last one of the session before outlives it.
    static func interfaces(in snapshot: TrafficSnapshot, startedAt: Date) -> InterfaceTraffic {
        guard snapshot.timestamp >= startedAt else { return InterfaceTraffic() }
        return snapshot.interfaces ?? InterfaceTraffic()
    }
}
