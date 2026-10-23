import AppKit
import Foundation
import Observation
import os
import SystemExtensions

/// Activates the packet-tunnel system extension embedded in the app
/// (`Contents/Library/SystemExtensions`). The first activation needs the user
/// to allow it in System Settings; later launches re-submit the request so an
/// updated app replaces the running extension.
@MainActor
@Observable
final class SystemExtensionInstaller {
    enum State: Equatable {
        case unknown
        case activating
        case needsApproval
        case activated
        /// macOS only activates extensions of apps in /Applications.
        case needsRelocation
        case failed(String)
    }

    private(set) var state: State = .unknown

    private static let log = Logger(subsystem: "com.tangzixiang.meow.mac", category: "system-extension")
    private static let activatedKey = "mac.systemExtensionActivated"

    @ObservationIgnored private let delegate = RequestDelegate()
    @ObservationIgnored private var waiters: [CheckedContinuation<Bool, Never>] = []

    init() {
        delegate.owner = self
    }

    /// Re-activate at launch once the user has activated before, so an app
    /// update swaps in its own extension before the next connect.
    func activateIfPreviouslyActivated() {
        guard UserDefaults.standard.bool(forKey: Self.activatedKey) else { return }
        activate()
    }

    func activate() {
        switch state {
        case .activating, .needsApproval:
            return
        default:
            break
        }
        state = .activating
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: VpnManager.providerBundleIdentifier,
            queue: .main,
        )
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Activate if needed and wait for the outcome. While the user hasn't
    /// allowed the extension yet this keeps waiting: the request completes
    /// as soon as they do.
    func ensureActivated() async -> Bool {
        if state == .activated {
            return true
        }
        activate()
        return await withCheckedContinuation { waiters.append($0) }
    }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Delegate callbacks

    fileprivate func didNeedApproval() {
        Self.log.notice("waiting for user approval")
        state = .needsApproval
    }

    fileprivate func didFinish(_ result: OSSystemExtensionRequest.Result) {
        Self.log.notice("activation finished, result=\(result.rawValue)")
        state = .activated
        UserDefaults.standard.set(true, forKey: Self.activatedKey)
        resume(true)
    }

    fileprivate func didFail(code: Int, domain: String, message: String) {
        Self.log.error("activation failed: \(domain, privacy: .public) \(code) \(message, privacy: .public)")
        if domain == OSSystemExtensionErrorDomain,
           code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue
        {
            state = .needsRelocation
        } else {
            state = .failed(message)
        }
        resume(false)
    }

    private func resume(_ activated: Bool) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: activated)
        }
    }
}

/// The request is created with `queue: .main`, so every callback already runs
/// on the main thread.
@MainActor
private final class RequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    weak var owner: SystemExtensionInstaller?

    nonisolated func request(
        _: OSSystemExtensionRequest,
        actionForReplacingExtension _: OSSystemExtensionProperties,
        withExtension _: OSSystemExtensionProperties,
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { owner?.didNeedApproval() }
    }

    nonisolated func request(_: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated { owner?.didFinish(result) }
    }

    nonisolated func request(_: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let nsError = error as NSError
        let code = nsError.code
        let domain = nsError.domain
        let message = nsError.localizedDescription
        MainActor.assumeIsolated { owner?.didFail(code: code, domain: domain, message: message) }
    }
}
