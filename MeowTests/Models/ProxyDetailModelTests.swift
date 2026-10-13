import Foundation
@testable import meow_ios
import MeowIPC
import Testing

/// The proxy detail page's tests, over a faked extension and controller.
@MainActor
@Suite("ProxyDetailModel", .tags(.model))
struct ProxyDetailModelTests {
    private struct TCPTest: Equatable {
        let proxy: String
        let url: String
    }

    private let transport = FakeProxyProbeTransport()
    private let described = Recorder<String>()
    private let tcpTests = Recorder<TCPTest>()

    private func makeModel(
        testURL: String? = "https://cp.cloudflare.com/",
        describeError: (any Error)? = nil,
        tcpDelay: @escaping @Sendable () async throws -> Int = { 120 },
        connected: Bool = true,
    ) async -> ProxyDetailModel {
        let described = described
        let tcpTests = tcpTests
        let model = ProxyDetailModel(
            name: "Tokyo 01",
            testURL: testURL,
            describe: { name in
                if let describeError {
                    throw describeError
                }
                described.append(name)
                return Proxy(name: name, type: "Snell", now: nil, all: nil, history: nil, udp: true)
            },
            tcpDelay: { proxy, url in
                tcpTests.append(TCPTest(proxy: proxy, url: url))
                return try await tcpDelay()
            },
            prober: ProxyProber(transport: transport),
        )
        if connected {
            await model.setConnected(true)
        }
        return model
    }

    /// The state `probe` settles in once it stops running.
    private func finished(_ model: ProxyDetailModel, _ probe: ProxyProbe) async -> ProbeState {
        #expect(await eventually { model.state(of: probe) != .running }, "\(probe) never finished")
        return model.state(of: probe)
    }

    @Test
    func `describes the proxy once connected`() async {
        let model = await makeModel(connected: false)
        #expect(model.type == nil)
        #expect(described.all.isEmpty)

        await model.setConnected(true)

        #expect(model.connected)
        #expect(model.type == "Snell")
        #expect(model.udp == true)
        #expect(described.all == ["Tokyo 01"])
    }

    @Test
    func `the TCP test probes the group URL and falls back to the default`() async {
        let model = await makeModel()
        model.test(.tcpLatency)
        #expect(await finished(model, .tcpLatency) == .done(.latency(ms: 120)))

        let selectorModel = await makeModel(testURL: nil)
        selectorModel.test(.tcpLatency)
        _ = await finished(selectorModel, .tcpLatency)

        #expect(tcpTests.all == [
            TCPTest(proxy: "Tokyo 01", url: "https://cp.cloudflare.com/"),
            TCPTest(proxy: "Tokyo 01", url: MeowAPI.delayTestURL),
        ])
    }

    @Test
    func `a TCP test that gets no answer is a timeout`() async {
        let noDelay = await makeModel(tcpDelay: { -1 })
        noDelay.test(.tcpLatency)
        #expect(await finished(noDelay, .tcpLatency) == .failed(.timedOut))

        let gatewayTimeout = await makeModel(tcpDelay: { throw MeowAPIError.http(status: 504) })
        gatewayTimeout.test(.tcpLatency)
        #expect(await finished(gatewayTimeout, .tcpLatency) == .failed(.timedOut))
    }

    @Test
    func `probes report their measurements`() async {
        transport.answer(.udpLatency) { _ in #"{"ms":35}"# }
        transport.answer(.download) { _ in #"{"bytes":50000000,"ms":4000}"# }
        transport.answer(.nat) { _ in
            #"{"mapping":"endpoint-independent","filtering":"endpoint-independent","#
                + #""mapped":"198.51.100.9:5000","server":"s","note":null}"#
        }
        transport.answer(.httpGet) { _ in
            #"{"status":200,"body":"{\"ip\":\"198.51.100.9\",\"country_code\":\"JP\",\"asn\":2516,\"isp\":\"KDDI\"}"}"#
        }
        let model = await makeModel()

        model.test(.udpLatency)
        #expect(await finished(model, .udpLatency) == .done(.latency(ms: 35)))

        model.test(.download)
        #expect(await finished(model, .download) == .done(.bandwidth(Throughput(bytes: 50_000_000, millis: 4000))))

        model.test(.nat)
        guard case let .done(.nat(nat)) = await finished(model, .nat) else {
            Issue.record("NAT test did not finish with a NAT type")
            return
        }
        #expect(nat.natClass == .fullCone)
        #expect(nat.mappedAddress == "198.51.100.9:5000")

        model.test(.exitIP)
        guard case let .done(.exit(exitIP)) = await finished(model, .exitIP) else {
            Issue.record("exit IP test did not finish with an address")
            return
        }
        #expect(exitIP.ip == "198.51.100.9")
        #expect(exitIP.countryCode == "JP")
        // The first source answered; the lookup went through the node, once.
        #expect(transport.calls.filter { $0.kind == .httpGet }.count == 1)
    }

    @Test
    func `failures are told apart`() async {
        transport.answer(.udpLatency) { _ in #"{"error":"the proxy does not relay UDP","code":"udp-unsupported"}"# }
        transport.answer(.nat) { _ in #"{"error":"no reply","code":"timeout"}"# }
        transport.answer(.upload) { _ in #"{"error":"HTTP 403","code":"failed"}"# }
        let model = await makeModel()

        model.test(.udpLatency)
        #expect(await finished(model, .udpLatency) == .failed(.udpUnsupported))
        model.test(.nat)
        #expect(await finished(model, .nat) == .failed(.timedOut))
        model.test(.upload)
        #expect(await finished(model, .upload) == .failed(.failed, detail: "HTTP 403"))
    }

    @Test
    func `an unreachable extension is a failed test, not a crash`() async {
        transport.answer(.download) { _ in
            throw ProxyProbeError(message: "the VPN is not running", code: ProxyProbeError.engineStopped)
        }
        let model = await makeModel(describeError: URLError(.cannotConnectToHost))

        model.test(.download)
        #expect(await finished(model, .download) == .failed(.failed, detail: "the VPN is not running"))
        #expect(model.type == nil, "describing failed, so the header stays blank")
    }

    @Test
    func `nothing runs until the VPN is up`() async {
        let model = await makeModel(connected: false)
        model.test(.udpLatency)
        model.test(.tcpLatency)
        #expect(model.state(of: .udpLatency) == .idle)
        #expect(model.state(of: .tcpLatency) == .idle)
        #expect(transport.calls.isEmpty)
        #expect(tcpTests.all.isEmpty)
    }

    @Test
    func `the VPN going down ends running tests in the extension too`() async {
        transport.answer(.udpLatency) { [anyCancel = transport.anyCancel] _ in
            await anyCancel.wait()
            return #"{"error":"cancelled","code":"cancelled"}"#
        }
        let model = await makeModel()
        model.test(.udpLatency)
        #expect(await eventually { !transport.calls.isEmpty })

        await model.setConnected(false)

        #expect(!model.connected)
        #expect(model.state(of: .udpLatency) == .idle)
        #expect(await eventually { !transport.cancelled.isEmpty })
        #expect(transport.cancelled == transport.calls.map(\.id))
        // The cancelled probe's late answer does not land on the row.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.state(of: .udpLatency) == .idle)
    }

    @Test
    func `leaving the page ends running tests and keeps finished ones`() async {
        transport.answer(.udpLatency) { _ in #"{"ms":35}"# }
        transport.answer(.nat) { [anyCancel = transport.anyCancel] _ in
            await anyCancel.wait()
            return #"{"error":"cancelled","code":"cancelled"}"#
        }
        let model = await makeModel()
        model.test(.udpLatency)
        _ = await finished(model, .udpLatency)
        model.test(.nat)
        #expect(await eventually { transport.calls.contains { $0.kind == .nat } })

        model.stopAll()

        #expect(model.state(of: .nat) == .idle)
        #expect(model.state(of: .udpLatency) == .done(.latency(ms: 35)))
        #expect(await eventually { transport.cancelled.count == 1 })
    }

    @Test
    func `a second tap on a running test is ignored`() async {
        let released = Gate()
        transport.answer(.download) { _ in
            await released.wait()
            return #"{"bytes":1000,"ms":1000}"#
        }
        let model = await makeModel()
        model.test(.download)
        model.test(.download)
        released.open()
        _ = await finished(model, .download)
        #expect(transport.calls.count == 1)
    }

    @Test
    func `download and upload take turns`() async throws {
        let downloadReleased = Gate()
        transport.answer(.download) { _ in
            await downloadReleased.wait()
            return #"{"bytes":1000,"ms":1000}"#
        }
        transport.answer(.upload) { _ in #"{"bytes":500,"ms":1000}"# }
        let model = await makeModel()

        model.test(.download)
        #expect(await eventually { !transport.calls.isEmpty })
        model.test(.upload)
        try await Task.sleep(for: .milliseconds(200))
        #expect(transport.calls.map(\.kind) == [.download], "upload waits for the download")
        #expect(model.state(of: .upload) == .running)

        downloadReleased.open()
        #expect(await finished(model, .upload) == .done(.bandwidth(Throughput(bytes: 500, millis: 1000))))
        #expect(transport.calls.map(\.kind) == [.download, .upload])
    }

    @Test
    func `NAT behaviours map to the classic names`() {
        func natClass(_ mapping: NatBehavior, _ filtering: NatBehavior) -> NatClass {
            NatType(mapping: mapping, filtering: filtering, mappedAddress: nil, server: nil, sourceHidden: false)
                .natClass
        }
        #expect(natClass(.endpointIndependent, .endpointIndependent) == .fullCone)
        #expect(natClass(.endpointIndependent, .addressDependent) == .restrictedCone)
        #expect(natClass(.endpointIndependent, .addressAndPortDependent) == .portRestrictedCone)
        #expect(natClass(.endpointIndependent, .unknown) == .cone)
        #expect(natClass(.addressAndPortDependent, .addressAndPortDependent) == .symmetric)
        #expect(natClass(.dependent, .unknown) == .symmetric)
        #expect(natClass(.unknown, .unknown) == .unknown)
    }

    @Test
    func `bit rates step by thousands like link speeds`() {
        #expect(BitRate.format(850) == "850 bps")
        #expect(BitRate.format(940_000) == "940 Kbps")
        #expect(BitRate.format(85_300_000) == "85.3 Mbps")
        #expect(BitRate.format(1_200_000_000) == "1.2 Gbps")
    }
}
