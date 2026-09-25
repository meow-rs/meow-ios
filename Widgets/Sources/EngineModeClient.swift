import Foundation
import MeowModels

/// The route-mode slice of the engine's loopback REST API (`/configs`) —
/// all the widgets need. The app's `MeowAPI` covers the rest of the API but
/// lives in the app target.
enum EngineModeClient {
    enum Failure: Error {
        /// No tunnel has run yet, so the engine hasn't minted credentials.
        case notRunning
        case http(status: Int)
        case unknownMode(String)
    }

    private struct Configs: Decodable {
        let mode: String
    }

    static func fetchMode() async throws -> RouteMode {
        #if targetEnvironment(simulator)
            return RouteMode.lastKnown(in: AppGroup.defaults) ?? .rule
        #else
            let (data, response) = try await URLSession.shared.data(for: request(method: "GET"))
            try check(response)
            let wire = try JSONDecoder().decode(Configs.self, from: data).mode
            guard let mode = RouteMode(wire: wire) else { throw Failure.unknownMode(wire) }
            return mode
        #endif
    }

    /// Lasts until the engine restarts, which resets to the profile's `mode:`.
    static func setMode(_ mode: RouteMode) async throws {
        #if targetEnvironment(simulator)
            return
        #else
            var req = try request(method: "PATCH")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(["mode": mode.wire])
            let (_, response) = try await URLSession.shared.data(for: req)
            try check(response)
        #endif
    }

    private static func request(method: String) throws -> URLRequest {
        guard let creds = AppGroup.apiCredentials() else { throw Failure.notRunning }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(creds.port)/configs")!)
        req.httpMethod = method
        req.timeoutInterval = 3
        req.setValue("Bearer \(creds.secret)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else { throw Failure.http(status: http.statusCode) }
    }
}
