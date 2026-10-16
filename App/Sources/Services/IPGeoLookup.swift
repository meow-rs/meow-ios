import Foundation
import MeowModels

/// Where an IP is registered, as far as the bundled GeoX databases know.
struct IPGeo: Decodable, Equatable {
    /// ISO 3166-1 alpha-2, or one of the database's own codes for ranges it
    /// files by owner or use (`GOOGLE`, `CLOUDFLARE`, `PRIVATE`…) — what a
    /// GEOIP rule matches on. Nil when unknown.
    var country: String?
    var asn: UInt32?
    /// The AS organisation.
    var org: String?

    /// The database's code for private, loopback and link-local ranges.
    var isPrivate: Bool {
        country == "PRIVATE"
    }

    /// `country` as its flag and name in the UI language. The database's own
    /// codes (`GOOGLE`…) are what GEOIP rules match on, so they stay as they
    /// are.
    func regionLabel(locale: Locale = .current) -> String? {
        guard let country else { return nil }
        guard country.count == 2,
              country.unicodeScalars.allSatisfy({ ("A" ... "Z").contains($0) }),
              let name = locale.localizedString(forRegionCode: country),
              !name.isEmpty, name != country
        else { return country }
        return "\(regionFlag(country)) \(name)"
    }
}

/// Looks IPs up in the GeoX databases `GeoAssetStager` stages into the App
/// Group (`meow_lookup_ip`), from this process and without the network:
/// nothing about the connection leaves the device.
enum IPGeoLookup {
    static func lookup(_ ip: String, in dir: URL = AppGroup.meowConfigDir) async -> IPGeo {
        let path = dir.path(percentEncoded: false)
        // Maps the databases on first use; keep that off the main thread.
        return await Task.detached(priority: .utility) {
            decode(answer(ip: ip, dir: path))
        }.value
    }

    static func decode(_ json: String) -> IPGeo {
        (try? JSONDecoder().decode(IPGeo.self, from: Data(json.utf8))) ?? IPGeo()
    }

    private static func answer(ip: String, dir: String) -> String {
        let raw: UnsafeMutablePointer<CChar>? = dir.withCString { dirPtr in
            ip.withCString { meow_lookup_ip(dirPtr, $0) }
        }
        guard let raw else { return "{}" }
        defer { meow_string_free(raw) }
        return String(cString: raw)
    }
}
