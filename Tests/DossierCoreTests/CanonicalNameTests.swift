import DossierCore
import Foundation
import Testing

@Suite("CanonicalName (§2)")
struct CanonicalNameTests {
  private struct Table: Decodable {
    struct Row: Decodable {
      let input: String
      let canonical: String?
      let error: String?
    }
    let names: [Row]
  }

  /// `Row.canonical` is compared by bytes: Swift's `==` would pass an NFD result.
  @Test("Every row of names.json")
  func namesJSON() throws {
    let data = try Data(contentsOf: Fixtures.root.appendingPathComponent("names.json"))
    let table = try JSONDecoder().decode(Table.self, from: data)
    #expect(table.names.count == 18)
    for row in table.names {
      if let canonical = row.canonical {
        let result = try CanonicalName.canonicalize(row.input)
        #expect(bytes(result) == bytes(canonical), "\(row.input)")
        #expect(CanonicalName.isCanonical(canonical), "\(canonical)")
      } else {
        #expect(row.error == "E-NAME")
        #expect(throws: (any Error).self, "\(row.input)") { try CanonicalName.canonicalize(row.input) }
        #expect(!CanonicalName.isCanonical(row.input), "\(row.input)")
      }
    }
  }

  @Test("An NFD name isn't canonical, though Swift calls it equal to its NFC form")
  func nfdIsNotCanonical() {
    let nfd = "JOSE\u{0301}"
    let nfc = "JOS\u{00C9}"
    #expect(nfd == nfc)
    #expect(!CanonicalName.isCanonical(nfd))
    #expect(CanonicalName.isCanonical(nfc))
  }

  @Test("The E-NAME fixtures about canonical form fail isCanonical, by bytes")
  func nameFixtures() throws {
    for path in ["errors/E-NAME-not-nfc", "errors/E-NAME-not-canonical"] {
      let entry = try #require(try Fixtures.conformance().fixtures.first { $0.path == path })
      let bundle = try DossierBundle.open(at: Fixtures.bundleURL(of: entry))
      #expect(!CanonicalName.isCanonical(bundle.manifest.character), "\(path)")
    }
    let valid = try #require(try Fixtures.conformance().fixtures.first { $0.path == "valid/non-ascii-underfive" })
    let bundle = try DossierBundle.open(at: Fixtures.bundleURL(of: valid))
    #expect(CanonicalName.isCanonical(bundle.manifest.character))
  }
}
