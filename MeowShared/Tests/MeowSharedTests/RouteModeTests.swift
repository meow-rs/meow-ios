import Foundation
@testable import MeowModels
import Testing

@Suite("RouteMode parsing and last-known mode")
struct RouteModeTests {
    @Test(arguments: RouteMode.allCases)
    func `wire value round-trips`(mode: RouteMode) {
        #expect(RouteMode(wire: mode.wire) == mode)
    }

    @Test
    func `all is sent as global`() {
        #expect(RouteMode.all.wire == "global")
        #expect(RouteMode(wire: "global") == .all)
    }

    @Test
    func `wire parsing ignores case and rejects unknown modes`() {
        #expect(RouteMode(wire: "Rule") == .rule)
        #expect(RouteMode(wire: "GLOBAL") == .all)
        #expect(RouteMode(wire: "all") == nil)
        #expect(RouteMode(wire: "script") == nil)
    }

    @Test
    func `configured mode reads the top-level mode key`() {
        let yaml = """
        mixed-port: 7890
        find-process-mode: strict
        dns:
          enhanced-mode: fake-ip
          mode: direct
        mode: global # proxy everything
        rules:
          - MATCH,DIRECT
        """
        #expect(RouteMode.configured(inYAML: yaml) == .all)
    }

    @Test
    func `configured mode tolerates quotes, case and CRLF`() {
        #expect(RouteMode.configured(inYAML: "log-level: info\r\nmode: \"Direct\"\r\n") == .direct)
        #expect(RouteMode.configured(inYAML: "mode: 'rule'") == .rule)
        #expect(RouteMode.configured(inYAML: "\u{FEFF}mode: direct\n") == .direct)
    }

    @Test
    func `configured mode defaults to rule like the engine`() {
        #expect(RouteMode.configured(inYAML: "") == .rule)
        #expect(RouteMode.configured(inYAML: "proxies: []\n") == .rule)
        #expect(RouteMode.configured(inYAML: "mode: script\n") == .rule)
    }

    @Test
    func `last-known mode round-trips through defaults`() throws {
        let suite = "route-mode-test-last-known"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        #expect(RouteMode.lastKnown(in: defaults) == nil)

        RouteMode.setLastKnown(.direct, in: defaults)
        #expect(RouteMode.lastKnown(in: defaults) == .direct)

        RouteMode.clearLastKnown(in: defaults)
        #expect(RouteMode.lastKnown(in: defaults) == nil)

        defaults.set("bogus", forKey: PreferenceKey.lastRouteMode)
        #expect(RouteMode.lastKnown(in: defaults) == nil)
    }
}
