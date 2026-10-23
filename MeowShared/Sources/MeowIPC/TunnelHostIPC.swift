import Foundation
import MeowModels

/// The channel between the macOS app and its packet-tunnel system extension,
/// standing in for the App Group files the iOS and tvOS builds share.
///
/// A system extension runs as root, so its App Group container and
/// UserDefaults are root's, never the user's: the two processes can't see
/// each other's files. Instead the app hands the extension the active config
/// and the tunnel preferences with every start (`startOptions`) and every
/// command (`intentTag`), and pulls the extension's state, traffic and
/// REST-API credentials back on demand (`snapshotTag`), mirroring them into
/// its own container so the readers written for the App Group keep working.
///
/// Extends the `DiagnosticsIPC` (0x01-0x03), `ProxyControlIPC` (0x04) and
/// `ProxyProbeIPC` (0x05-0x06) tag range; keep the values in sync with
/// `PacketTunnelProvider.m`.
public enum TunnelHostIPC {
    /// No body. Replies a `TunnelHostSnapshot` as JSON.
    public static let snapshotTag: UInt8 = 0x07
    /// Followed by a `TunnelHostIntent` as JSON. The extension saves the
    /// config and preferences it carries before acting on the command, then
    /// replies `{}`.
    public static let intentTag: UInt8 = 0x08
    /// No body. Replies the newest part of the extension's tunnel log
    /// (`AppGroup.tunnelLogURL` and its rotation) as UTF-8 text.
    public static let logTag: UInt8 = 0x09

    /// Key under which `startOptions` carries the encoded `TunnelHostIntent`.
    public static let startOptionKey = "meowHostIntent"

    public static var snapshotRequest: Data {
        Data([snapshotTag])
    }

    public static var logRequest: Data {
        Data([logTag])
    }

    public static func encodeIntent(_ intent: TunnelHostIntent) throws -> Data {
        var data = Data([intentTag])
        try data.append(JSONEncoder().encode(intent))
        return data
    }

    public static func decodeIntent(_ data: Data) throws -> TunnelHostIntent {
        guard data.count >= 2, data[0] == intentTag else {
            throw TunnelHostIPCError.tagMismatch
        }
        return try JSONDecoder().decode(TunnelHostIntent.self, from: data.subdata(in: 1 ..< data.count))
    }

    /// The options for `startVPNTunnel(options:)`. `profileID` stays a
    /// top-level string because the provider already reads it there; the
    /// rest travels as the same JSON an intent message carries.
    public static func startOptions(for intent: TunnelHostIntent) throws -> [String: NSObject] {
        var options: [String: NSObject] = try [
            startOptionKey: JSONEncoder().encode(intent) as NSData,
        ]
        if let profileID = intent.profileID {
            options["profileID"] = profileID as NSString
        }
        return options
    }

    public static func decodeSnapshot(_ data: Data) throws -> TunnelHostSnapshot {
        let decoder = JSONDecoder()
        // The extension writes dates the way `SharedStore` reads them.
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(TunnelHostSnapshot.self, from: data)
    }
}

public enum TunnelHostIPCError: Error, Equatable {
    case tagMismatch
    case noResponse
}

/// A command for the extension plus everything it needs to act on it that
/// would otherwise sit in the shared container.
public struct TunnelHostIntent: Codable, Sendable, Equatable {
    public var command: TunnelCommand
    public var profileID: String?
    /// The active profile's YAML (`AppGroup.configURL`). Nil leaves the
    /// extension's saved copy in place.
    public var configYAML: String?
    public var preferences: TunnelHostPreferences?

    public init(
        command: TunnelCommand,
        profileID: String? = nil,
        configYAML: String? = nil,
        preferences: TunnelHostPreferences? = nil,
    ) {
        self.command = command
        self.profileID = profileID
        self.configYAML = configYAML
        self.preferences = preferences
    }
}

/// The preferences the extension reads, keyed by their `PreferenceKey` so the
/// extension can store each value under its own UserDefaults key unchanged.
public struct TunnelHostPreferences: Codable, Sendable, Equatable {
    public var mixedPort: Int
    public var logLevel: String
    public var allowLan: Bool
    public var blockHTTP3: Bool
    public var ipv6Enabled: Bool

    public init(_ prefs: Preferences) {
        mixedPort = prefs.mixedPort
        logLevel = prefs.logLevel
        allowLan = prefs.allowLan
        blockHTTP3 = prefs.blockHTTP3
        ipv6Enabled = prefs.ipv6Enabled
    }

    /// keep in sync with PreferenceKey and MWPreferences.h
    enum CodingKeys: String, CodingKey {
        case mixedPort = "com.meow.mixedPort"
        case logLevel = "com.meow.logLevel"
        case allowLan = "com.meow.allowLan"
        case blockHTTP3 = "com.meow.blockHTTP3"
        case ipv6Enabled = "com.meow.ipv6Enabled"
    }
}

/// What the extension reports for `TunnelHostIPC.snapshotTag`: the contents
/// of its `state.json`, `traffic.json` and `api-credentials.json`, each nil
/// until the extension has written it.
public struct TunnelHostSnapshot: Decodable, Sendable, Equatable {
    public var state: VpnState?
    public var traffic: TrafficSnapshot?
    public var api: APICredentials?

    public struct APICredentials: Codable, Sendable, Equatable {
        public var port: Int
        public var secret: String
    }
}

#if canImport(NetworkExtension)
    import NetworkExtension

    @MainActor
    public extension TunnelHostIPC {
        /// `sendProviderMessage` as a single async call. Throws `noResponse`
        /// when the extension replies nothing, which is also what an
        /// extension too old to know the tag sends back.
        static func send(_ message: Data, over session: NETunnelProviderSession) async throws -> Data {
            try await withCheckedThrowingContinuation { cont in
                do {
                    try session.sendProviderMessage(message) { data in
                        if let data {
                            cont.resume(returning: data)
                        } else {
                            cont.resume(throwing: TunnelHostIPCError.noResponse)
                        }
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
#endif
