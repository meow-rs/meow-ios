import Foundation
import os

/// The public address traffic leaves from, as one geo-IP service sees it.
struct ExitIP: Equatable {
    let ip: String
    /// ISO 3166-1 alpha-2, upper-case; nil when the service did not give a
    /// usable one.
    let countryCode: String?
    /// The service's own country name — English only, so only a fallback
    /// for display.
    let country: String?
    let asn: Int?
    /// The ISP, or failing that the AS organisation.
    let org: String?

    /// The country's flag.
    var flagEmoji: String? {
        countryCode.map(regionFlag)
    }

    /// The country in the UI language. The services answer in English
    /// (ipinfo.io not at all), so the system names the code; their name is
    /// the fallback for codes it does not know.
    func countryName(locale: Locale = .current) -> String? {
        guard let countryCode else { return country }
        // An unknown region can come back as the code itself.
        if let name = locale.localizedString(forRegionCode: countryCode), !name.isEmpty, name != countryCode {
            return name
        }
        return country ?? countryCode
    }

    /// `AS24940 Hetzner Online GmbH`, or whichever half is known.
    var networkLabel: String? {
        switch (asn, org) {
        case let (asn?, org?): "AS\(asn) \(org)"
        case let (asn?, nil): "AS\(asn)"
        case let (nil, org): org
        }
    }
}

/// The flag of the region an upper-case ISO 3166-1 alpha-2 `code` names,
/// from its letters' regional indicator symbols.
func regionFlag(_ code: String) -> String {
    var flag = ""
    flag.unicodeScalars.append(contentsOf: code.unicodeScalars.compactMap {
        Unicode.Scalar(0x1F1E6 + $0.value - 0x41)
    })
    return flag
}

struct ExitIPLookupError: Error, LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// A keyless geo-IP endpoint that describes the caller's own address, plus
/// the parser for its answer. Each service has its own JSON shape and its
/// own way of saying "no", so every source carries its own parser.
struct ExitIPSource: Sendable {
    let url: URL
    let parse: @Sendable ([String: Any]) throws -> ExitIP

    static let ipSb = ExitIPSource(url: URL(string: "https://api.ip.sb/geoip")!, parse: parseIpSb)
    static let ipwhoIs = ExitIPSource(url: URL(string: "https://ipwho.is/")!, parse: parseIpwhoIs)
    static let ipinfo = ExitIPSource(url: URL(string: "https://ipinfo.io/json")!, parse: parseIpinfo)
}

/// Asks public geo-IP services which address traffic leaves from, fetching
/// each through `fetcher` — on the proxy detail page, a GET through that one
/// proxy (`ProxyProber.exitIPFetcher`).
///
/// Sources are tried in order rather than raced: a race would send every
/// check to every service, and each one sees the user's address. A source
/// that refuses (rate limit, challenge page) falls through at once; the
/// whole lookup gives up after `totalTimeout` — a hang usually means the
/// route itself is down, and then every source would hang the same way.
struct ExitIPLookup: Sendable {
    static let defaultTotalTimeout: Duration = .seconds(8)

    var sources: [ExitIPSource] = [.ipSb, .ipwhoIs, .ipinfo]
    /// The body of a 2xx answer from `url`; anything else throws.
    let fetcher: @Sendable (URL) async throws -> String
    var totalTimeout: Duration = Self.defaultTotalTimeout

    /// Throws `ExitIPLookupError` when no source answered usably in time.
    func lookup() async throws -> ExitIP {
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        let found = try await withThrowingTaskGroup(of: ExitIP?.self) { group in
            group.addTask {
                for source in sources {
                    try Task.checkCancellation()
                    do {
                        return try await fetch(source)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        failures.withLock { $0.append(reason) }
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: totalTimeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let found {
            return found
        }
        let reasons = failures.withLock { $0 }
        let what = reasons.count < sources.count ? "exit IP lookup timed out" : "no exit IP source answered"
        throw ExitIPLookupError(message: reasons.isEmpty ? what : "\(what) (\(reasons.joined(separator: "; ")))")
    }

    private func fetch(_ source: ExitIPSource) async throws -> ExitIP {
        let body = try await fetcher(source.url)
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            // Not JSON at all (a Cloudflare challenge page), or not an object.
            throw ExitIPLookupError(message: "\(source.url.host() ?? "?"): unreadable answer")
        }
        return try source.parse(object)
    }
}

// MARK: - Parsers — one per source, fed the decoded body of a 2xx answer.

/// `{"ip": "…", "country_code": "FI", "country": "Finland", "asn": 24940, "isp": "…", …}`
func parseIpSb(_ json: [String: Any]) throws -> ExitIP {
    try ExitIP(
        ip: json.requireIP("api.ip.sb"),
        countryCode: countryCode(json.string("country_code")),
        country: json.string("country"),
        asn: json.int("asn"),
        org: json.string("isp") ?? json.string("asn_organization") ?? json.string("organization"),
    )
}

/// `{"ip": "…", "success": true, "country_code": "FI", "connection": {"asn": …, "isp": …}, …}`.
/// Refusals (quota, reserved range) are `"success": false` with a
/// `message`, often on HTTP 200.
func parseIpwhoIs(_ json: [String: Any]) throws -> ExitIP {
    if json.bool("success") == false {
        throw ExitIPLookupError(message: "ipwho.is refused: \(json.string("message") ?? "no reason given")")
    }
    let connection = json["connection"] as? [String: Any]
    return try ExitIP(
        ip: json.requireIP("ipwho.is"),
        countryCode: countryCode(json.string("country_code")),
        country: json.string("country"),
        asn: connection?.int("asn"),
        org: connection?.string("isp") ?? connection?.string("org"),
    )
}

/// `{"ip": "…", "country": "FI", "org": "AS24940 Hetzner Online GmbH", …}` —
/// the country is only a code, and the ASN is folded into `org`.
func parseIpinfo(_ json: [String: Any]) throws -> ExitIP {
    // A private source address: the request never reached the internet as us.
    if json.bool("bogon") == true {
        throw ExitIPLookupError(message: "ipinfo.io: bogon address")
    }
    var asn: Int?
    var org = json.string("org")
    if let match = org?.wholeMatch(of: #/AS(\d+)\s*(.*)/#) {
        asn = Int(match.1)
        org = match.2.isEmpty ? nil : String(match.2)
    }
    return try ExitIP(
        ip: json.requireIP("ipinfo.io"),
        countryCode: countryCode(json.string("country")),
        country: nil,
        asn: asn,
        org: org,
    )
}

private func countryCode(_ raw: String?) -> String? {
    guard let code = raw?.uppercased(), code.count == 2,
          code.unicodeScalars.allSatisfy({ ("A" ... "Z").contains($0) })
    else {
        return nil
    }
    return code
}

private extension [String: Any] {
    func string(_ key: String) -> String? {
        guard let value = (self[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    func int(_ key: String) -> Int? {
        if let number = self[key] as? NSNumber {
            return number.intValue
        }
        return (self[key] as? String).flatMap { Int($0) }
    }

    func bool(_ key: String) -> Bool? {
        self[key] as? Bool
    }

    func requireIP(_ service: String) throws -> String {
        guard let ip = string("ip") else {
            throw ExitIPLookupError(message: "\(service): answer has no ip")
        }
        return ip
    }
}
