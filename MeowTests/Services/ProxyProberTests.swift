import Foundation
@testable import meow_ios
import MeowIPC
import Testing

/// `ProxyProber` over a faked extension: the answers `meow_probe_proxy`
/// gives, and the cancel it must send when the caller gives up.
@Suite("ProxyProber", .tags(.service))
struct ProxyProberTests {
    @Test
    func `reads each kind of answer`() async throws {
        let transport = FakeProxyProbeTransport([
            .udpLatency: { _ in #"{"ms":42}"# },
            .download: { _ in #"{"bytes":10000000,"ms":8000}"# },
            .upload: { _ in #"{"bytes":2500000,"ms":4000}"# },
            .nat: { _ in
                #"{"mapping":"endpoint-independent","filtering":"address-dependent","#
                    + #""mapped":"203.0.113.7:41000","server":"stun.example:3478","note":null}"#
            },
        ])
        let prober = ProxyProber(transport: transport)

        #expect(try await prober.udpLatency(proxy: "hk") == 42)
        #expect(try await prober.download(proxy: "hk").bitsPerSecond == 10_000_000)
        #expect(try await prober.upload(proxy: "hk") == Throughput(bytes: 2_500_000, millis: 4000))
        #expect(try await prober.natType(proxy: "hk") == NatType(
            mapping: .endpointIndependent,
            filtering: .addressDependent,
            mappedAddress: "203.0.113.7:41000",
            server: "stun.example:3478",
            sourceHidden: false,
        ))

        let calls = transport.calls
        #expect(calls.map(\.kind) == [.udpLatency, .download, .upload, .nat])
        #expect(calls.allSatisfy { $0.proxy == "hk" && $0.arg.isEmpty })
        #expect(Set(calls.map(\.id)).count == 4, "every probe gets its own id")
        // The extension reads ids through NSJSONSerialization, exact only below 2^53.
        #expect(calls.allSatisfy { $0.id > 0 && $0.id < 1 << 52 })
    }

    @Test
    func `a relay that hides reply sources is reported as such`() async throws {
        let prober = ProxyProber(transport: FakeProxyProbeTransport([
            .nat: { _ in
                #"{"mapping":"unknown","filtering":"unknown","mapped":"203.0.113.7:41000","#
                    + #""server":"s","note":"source-hidden"}"#
            },
        ]))
        let nat = try await prober.natType(proxy: "hk")
        #expect(nat.sourceHidden)
        #expect(nat.mapping == .unknown)
    }

    @Test
    func `an unknown behavior reads as unknown`() {
        #expect(NatBehavior(wire: "somewhere-in-between") == .unknown)
        #expect(NatBehavior(wire: nil) == .unknown)
        #expect(NatBehavior(wire: "dependent") == .dependent)
    }

    @Test
    func `an error answer throws with its code`() async {
        let prober = ProxyProber(transport: FakeProxyProbeTransport([
            .udpLatency: { _ in #"{"error":"the proxy does not relay UDP","code":"udp-unsupported"}"# },
        ]))
        await #expect(throws: ProxyProbeError(
            message: "the proxy does not relay UDP",
            code: ProxyProbeError.udpUnsupported,
        )) {
            try await prober.udpLatency(proxy: "http-only")
        }
    }

    @Test
    func `an unreadable or incomplete answer is a failure`() async {
        let garbled = ProxyProber(transport: FakeProxyProbeTransport([.download: { _ in "not json" }]))
        let error = await #expect(throws: ProxyProbeError.self) {
            try await garbled.download(proxy: "hk")
        }
        #expect(error?.code == ProxyProbeError.failed)

        let incomplete = ProxyProber(transport: FakeProxyProbeTransport([.download: { _ in #"{"bytes":1}"# }]))
        await #expect(throws: ProxyProbeError(message: "probe answer has no ms", code: ProxyProbeError.failed)) {
            try await incomplete.download(proxy: "hk")
        }
    }

    @Test
    func `cancelling the caller ends the probe in the extension`() async {
        let started = Gate()
        let transport = FakeProxyProbeTransport()
        transport.answer(.download) { [anyCancel = transport.anyCancel] _ in
            started.open()
            // Held, as the extension holds a probe, until a cancel ends it.
            await anyCancel.wait()
            return #"{"error":"cancelled","code":"cancelled"}"#
        }
        let prober = ProxyProber(transport: transport)

        let task = Task { try await prober.download(proxy: "hk") }
        await started.wait()
        task.cancel()
        _ = await task.result

        #expect(transport.cancelled == transport.calls.map(\.id))
        #expect(transport.cancelled.count == 1)
    }

    @Test
    func `the exit IP fetcher passes the URL and refuses non-2xx answers`() async throws {
        let transport = FakeProxyProbeTransport([
            .httpGet: { request in
                request.arg.contains("limited")
                    ? #"{"status":429,"body":"slow down"}"#
                    : #"{"status":200,"body":"{\"ip\":\"198.51.100.4\",\"country_code\":\"jp\"}"}"#
            },
        ])
        let prober = ProxyProber(transport: transport)
        let lookup = ExitIPLookup(
            sources: [
                ExitIPSource(url: URL(string: "https://limited.example/geoip")!, parse: parseIpSb),
                ExitIPSource(url: URL(string: "https://ok.example/geoip")!, parse: parseIpSb),
            ],
            fetcher: prober.exitIPFetcher(proxy: "jp"),
        )

        let exitIP = try await lookup.lookup()
        #expect(exitIP.ip == "198.51.100.4")
        #expect(exitIP.countryCode == "JP")
        #expect(transport.calls.map(\.arg) == ["https://limited.example/geoip", "https://ok.example/geoip"])
        #expect(transport.calls.allSatisfy { $0.kind == .httpGet && $0.proxy == "jp" })

        await #expect(throws: ExitIPLookupError(message: "limited.example returned HTTP 429")) {
            try await prober.exitIPFetcher(proxy: "jp")(URL(string: "https://limited.example/")!)
        }
        #expect(transport.cancelled.isEmpty, "nothing was cancelled")
    }

    /// The simulator runs no engine, so the page shows these canned answers;
    /// each must read back as a measurement.
    @Test
    func `the simulator mock answers every kind readably`() async throws {
        let prober = ProxyProber(transport: MockProxyProbeTransport())
        async let udp = prober.udpLatency(proxy: "Tokyo 01")
        async let nat = prober.natType(proxy: "Tokyo 01")
        async let download = prober.download(proxy: "Tokyo 01")
        async let upload = prober.upload(proxy: "Tokyo 01")
        async let exitIP = ExitIPLookup(fetcher: prober.exitIPFetcher(proxy: "Tokyo 01")).lookup()

        #expect(try await udp > 0)
        #expect(try await nat.natClass == .portRestrictedCone)
        #expect(try await download.bitsPerSecond > 0)
        #expect(try await upload.bitsPerSecond > 0)
        #expect(try await exitIP.countryCode == "JP")
    }
}
