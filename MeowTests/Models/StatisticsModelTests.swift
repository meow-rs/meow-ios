import Foundation
@testable import meow_ios
import MeowModels
import os
import Testing

/// The Statistics page's per-proxy list and interface split, over a faked
/// controller.
@MainActor
@Suite("StatisticsModel", .tags(.model))
struct StatisticsModelTests {
    /// The controller's answers: the traffic, or a failure while `failing`.
    private final class Controller: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (failing: false, requests: 0))

        var failing: Bool {
            get { state.withLock { $0.failing } }
            set { state.withLock { $0.failing = newValue } }
        }

        var requests: Int {
            state.withLock { $0.requests }
        }

        func answer(_ traffic: [String: ByteTotals]?) throws -> [String: ByteTotals]? {
            let failing = state.withLock {
                $0.requests += 1
                return $0.failing
            }
            if failing {
                throw URLError(.networkConnectionLost)
            }
            return traffic
        }
    }

    private static let traffic: [String: ByteTotals] = [
        "daniel": .init(upload: 1, download: 1),
        "DIRECT": .init(upload: 2, download: 2),
        "REJECT": .init(),
        "daniel-TW": .init(upload: 3, download: 3),
    ]

    private let controller = Controller()

    private func makeModel(traffic: [String: ByteTotals]? = Self.traffic) -> StatisticsModel {
        let controller = controller
        return StatisticsModel { try controller.answer(traffic) }
    }

    @Test
    func `lists the proxies that carried traffic, capitals first`() async {
        let model = makeModel()
        await model.refresh()
        #expect(model.policies?.map(\.name) == ["DIRECT", "daniel", "daniel-TW"])
        #expect(model.policies?.last?.totals == ByteTotals(upload: 3, download: 3))
    }

    @Test
    func `a failed request keeps the proxies last read`() async {
        let model = makeModel()
        await model.refresh()
        controller.failing = true
        await model.refresh()
        #expect(controller.requests == 2)
        #expect(model.policies?.map(\.name) == ["DIRECT", "daniel", "daniel-TW"])
    }

    @Test
    func `an engine without per-proxy traffic leaves the section out`() async {
        let model = makeModel(traffic: nil)
        await model.refresh()
        #expect(model.policies == nil)
    }

    @Test
    func `polls while connected until cancelled`() async {
        let model = makeModel()
        let polling = Task { await model.run(connected: true) }
        #expect(await eventually { controller.requests >= 2 })
        polling.cancel()
        await polling.value
        #expect(model.policies?.count == 3)
    }

    @Test
    func `with the VPN down the session is gone and the engine is not asked`() async {
        let model = makeModel()
        await model.refresh()
        await model.run(connected: false)
        #expect(model.policies == nil)
        #expect(controller.requests == 1)
    }

    @Test
    func `the interface split is the session's own`() {
        let startedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let split = InterfaceTraffic(cellular: ByteTotals(upload: 20, download: 300))
        let current = TrafficSnapshot(timestamp: startedAt.addingTimeInterval(0.5), interfaces: split)
        #expect(StatisticsModel.interfaces(in: current, startedAt: startedAt) == split)

        // The last snapshot of the session before outlives it.
        let stale = TrafficSnapshot(timestamp: startedAt.addingTimeInterval(-5), interfaces: split)
        #expect(StatisticsModel.interfaces(in: stale, startedAt: startedAt) == InterfaceTraffic())

        let unsplit = TrafficSnapshot(timestamp: startedAt.addingTimeInterval(0.5))
        #expect(StatisticsModel.interfaces(in: unsplit, startedAt: startedAt) == InterfaceTraffic())
    }
}
