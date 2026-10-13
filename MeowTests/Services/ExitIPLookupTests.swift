import Foundation
@testable import meow_ios
import Testing

/// The geo-IP answers the proxy detail page's exit IP test reads, and the
/// lookup's walk over its sources.
@Suite("ExitIPLookup", .tags(.service))
struct ExitIPLookupTests {
    private func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    private func source(_ host: String) -> ExitIPSource {
        ExitIPSource(url: URL(string: "https://\(host)/geoip")!, parse: parseIpSb)
    }

    // MARK: - Parsers

    @Test
    func `ip.sb answers read in full`() throws {
        let exitIP = try parseIpSb(json(#"""
        {"ip": "95.216.1.2", "country_code": "FI", "country": "Finland",
         "asn": 24940, "isp": "Hetzner Online GmbH", "asn_organization": "Hetzner"}
        """#))
        #expect(exitIP == ExitIP(
            ip: "95.216.1.2",
            countryCode: "FI",
            country: "Finland",
            asn: 24940,
            org: "Hetzner Online GmbH",
        ))
    }

    @Test
    func `ipwho.is reads its connection block and says why it refused`() throws {
        let exitIP = try parseIpwhoIs(json(#"""
        {"ip": "95.216.1.2", "success": true, "country_code": "FI", "country": "Finland",
         "connection": {"asn": 24940, "isp": "Hetzner Online GmbH"}}
        """#))
        #expect(exitIP.asn == 24940)
        #expect(exitIP.org == "Hetzner Online GmbH")

        #expect(throws: ExitIPLookupError(message: "ipwho.is refused: You've hit the monthly limit")) {
            try parseIpwhoIs(json(#"{"success": false, "message": "You've hit the monthly limit"}"#))
        }
    }

    @Test
    func `ipinfo.io splits the ASN out of org and refuses bogons`() throws {
        let exitIP = try parseIpinfo(json(
            #"{"ip": "95.216.1.2", "country": "FI", "org": "AS24940 Hetzner Online GmbH"}"#,
        ))
        #expect(exitIP.countryCode == "FI")
        #expect(exitIP.country == nil)
        #expect(exitIP.asn == 24940)
        #expect(exitIP.org == "Hetzner Online GmbH")

        let bare = try parseIpinfo(json(#"{"ip": "95.216.1.2", "org": "AS24940"}"#))
        #expect(bare.asn == 24940)
        #expect(bare.org == nil)

        let unnumbered = try parseIpinfo(json(#"{"ip": "95.216.1.2", "org": "Some Campus Network"}"#))
        #expect(unnumbered.asn == nil)
        #expect(unnumbered.org == "Some Campus Network")

        #expect(throws: ExitIPLookupError(message: "ipinfo.io: bogon address")) {
            try parseIpinfo(json(#"{"ip": "10.0.0.2", "bogon": true}"#))
        }
    }

    @Test
    func `country codes are normalised or dropped`() throws {
        #expect(try parseIpSb(json(#"{"ip": "1.2.3.4", "country_code": "jp"}"#)).countryCode == "JP")
        #expect(try parseIpSb(json(#"{"ip": "1.2.3.4", "country_code": "JPN"}"#)).countryCode == nil)
        #expect(try parseIpSb(json(#"{"ip": "1.2.3.4", "country_code": "1A"}"#)).countryCode == nil)
    }

    @Test
    func `an answer without an ip is refused`() {
        #expect(throws: ExitIPLookupError(message: "api.ip.sb: answer has no ip")) {
            try parseIpSb(json(#"{"ip": "  ", "country_code": "JP"}"#))
        }
    }

    // MARK: - Display

    @Test
    func `display helpers`() {
        let full = ExitIP(ip: "1.2.3.4", countryCode: "JP", country: "Japan", asn: 2516, org: "KDDI")
        #expect(full.flagEmoji == "🇯🇵")
        #expect(full.countryName(locale: Locale(identifier: "en_US")) == "Japan")
        #expect(full.networkLabel == "AS2516 KDDI")

        let bare = ExitIP(ip: "1.2.3.4", countryCode: nil, country: "Japan", asn: 2516, org: nil)
        #expect(bare.flagEmoji == nil)
        #expect(bare.countryName(locale: Locale(identifier: "en_US")) == "Japan")
        #expect(bare.networkLabel == "AS2516")

        let orgOnly = ExitIP(ip: "1.2.3.4", countryCode: nil, country: nil, asn: nil, org: "KDDI")
        #expect(orgOnly.networkLabel == "KDDI")
        #expect(orgOnly.countryName() == nil)
    }

    // MARK: - Lookup

    @Test
    func `a refusing source falls through to the next, in order`() async throws {
        let asked = Recorder<String>()
        let lookup = ExitIPLookup(
            sources: [source("refuses.example"), source("garbles.example"), source("answers.example")],
            fetcher: { url in
                asked.append(url.host() ?? "")
                switch url.host() {
                case "refuses.example": throw ExitIPLookupError(message: "refuses.example returned HTTP 429")
                case "garbles.example": return "<html>challenge</html>"
                default: return #"{"ip": "198.51.100.4", "country_code": "JP"}"#
                }
            },
        )
        let exitIP = try await lookup.lookup()
        #expect(exitIP.ip == "198.51.100.4")
        #expect(asked.all == ["refuses.example", "garbles.example", "answers.example"])
    }

    @Test
    func `a lookup no source answers says why each failed`() async {
        let lookup = ExitIPLookup(
            sources: [source("a.example"), source("b.example")],
            fetcher: { url in
                if url.host() == "a.example" {
                    throw ExitIPLookupError(message: "a.example returned HTTP 403")
                }
                return "[]"
            },
        )
        await #expect(throws: ExitIPLookupError(
            message: "no exit IP source answered (a.example returned HTTP 403; b.example: unreadable answer)",
        )) {
            try await lookup.lookup()
        }
    }

    @Test
    func `a hanging route gives up after the total timeout`() async {
        let lookup = ExitIPLookup(
            sources: [source("a.example"), source("b.example")],
            fetcher: { _ in
                try await Task.sleep(for: .seconds(30))
                return ""
            },
            totalTimeout: .milliseconds(100),
        )
        let started = ContinuousClock.now
        await #expect(throws: ExitIPLookupError(message: "exit IP lookup timed out")) {
            try await lookup.lookup()
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
