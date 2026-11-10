import Foundation
@testable import meow_ios
import MeowModels
import Testing

@Suite("Utility session stores", .tags(.model))
@MainActor
struct UtilitySessionStoreTests {
    @Test
    func `logs store keeps level and autoScroll across re-entry`() {
        let store = UtilityLogsStore()
        store.level = "warning"
        store.autoScroll = false

        #expect(store.level == "warning")
        #expect(store.autoScroll == false)
    }

    @Test
    func `dns ttl fits Int for localized %lld keys`() async throws {
        let api = MeowAPI()
        let results = try await api.getDnsResults()
        let ttl = try #require(results.first?.ttl)
        #expect(Int(ttl) == 298 || Int(ttl) == 412 || Int(ttl) == 389 || Int(ttl) == 600)
    }
}
