import Foundation
@testable import MeowModels
import Testing

/// The traffic snapshot as the extension writes it: an `NSJSONSerialization`
/// dictionary, read back with `SharedStore`'s seconds-since-1970 dates.
@Suite("TrafficSnapshot wire format")
struct TrafficSnapshotTests {
    private static func decode(_ json: String) throws -> TrafficSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(TrafficSnapshot.self, from: Data(json.utf8))
    }

    private static let counters = """
    "uploadBytes": 120, "downloadBytes": 1300, "uploadRate": 4, "downloadRate": 40,
    "ingressPackets": 9, "egressPackets": 7, "timestamp": 1760000000.5,
    "footprintMB": 18, "heapUsedKB": 9000, "heapFreeKB": 800, "tcpConns": 3, "pumpTick": 12
    """

    @Test
    func `the interface split decodes`() throws {
        let snapshot = try Self.decode("""
        {\(Self.counters), "interfaces": {
            "wifiEthernet": {"upload": 100, "download": 1000},
            "cellular": {"upload": 20, "download": 300},
            "other": {"upload": 0, "download": 0}
        }}
        """)
        #expect(snapshot.uploadBytes == 120)
        #expect(snapshot.interfaces == InterfaceTraffic(
            wifiEthernet: ByteTotals(upload: 100, download: 1000),
            cellular: ByteTotals(upload: 20, download: 300),
        ))
        #expect(snapshot.interfaces?.cellular.total == 320)
    }

    @Test
    func `a snapshot without the split still decodes`() throws {
        let snapshot = try Self.decode("{\(Self.counters)}")
        #expect(snapshot.downloadBytes == 1300)
        #expect(snapshot.interfaces == nil)
    }
}
