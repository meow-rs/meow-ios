#if canImport(NetworkExtension)
    @testable import MeowIPC
    import MeowModels
    import NetworkExtension
    import Testing

    @Suite("TunnelControl status helpers")
    struct TunnelControlTests {
        @Test(arguments: [NEVPNStatus.connected, .connecting, .reasserting, .disconnecting])
        func `a live tunnel can be stopped`(status: NEVPNStatus) {
            #expect(TunnelControl.canStop(status))
        }

        /// Stopping from these produces no status notification, so callers
        /// have to repair their own state instead of waiting for one.
        @Test(arguments: [NEVPNStatus.invalid, .disconnected])
        func `no tunnel means nothing to stop`(status: NEVPNStatus) {
            #expect(!TunnelControl.canStop(status))
        }

        @Test
        func `reasserting reads as connecting`() {
            #expect(TunnelControl.stage(for: .reasserting) == .connecting)
            #expect(TunnelControl.stage(for: .invalid) == .idle)
            #expect(TunnelControl.stage(for: .disconnected) == .stopped)
        }
    }
#endif
