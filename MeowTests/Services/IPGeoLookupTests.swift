import Foundation
@testable import meow_ios
import Testing

/// The connection detail page's IP lookups: `meow_lookup_ip` over the GeoX
/// databases the app bundles, and how its answer reads.
@Suite("IPGeoLookup", .tags(.service))
struct IPGeoLookupTests {
    /// The bundled databases' directory, as `GeoAssetStager` finds them.
    private func bundledGeoData() throws -> URL {
        let country = try #require(
            Bundle.main.url(forResource: "Country.mmdb", withExtension: nil, subdirectory: "GeoData")
                ?? Bundle.main.url(forResource: "Country.mmdb", withExtension: nil),
        )
        return country.deletingLastPathComponent()
    }

    @Test(.tags(.ffi))
    func `looks up where an IP is registered in the bundled databases`() async throws {
        let dir = try bundledGeoData()
        let google = await IPGeoLookup.lookup("8.8.8.8", in: dir)
        #expect(google.country == "GOOGLE")
        #expect(google.asn == 15169)
        #expect(google.org != nil)

        let lan = await IPGeoLookup.lookup("192.168.1.1", in: dir)
        #expect(lan.isPrivate)
        #expect(lan.asn == nil)
    }

    @Test(.tags(.ffi))
    func `answers nothing without the databases or for a non-IP`() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "meow-ip-geo-missing")
        #expect(await IPGeoLookup.lookup("8.8.8.8", in: missing) == IPGeo())
        let dir = try bundledGeoData()
        #expect(await IPGeoLookup.lookup("not an ip", in: dir) == IPGeo())
    }

    @Test
    func `decodes the lookup's answer`() {
        #expect(
            IPGeoLookup.decode(#"{"country":"CN","asn":136958,"org":"China Unicom"}"#)
                == IPGeo(country: "CN", asn: 136_958, org: "China Unicom"),
        )
        #expect(IPGeoLookup.decode("{}") == IPGeo())
        #expect(IPGeoLookup.decode("garbage") == IPGeo())
    }

    @Test
    func `a country code reads as its flag and name, the database's own codes as they are`() {
        let english = Locale(identifier: "en_US")
        #expect(regionFlag("CN").unicodeScalars.map(\.value) == [0x1F1E8, 0x1F1F3])
        #expect(IPGeo(country: "JP").regionLabel(locale: english) == "\(regionFlag("JP")) Japan")
        #expect(IPGeo(country: "GOOGLE").regionLabel(locale: english) == "GOOGLE")
        #expect(IPGeo().regionLabel(locale: english) == nil)
        #expect(IPGeo(country: "PRIVATE").isPrivate)
    }
}
