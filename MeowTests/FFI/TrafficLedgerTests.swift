import Foundation
@testable import meow_ios
import Testing

/// The traffic ledger on the system SQLite: an engine run in this process
/// opens it under the engine home, and the Traffic page's reader reads and
/// clears it. In the bridge suite, which is serialized, as it boots the
/// engine.
extension MeowCoreBridgeTests {
    @Test
    func `an engine run opens the traffic ledger, which reads back and clears`() async throws {
        let base = URL(filePath: NSTemporaryDirectory()).appending(path: "meow-traffic-\(UUID().uuidString)")
        // Left in the simulator's tmp, as the logbook test leaves its own:
        // the ledger stays open in this process after the stop.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let config = base.appending(path: "config.yaml")
        try """
        mixed-port: 57893
        dns:
          enable: true
          listen: 127.0.0.1:57956
          enhanced-mode: fake-ip
          fake-ip-range: 28.0.0.0/8
          nameserver:
            - 119.29.29.29
        mode: rule
        proxies: []
        proxy-groups: []
        rules:
          - MATCH,DIRECT
        """.write(to: config, atomically: true, encoding: .utf8)

        meow_core_init()
        base.path(percentEncoded: false).withCString { meow_core_set_home_dir($0) }
        let zone = TimeZone.current
        meow_traffic_set_time_zone(Int32(zone.secondsFromGMT()), 0, 0)
        #expect(meow_engine_set_network_kind(MEOW_NETWORK_KIND_ETHERNET) == 0)
        meow_engine_stop()
        let rc = config.path(percentEncoded: false).withCString { meow_engine_start($0) }
        #expect(rc == 0, "engine start failed: \(String(cString: meow_core_last_error()))")
        meow_engine_stop()
        #expect(meow_engine_set_network_kind(MEOW_NETWORK_KIND_NONE) == 0)

        let home = base.appending(path: "meow")
        let traffic = home.appending(path: "traffic")
        #expect(FileManager.default.fileExists(atPath: traffic.path(percentEncoded: false)))
        let today = TrafficPeriod.today.days(at: .now, calendar: .current)
        // No flow ran, so nothing was counted.
        let report = try await TrafficLedgerReader.read(
            from: today.lowerBound,
            to: today.upperBound,
            by: .policy,
            in: home,
        )
        #expect(report.rows.isEmpty)
        try await TrafficLedgerReader.clear(in: home)
    }

    @Test
    func `a home without a traffic ledger reads as an empty report`() async throws {
        let base = URL(filePath: NSTemporaryDirectory()).appending(path: "meow-traffic-\(UUID().uuidString)")
        let report = try await TrafficLedgerReader.read(from: 20000, to: 20001, by: .network, in: base)
        #expect(report == TrafficReport())
        try await TrafficLedgerReader.clear(in: base)
    }
}
