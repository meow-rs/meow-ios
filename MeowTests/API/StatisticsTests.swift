import Foundation
@testable import meow_ios
import MeowModels
import Testing

/// Contract for `GET /statistics` (meow-rs #764), consumed by Statistics.
@Suite("MeowAPI statistics endpoint", .tags(.api))
struct StatisticsTests {
    @Test
    func `the engine's per-proxy traffic decodes`() throws {
        let json = """
        {"uploadTotal": 3, "downloadTotal": 30, "proxies": {
            "DIRECT": {"upload": 1, "download": 10},
            "daniel": {"upload": 2, "download": 20}
        }}
        """
        let response = try JSONDecoder().decode(StatisticsResponse.self, from: Data(json.utf8))
        #expect(response.proxies.count == 2)
        #expect(response.proxies["daniel"] == ByteTotals(upload: 2, download: 20))
    }

    @Test
    func `mock transport answers with the proxies' traffic`() async throws {
        let traffic = try await MeowAPI().getProxyTraffic()
        #expect((traffic?["Tokyo 01"]?.total ?? 0) > 0)
        #expect(traffic?["REJECT"]?.total == 0)
    }
}
