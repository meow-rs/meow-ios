import Foundation
@testable import meow_ios
import MeowIPC
import os

/// The tunnel extension's side of `ProxyProbeIPC`, faked: answers each probe
/// by kind, records what it was asked, and opens `anyCancel` on a cancel —
/// a held answer can wait on it, as the extension ends a probe on one.
final class FakeProxyProbeTransport: ProxyProbeTransport {
    typealias Answer = @Sendable (ProxyProbeRequest) async throws -> String

    private struct Log {
        var calls: [ProxyProbeRequest] = []
        var cancelled: [Int64] = []
    }

    private let log = OSAllocatedUnfairLock(initialState: Log())
    private let answers: OSAllocatedUnfairLock<[ProxyProbeKind: Answer]>
    let anyCancel = Gate()

    /// A kind with no answer fails its probe.
    init(_ answers: [ProxyProbeKind: Answer] = [:]) {
        self.answers = OSAllocatedUnfairLock(initialState: answers)
    }

    var calls: [ProxyProbeRequest] {
        log.withLock { $0.calls }
    }

    var cancelled: [Int64] {
        log.withLock { $0.cancelled }
    }

    func answer(_ kind: ProxyProbeKind, with answer: @escaping Answer) {
        answers.withLock { $0[kind] = answer }
    }

    func probe(_ request: ProxyProbeRequest) async throws -> Data {
        log.withLock { $0.calls.append(request) }
        guard let answer = answers.withLock({ $0[request.kind] }) else {
            return Data(#"{"error":"no answer for \#(request.kind.rawValue)","code":"failed"}"#.utf8)
        }
        return try await Data(answer(request).utf8)
    }

    func cancel(id: Int64) async {
        log.withLock { $0.cancelled.append(id) }
        anyCancel.open()
    }
}

/// A one-shot latch: `wait()` returns once `open()` has been called.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func open() {
        let waiters = state.withLock { locked in
            locked.isOpen = true
            defer { locked.waiters = [] }
            return locked.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLock { locked in
                if !locked.isOpen {
                    locked.waiters.append(waiter)
                }
                return locked.isOpen
            }
            if isOpen {
                waiter.resume()
            }
        }
    }
}

/// Appends from any thread; reads a snapshot.
final class Recorder<Element: Sendable>: Sendable {
    private let lock = OSAllocatedUnfairLock<[Element]>(initialState: [])

    func append(_ element: Element) {
        lock.withLock { $0.append(element) }
    }

    var all: [Element] {
        lock.withLock { $0 }
    }
}

/// Polls `condition` on the main actor until it holds; false if it still
/// does not after `timeout`.
@MainActor
func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
