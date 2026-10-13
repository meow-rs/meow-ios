import Foundation
@testable import meow_ios
import Testing

/// Wire-format tolerance for `GET /proxies` (issue #255 follow-up).
///
/// The engine's `history[].time` representation changed once already —
/// meow-rs serialized serde's default `SystemTime` object
/// (`{"secs_since_epoch":…,"nanos_since_epoch":…}`) before moving to the
/// upstream RFC 3339 string. When the Swift client decoded `time`, either
/// shape mismatch made the WHOLE `ProxiesResponse` throw, so proxy groups
/// silently froze with no delays after the first probe recorded history.
/// The client now decodes only `delay` and must tolerate any `time` shape.
@Suite("ProxiesResponse decoding", .tags(.api))
struct ProxiesDecodingTests {
    private func decode(historyJSON: String) throws -> ProxiesResponse {
        let json = """
        {"proxies": {"node-01": {
            "name": "node-01", "type": "Shadowsocks", "alive": true,
            "udp": true, "history": [\(historyJSON)]
        }}}
        """
        return try JSONDecoder().decode(ProxiesResponse.self, from: Data(json.utf8))
    }

    @Test
    func `history with RFC 3339 string time decodes`() throws {
        let resp = try decode(historyJSON: #"{"time": "2026-07-03T07:16:40Z", "delay": 76}"#)
        #expect(resp.proxies["node-01"]?.history?.last?.delay == 76)
    }

    @Test
    func `history with legacy SystemTime object time decodes`() throws {
        let resp = try decode(
            historyJSON: #"{"time": {"secs_since_epoch": 1751527000, "nanos_since_epoch": 12}, "delay": 321}"#,
        )
        #expect(resp.proxies["node-01"]?.history?.last?.delay == 321)
    }

    @Test
    func `history without a time field decodes`() throws {
        let resp = try decode(historyJSON: #"{"delay": 42}"#)
        #expect(resp.proxies["node-01"]?.history?.last?.delay == 42)
    }

    /// The proxy detail page shows `udp`, and tests TCP latency against the
    /// group's `testUrl`; older engines send neither.
    @Test
    func `udp and testUrl decode when present and stay nil when absent`() throws {
        let json = #"""
        {"proxies": {
            "node-01": {"name": "node-01", "type": "Trojan", "udp": false, "history": []},
            "Auto": {"name": "Auto", "type": "URLTest", "udp": true, "now": "node-01",
                     "all": ["node-01"], "testUrl": "https://cp.cloudflare.com/", "history": []},
            "old-node": {"name": "old-node", "type": "Shadowsocks", "history": []}
        }}
        """#
        let proxies = try JSONDecoder().decode(ProxiesResponse.self, from: Data(json.utf8)).proxies
        #expect(proxies["node-01"]?.udp == false)
        #expect(proxies["node-01"]?.testUrl == nil)
        #expect(proxies["Auto"]?.udp == true)
        #expect(proxies["Auto"]?.testUrl == "https://cp.cloudflare.com/")
        #expect(proxies["old-node"]?.udp == nil)
    }
}
