import Foundation
@testable import meow_ios
import Testing

/// Paw Print on the system SQLite: an engine run in this process writes the
/// logbook under the engine home, and the page's reader reads it back. In
/// the bridge suite, which is serialized, as it boots the engine.
extension MeowCoreBridgeTests {
    @Test
    func `an engine run is recorded in the logbook and reads back`() async throws {
        let base = URL(filePath: NSTemporaryDirectory()).appending(path: "meow-logbook-\(UUID().uuidString)")
        // Left in the simulator's tmp: the logbook stays open in this process
        // after the stop, as in the PacketTunnel until it exits, and SQLite
        // flags a database removed while in use.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let config = base.appending(path: "config.yaml")
        try """
        mixed-port: 57892
        dns:
          enable: true
          listen: 127.0.0.1:57955
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
        meow_engine_stop()
        let rc = config.path(percentEncoded: false).withCString { meow_engine_start($0) }
        #expect(rc == 0, "engine start failed: \(String(cString: meow_core_last_error()))")
        meow_engine_stop()

        let page = try await LogbookReader.read(in: base.appending(path: "meow"))
        let kinds = page.entries.map(\.kind)
        #expect(kinds.first == "engine.stop", "\(kinds)")
        #expect(kinds.contains("engine.start"), "\(kinds)")
        #expect(page.entries.first?.level == .info)
        #expect(page.rev > 0)

        // The engine filters by a kind or its area.
        let starts = try await LogbookReader.read(kind: "engine.start", in: base.appending(path: "meow"))
        #expect(starts.entries.map(\.kind) == ["engine.start"])
        let runs = try await LogbookReader.read(kind: "engine", in: base.appending(path: "meow"))
        #expect(runs.entries.allSatisfy { $0.kind.hasPrefix("engine.") }, "\(runs.entries.map(\.kind))")
        #expect(runs.entries.count >= 2)
    }

    @Test
    func `a home without a logbook reads as an empty page`() async throws {
        let base = URL(filePath: NSTemporaryDirectory()).appending(path: "meow-logbook-\(UUID().uuidString)")
        let page = try await LogbookReader.read(in: base)
        #expect(page.entries.isEmpty)
        #expect(page.rev == 0)
        #expect(!page.more)
    }
}
