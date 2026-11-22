import DossierCore
import Foundation
import Testing

@Suite("Staleness (§7, §11)")
struct StalenessTests {
  private func template() throws -> PageTemplate {
    let conformance = try Fixtures.conformance()
    return PageTemplate(version: conformance.templateVersion, sha256: conformance.templateSha256)
  }

  private func findings(_ path: String, template: PageTemplate?) throws -> [StaleFinding] {
    let entry = try #require(try Fixtures.conformance().fixtures.first { $0.path == path })
    let found = try #require(Fixtures.member(of: entry))
    let bundle = try #require(try found.cast.openBundle(for: found.member))
    return bundle.stale(template: template)
  }

  @Test("stale(template:) is non-empty exactly where conformance.json has W-STALE")
  func everyLoadedFixture() throws {
    let conformance = try Fixtures.conformance()
    let current = try template()
    var measured = 0
    var staleCount = 0
    for entry in conformance.fixtures {
      guard let found = Fixtures.member(of: entry),
        let bundle = try? found.cast.openBundle(for: found.member)
      else { continue }
      let findings = bundle.stale(template: current)
      if entry.codes.contains("W-STALE") {
        #expect(!findings.isEmpty, "\(entry.path)")
        staleCount += 1
      } else if !entry.mayAlso.contains("W-STALE") {
        #expect(findings.isEmpty, "\(entry.path): \(findings)")
      }
      measured += 1
    }
    if SpecTree.isOverridden { #expect(staleCount >= 17) } else { #expect(staleCount == 17) }
    #expect(measured >= 80)
  }

  @Test("Each W-STALE fixture is stale for its own reason")
  func reasons() throws {
    let current = try template()
    func roles(_ path: String) throws -> Set<String> {
      Set(
        try findings(path, template: current).compactMap { finding -> String? in
          if case .input(let role, _, _) = finding.reason { return role }
          return nil
        })
    }
    #expect(try roles("warnings/W-STALE-input-face").contains("face"))
    #expect(try roles("warnings/W-STALE-input-vox").contains("vox"))
    #expect(try roles("warnings/W-STALE-input-description").contains("description"))
    #expect(try roles("warnings/W-STALE-input-member").contains("castMember"))
    #expect(try roles("warnings/W-STALE-input-bundle").contains("bundle"))
    #expect(try roles("warnings/W-STALE-no-selection").contains("portrait"))
    let noSelection = try findings("warnings/W-STALE-no-selection", template: current)
    #expect(
      noSelection.contains {
        if case .input("portrait", _, nil) = $0.reason { return true }
        return false
      })
    // §7's worked example: both samples' voice input, the ID changed or the key gone.
    let changed = try findings("warnings/W-STALE-input-voice", template: current)
    #expect(changed.count == 2)
    #expect(
      changed.allSatisfy {
        if case .voice("vocalsmith", "FIXTURE0VOICE0000001", ["FIXTURE0VOICE0000002"]) = $0.reason { return true }
        return false
      })
    let absent = try findings("warnings/W-STALE-input-voice-provider-absent", template: current)
    #expect(absent.count == 2)
    #expect(
      absent.allSatisfy {
        if case .voice("vocalsmith", _, nil) = $0.reason { return true }
        return false
      })
    let art = try findings("warnings/W-STALE-art-style", template: current)
    #expect(art.count == 2)
    #expect(
      art.allSatisfy {
        if case .artStyle(_, "woodcut") = $0.reason { return true }
        return false
      })
  }

  @Test("§11: the template compares in both places; with none carried, it doesn't compare")
  func templateIsAParameter() throws {
    let current = try template()
    let reported = try findings("warnings/W-STALE-template", template: current)
    #expect(
      reported.contains {
        if case .pageTemplate(_, current.sha256) = $0.reason { return true }
        return false
      })
    #expect(
      reported.contains {
        if case .input("template", _, _) = $0.reason { return true }
        return false
      })
    #expect(try findings("warnings/W-STALE-template", template: nil).isEmpty)
    #expect(try findings("valid/complete-lead", template: current).isEmpty)
    // A different current template makes a current page stale: versions aren't ordered.
    let other = PageTemplate(version: current.version, sha256: String(repeating: "0", count: 64))
    #expect(try !findings("valid/complete-lead", template: other).isEmpty)
  }

  @Test("valid/not-reported: a stale candidate and an image with no artStyle aren't reported")
  func notReported() throws {
    #expect(try findings("valid/not-reported", template: try template()).isEmpty)
  }

  @Test("§7: opened without a CAST.md, W-STALE-input-voice's samples aren't stale")
  func voiceWithoutMember() throws {
    let bundle = try DossierBundle.open(
      at: Fixtures.project("warnings/W-STALE-input-voice").appendingPathComponent("characters/THE NIGHT CALLER.dossier"))
    #expect(bundle.stale(template: try template()).isEmpty)
  }

  @Test("DF-77: valid/imported-view's front view differs in artStyle and isn't stale")
  func importedView() throws {
    let current = try template()
    #expect(try findings("valid/imported-view", template: current).isEmpty)
  }

  @Test("With no member, the castMember input isn't compared")
  func noMember() throws {
    let bundle = try DossierBundle.open(
      at: Fixtures.project("warnings/W-STALE-input-member").appendingPathComponent("characters/PELL ARDEN.dossier"))
    let stale = bundle.stale(template: try template())
    #expect(
      !stale.contains {
        if case .input("castMember", _, _) = $0.reason { return true }
        return false
      })
  }

  @Test("DF-100: an accepted mismatch is current; a later change, or a voice entry, isn't")
  func acceptedFixtures() throws {
    let current = try template()
    #expect(try findings("valid/accepted-stale-view", template: current).isEmpty)
    #expect(try findings("valid/accepted-art-style", template: current).isEmpty)
    let older = try findings("warnings/W-STALE-accepted-older-portrait", template: current)
    #expect(
      older.contains {
        if case .input("portrait", _, _) = $0.reason { return $0.path == "images/view-front-b31b46b8.png" }
        return false
      })
    let again = try findings("warnings/W-STALE-accepted-art-style-changed-again", template: current)
    #expect(!again.isEmpty)
    #expect(
      again.allSatisfy {
        if case .artStyle(_, "linocut") = $0.reason { return true }
        return false
      })
    let voice = try findings("errors/E-SCHEMA-accepted-voice", template: current)
    #expect(voice.count == 2)
    #expect(
      voice.allSatisfy {
        if case .voice = $0.reason { return true }
        return false
      })
  }

  /// valid/accepted-stale-view with the view's entry replaced.
  private func acceptedView(_ entry: JSONObject?) throws -> DossierBundle {
    let bundle = try DossierBundle.open(
      at: Fixtures.project("valid/accepted-stale-view").appendingPathComponent("characters/PELL ARDEN.dossier"))
    var manifest = bundle.manifest
    var assets = manifest.assets
    let index = try #require(assets.firstIndex { $0.path == "images/view-front-b31b46b8.png" })
    assets[index].accepted = entry.map { [AcceptedEntry(json: $0)] } ?? []
    manifest.assets = assets
    return DossierBundle(url: bundle.url, manifest: manifest, member: nil)
  }

  @Test("DF-100: only a well-formed entry for the input's role, with the selection's hash, accepts")
  func entryShapes() throws {
    let selected = JSONValue.string("3d7967cf98c8f532ba194c4bb1d9ba6a641b2fb7c84f8de9e427f8651086c394")
    let time = JSONValue.string("2026-11-20T09:30:00Z")
    #expect(try acceptedView(JSONObject([("acceptedAt", time), ("role", .string("portrait")), ("sha256", selected)])).stale().isEmpty)
    #expect(try acceptedView(nil).stale().count == 1)
    // The recorded input's hash, not the selection's: it matches nothing.
    let recorded = JSONValue.string("f65b324c40943eced863282c9f4c8eda7433c4d71d4416e7353fab242ea506d4")
    #expect(try acceptedView(JSONObject([("acceptedAt", time), ("role", .string("portrait")), ("sha256", recorded)])).stale().count == 1)
    // Another role.
    #expect(try acceptedView(JSONObject([("acceptedAt", time), ("role", .string("face")), ("sha256", selected)])).stale().count == 1)
    // A key the schema doesn't allow, or a missing acceptedAt: E-SCHEMA, and it accepts nothing.
    #expect(
      try acceptedView(
        JSONObject([("acceptedAt", time), ("role", .string("portrait")), ("sha256", selected), ("note", .string("x"))])
      ).stale().count == 1)
    #expect(try acceptedView(JSONObject([("role", .string("portrait")), ("sha256", selected)])).stale().count == 1)
    // An artStyle entry doesn't accept an input.
    #expect(try acceptedView(JSONObject([("acceptedAt", time), ("artStyle", .string("flat placeholder shapes"))])).stale().count == 1)
  }
}
