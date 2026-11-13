import DossierCore
import Foundation
import Testing

@Suite("Checksum (§5.3, Appendix A)")
struct ChecksumTests {
  private static let character = "bc987259bf9c3924d17ebcd78cde56315bc965eacc7f8070184b88d35fc845c6"
  private static let samples = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"

  @Test("§5.3's worked example")
  func section5_3WorkedExample() {
    #expect(Checksum.sha256(Data("# CHARACTER\n".utf8)) == Self.character)
    #expect(Checksum.sha256(Data("hello\n".utf8)) == Self.samples)
    let expected = "a27ac1c9afbdeb3708fd6b86b90977f80d3b01d31bc65a7acb84585c74a30980"
    #expect(Checksum.sorted([Self.character, Self.samples]) == expected)
    #expect(Checksum.sorted([Self.samples, Self.character]) == expected)
  }

  @Test("Appendix A's form is in files order, and differs from §5.3's when the orders differ")
  func pathOrder() {
    let pathOrder = Checksum.pathOrder([Self.character, Self.samples])
    #expect(pathOrder == Checksum.sha256(Self.character + Self.samples))
    #expect(pathOrder != Checksum.sorted([Self.character, Self.samples]))
    #expect(Checksum.pathOrder([Self.samples, Self.character]) == Checksum.sorted([Self.character, Self.samples]))
  }

  @Test("Every fixture without a checksum fault computes its recorded checksum, v1 and v2")
  func fixtures() throws {
    let conformance = try Fixtures.conformance()
    var verified = 0
    for entry in conformance.fixtures where !entry.codes.contains("E-CHECKSUM") {
      let url = Fixtures.bundleURL(of: entry).appendingPathComponent("manifest.json")
      guard let data = try? Data(contentsOf: url), let manifest = try? Manifest(data: data) else { continue }
      #expect(manifest.computedChecksum == manifest.manifestChecksum, "\(entry.path)")
      verified += 1
    }
    // The count is the pinned tag's. Another tree (SPEC_DIR) may have more fixtures.
    if SpecTree.isOverridden { #expect(verified >= 147) } else { #expect(verified == 147) }
  }

  @Test("The two E-CHECKSUM fixtures fail, including a path-order sum in a v2 manifest")
  func checksumFaults() throws {
    for name in ["errors/E-CHECKSUM", "errors/E-CHECKSUM-path-order"] {
      let entry = try #require(try Fixtures.conformance().fixtures.first { $0.path == name })
      let data = try Data(contentsOf: Fixtures.bundleURL(of: entry).appendingPathComponent("manifest.json"))
      let manifest = try Manifest(data: data)
      #expect(manifest.computedChecksum != manifest.manifestChecksum, "\(name)")
    }
  }
}
