import Foundation
@testable import MeowIPC
import MeowModels
import Testing

@Suite("TunnelHostIPC wire format")
struct TunnelHostIPCTests {
    @Test
    func `intent is tag 0x08 followed by JSON the extension reads`() throws {
        let prefs = Preferences(mixedPort: 7891, logLevel: "debug", allowLan: true, blockHTTP3: true, ipv6Enabled: true)
        let data = try TunnelHostIPC.encodeIntent(TunnelHostIntent(
            command: .reload,
            profileID: "P-1",
            configYAML: "mode: rule\n",
            preferences: TunnelHostPreferences(prefs),
        ))
        #expect(data.first == 0x08)
        // PacketTunnelProvider.m reads these keys with NSJSONSerialization and
        // stores each preference under its own key, so they must be the
        // PreferenceKey strings.
        let body = try #require(JSONSerialization.jsonObject(with: data.dropFirst()) as? [String: Any])
        #expect(body["command"] as? String == "reload")
        #expect(body["profileID"] as? String == "P-1")
        #expect(body["configYAML"] as? String == "mode: rule\n")
        let stored = try #require(body["preferences"] as? [String: Any])
        #expect(Set(stored.keys) == [
            PreferenceKey.mixedPort, PreferenceKey.logLevel, PreferenceKey.allowLan,
            PreferenceKey.blockHTTP3, PreferenceKey.ipv6Enabled,
        ])
        #expect((stored[PreferenceKey.mixedPort] as? NSNumber)?.intValue == 7891)
        #expect(stored[PreferenceKey.logLevel] as? String == "debug")
        #expect(stored[PreferenceKey.ipv6Enabled] as? Bool == true)
    }

    @Test
    func `intent roundtrips`() throws {
        let intent = TunnelHostIntent(command: .stop)
        #expect(try TunnelHostIPC.decodeIntent(TunnelHostIPC.encodeIntent(intent)) == intent)
    }

    @Test
    func `start options carry the profile id and the encoded intent`() throws {
        let intent = TunnelHostIntent(command: .start, profileID: "P-2", configYAML: "proxies: []\n")
        let options = try TunnelHostIPC.startOptions(for: intent)
        #expect(options["profileID"] as? String == "P-2")
        let encoded = try #require(options[TunnelHostIPC.startOptionKey] as? Data)
        #expect(try JSONDecoder().decode(TunnelHostIntent.self, from: encoded) == intent)
    }

    @Test
    func `snapshot decodes what the extension writes`() throws {
        // Shapes as PacketTunnelProvider.m and MWTunnelEngine.m write them.
        let json = """
        {
          "state": {"stage": "connected", "profileID": "P-3", "startedAt": 1761200000.5},
          "traffic": {"uploadBytes": 10, "downloadBytes": 20, "uploadRate": 1, "downloadRate": 2,
                      "ingressPackets": 3, "egressPackets": 4, "timestamp": 1761200001,
                      "footprintMB": 30, "heapUsedKB": 5, "heapFreeKB": 6, "tcpConns": 7, "pumpTick": 8},
          "api": {"port": 49152, "secret": "abc"}
        }
        """
        let snapshot = try TunnelHostIPC.decodeSnapshot(Data(json.utf8))
        #expect(snapshot.state?.stage == .connected)
        #expect(snapshot.state?.startedAt == Date(timeIntervalSince1970: 1_761_200_000.5))
        #expect(snapshot.traffic?.downloadBytes == 20)
        #expect(snapshot.api == .init(port: 49152, secret: "abc"))
    }

    @Test
    func `snapshot fields are optional before the first tunnel start`() throws {
        let snapshot = try TunnelHostIPC.decodeSnapshot(Data("{}".utf8))
        #expect(snapshot.state == nil)
        #expect(snapshot.traffic == nil)
        #expect(snapshot.api == nil)
    }

    @Test
    func `tags extend the existing provider message range`() {
        #expect(TunnelHostIPC.snapshotRequest == Data([0x07]))
        #expect(TunnelHostIPC.intentTag == 0x08)
        #expect(TunnelHostIPC.logRequest == Data([0x09]))
    }
}
