import Foundation
@testable import MeowIPC
import Testing

@Suite("ProxyProbeIPC wire format")
struct ProxyProbeIPCTests {
    @Test
    func `probe request is tag 0x05 followed by JSON the extension reads`() throws {
        let data = try ProxyProbeIPC.encodeProbe(
            ProxyProbeRequest(id: 42, proxy: "🇭🇰 香港 01", kind: .httpGet, arg: "https://api.ip.sb/geoip"),
        )
        #expect(data.first == 0x05)
        // PacketTunnelProvider.m reads these keys with NSJSONSerialization.
        let body = try #require(
            JSONSerialization.jsonObject(with: data.dropFirst()) as? [String: Any],
        )
        #expect((body["id"] as? NSNumber)?.int64Value == 42)
        #expect(body["proxy"] as? String == "🇭🇰 香港 01")
        #expect(body["kind"] as? String == "http-get")
        #expect(body["arg"] as? String == "https://api.ip.sb/geoip")
    }

    @Test
    func `probe request roundtrips`() throws {
        let request = ProxyProbeRequest(id: (1 << 52) - 1, proxy: "node", kind: .nat)
        let decoded = try ProxyProbeIPC.decodeProbe(ProxyProbeIPC.encodeProbe(request))
        #expect(decoded == request)
        #expect(decoded.arg.isEmpty)
    }

    @Test
    func `cancel is tag 0x06 carrying only the id`() throws {
        let data = try ProxyProbeIPC.encodeCancel(id: 7)
        #expect(data.first == 0x06)
        #expect(try ProxyProbeIPC.decodeCancel(data) == 7)
        #expect(String(data: data.dropFirst(), encoding: .utf8) == #"{"id":7}"#)
    }

    @Test
    func `kinds use the wire names meow_probe_proxy dispatches on`() {
        let wire = ProxyProbeKind.allCases.map(\.rawValue)
        #expect(wire == ["udp-latency", "http-get", "nat", "download", "upload"])
    }

    @Test
    func `tags do not collide with the other IPC channels`() throws {
        let probe = try ProxyProbeIPC.encodeProbe(ProxyProbeRequest(id: 1, proxy: "a", kind: .nat))
        let cancel = try ProxyProbeIPC.encodeCancel(id: 1)
        #expect(ProxyProbeIPC.isProbe(probe) && !ProxyProbeIPC.isCancel(probe))
        #expect(ProxyProbeIPC.isCancel(cancel) && !ProxyProbeIPC.isProbe(cancel))
        #expect(!ProxyControlIPC.isRequest(probe) && !ProxyControlIPC.isRequest(cancel))
        #expect(!DiagnosticsIPC.isUserRequest(probe) && !DiagnosticsIPC.isUserRequest(cancel))
        #expect(throws: ProxyProbeIPCError.self) { try ProxyProbeIPC.decodeProbe(cancel) }
        #expect(throws: ProxyProbeIPCError.self) { try ProxyProbeIPC.decodeCancel(probe) }
    }
}
