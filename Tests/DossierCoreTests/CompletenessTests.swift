import DossierCore
import Foundation
import Testing

@Suite("Completeness (§8.3)")
struct CompletenessTests {
  @Test("conformance.json's complete and missingRequired, for every fixture that has them")
  func everyAssertedFixture() throws {
    var asserted = 0
    for entry in try Fixtures.conformance().fixtures {
      guard let complete = entry.complete, let missing = entry.missingRequired else { continue }
      let found = try #require(Fixtures.member(of: entry), "\(entry.path) has no member")
      let bundle = try #require(try found.cast.openBundle(for: found.member), "\(entry.path)")
      let report = try #require(try bundle.completeness(), "\(entry.path)")
      #expect(report.isComplete == complete, "\(entry.path)")
      #expect(report.missingRequired == missing.sorted(), "\(entry.path)")
      asserted += 1
    }
    // The count is the pinned tag's. Another tree (SPEC_DIR) may have more fixtures.
    #expect(SpecTree.isOverridden ? asserted >= 54 : asserted == 54)
  }

  @Test("§8.3: no role means completeness isn't defined, whatever the manifest says")
  func noTier() throws {
    for path in ["warnings/W-ROLE", "warnings/W-ROLE-manifest-has-one"] {
      let entry = try #require(try Fixtures.conformance().fixtures.first { $0.path == path })
      let found = try #require(Fixtures.member(of: entry))
      let bundle = try #require(try found.cast.openBundle(for: found.member))
      #expect(try bundle.completeness() == nil, "\(path)")
    }
  }

  @Test("Rows come from tiers.json, with each tier's level")
  func rowsAreFromTheTable() throws {
    let cast = try Cast.load(Fixtures.project("valid/complete-lead").appendingPathComponent("CAST.md"))
    let bundle = try #require(try cast.openBundle(for: cast.members[0]))

    let url = try #require(DossierCoreResources.bundle.url(forResource: "tiers", withExtension: "json"))
    let table = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let rows = try #require(table["rows"] as? [[String: Any]])

    let report = try #require(try bundle.completeness(tier: .costar))
    #expect(report.rows.map(\.id) == rows.compactMap { $0["id"] as? String })
    #expect(report.tier == .costar)
    for (row, source) in zip(report.rows, rows) {
      let levels = try #require(source["levels"] as? [String: String])
      #expect(row.level.rawValue == levels["costar"], "\(row.id)")
      #expect(row.label == source["label"] as? String)
    }
    #expect(report.rows.first { $0.id == "views" }?.isSatisfied == true)
  }

  @Test("Every check row in tiers.json is implemented, on every tier")
  func everyCheckRowIsImplemented() throws {
    let cast = try Cast.load(Fixtures.project("valid/complete-lead").appendingPathComponent("CAST.md"))
    let bundle = try #require(try cast.openBundle(for: cast.members[0]))
    let reports = [
      try bundle.completeness(tier: .lead), try bundle.completeness(tier: .supporting),
      try bundle.completeness(tier: .guest), try bundle.completeness(tier: .narrator),
      try bundle.completeness(tier: .costar), try bundle.completeness(tier: .underfive),
      try bundle.completeness(tier: .background),
    ]
    for report in reports {
      #expect(report?.rows.count == 18)
    }
  }

  @Test("With no member the voicePrompt row is unsatisfied, and the rest are measured")
  func noMember() throws {
    let bundle = try DossierBundle.open(
      at: Fixtures.project("valid/complete-lead").appendingPathComponent("characters/WREN HALLOWAY.dossier"))
    #expect(try bundle.completeness() == nil)
    let report = try #require(try bundle.completeness(tier: .lead))
    #expect(report.missingRequired == ["voicePrompt"])
  }
}
