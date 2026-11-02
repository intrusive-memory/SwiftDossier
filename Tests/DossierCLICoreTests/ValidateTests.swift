import Dossier
import DossierCore
import Foundation
import Testing

@testable import DossierCLICore

@Suite("dossier validate")
struct ValidateTests {
  @Test("a conformance bundle validates alone, and from its project")
  func completeLead() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let bundle = project.path("characters/WREN HALLOWAY.dossier")

    let alone = dossier(["validate", bundle, "--json"])
    #expect(try alone.object()["status"] as? Int == Int(alone.status))

    let fromProject = dossier(["validate", bundle, "--cast", project.cast.path, "--json"])
    #expect(fromProject.status == 0, "\(fromProject.stdout)")
    let object = try fromProject.object()
    #expect((object["findings"] as? [Any])?.isEmpty == true)
    #expect((object["completeness"] as? [[String: Any]])?.first?["tier"] as? String == "lead")

    let whole = dossier(["validate", "--cast", project.cast.path])
    #expect(whole.status == 0, "\(whole.stdout)")
    #expect(whole.stdout.contains("0 errors, 0 warnings"))
  }

  @Test("exit 1 for warnings only, 2 for errors")
  func exitStatus() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let bundle = project.path("characters/WREN HALLOWAY.dossier")
    // A file with no asset entry is W-UNCLASSIFIED.
    try Data("note".utf8).write(to: URL(fileURLWithPath: bundle + "/images/loose.png"))
    let warned = dossier(["validate", bundle, "--cast", project.cast.path, "--json"])
    #expect(warned.status == 1)
    let codes = (try warned.object()["findings"] as? [[String: Any]])?.compactMap { $0["code"] as? String }
    #expect(codes?.contains("W-UNCLASSIFIED") == true)

    // Tamper with a listed file: E-FILE-HASH.
    let portrait = try FileManager.default.contentsOfDirectory(atPath: bundle + "/images").first { $0.hasPrefix("portrait-") }
    try Data("changed".utf8).write(to: URL(fileURLWithPath: bundle + "/images/" + (portrait ?? "")))
    let broken = dossier(["validate", bundle, "--cast", project.cast.path])
    #expect(broken.status == 2)
    #expect(broken.stdout.contains("E-FILE-HASH"))
  }

  @Test("a bundle no member points at is an orphan from the project")
  func orphan() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let moved = project.path("characters/THE STRAY.dossier")
    try FileManager.default.copyItem(atPath: project.path("characters/WREN HALLOWAY.dossier"), toPath: moved)
    let ran = dossier(["validate", moved, "--cast", project.cast.path, "--json"])
    let codes = (try ran.object()["findings"] as? [[String: Any]])?.compactMap { $0["code"] as? String } ?? []
    #expect(codes.contains("W-ORPHAN"))
    #expect(ran.status >= 1)
  }

  @Test("validate --cast --json lists each member's hash and manifest; a bundle's result doesn't")
  func memberLines() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let cast = try Cast.load(project.cast)

    let members = try #require(try dossier(["validate", "--cast", project.cast.path, "--json"]).object()["members"] as? [[String: Any]])
    #expect(members.compactMap { $0["character"] as? String } == cast.members.map(\.character))
    #expect(members.compactMap { $0["hash"] as? String } == cast.members.map(\.hash))
    #expect(members[0]["manifest"] as? String == cast.manifestURL(of: cast.members[0])?.path)
    #expect(members[1]["manifest"] is NSNull)

    let bundle = project.path("characters/WREN HALLOWAY.dossier")
    #expect(try dossier(["validate", bundle, "--cast", project.cast.path, "--json"]).object()["members"] == nil)
  }

  @Test("an unreadable CAST.md is E-CAST and exit 2")
  func unreadableCast() throws {
    let project = try TempProject(castText: "no front matter here\n")
    let ran = dossier(["validate", "--cast", project.cast.path, "--json"])
    #expect(ran.status == 2)
    let codes = (try ran.object()["findings"] as? [[String: Any]])?.compactMap { $0["code"] as? String }
    #expect(codes == ["E-CAST"])
  }

  private struct ConformanceFile: Decodable {
    struct Entry: Decodable {
      let path: String
      let verdict: String
      let codes: [String]
      let mayAlso: [String]
    }
    let templateVersion: String
    let templateSha256: String
    let fixtures: [Entry]

    static func load() throws -> ConformanceFile {
      try JSONDecoder().decode(
        ConformanceFile.self, from: Data(contentsOf: FixturePaths.root.appendingPathComponent("conformance.json")))
    }
  }

  private func codes(_ ran: Ran) throws -> [String] {
    let findings = try #require(try ran.object()["findings"] as? [[String: Any]])
    return findings.compactMap { $0["code"] as? String }
  }

  @Test("the CLI gives what conformance.json states for every fixture, with its bundled template")
  func everyConformanceFixture() throws {
    if SpecTree.isOverridden {
      Issue.record("skipped: SPEC_DIR is set, and the CLI carries the pinned template, not that tree's", severity: .warning)
      return
    }
    let file = try ConformanceFile.load()
    #expect(try DossierTemplate.current == PageTemplate(version: file.templateVersion, sha256: file.templateSha256))
    #expect(!file.fixtures.isEmpty)
    let statuses = ["valid": Int32(0), "warnings": 1, "invalid": 2]
    for entry in file.fixtures {
      let cast = FixturePaths.root.appendingPathComponent(entry.path).appendingPathComponent("CAST.md")
      let ran = dossier(["validate", "--cast", cast.path, "--json"])
      #expect(ran.status == statuses[entry.verdict], "\(entry.path): \(ran.stdout)")
      let reported = Set(try codes(ran))
      #expect(Set(entry.codes).isSubset(of: reported), "\(entry.path): \(reported.sorted())")
      #expect(reported.subtracting(entry.codes).subtracting(entry.mayAlso).isEmpty, "\(entry.path): \(reported.sorted())")
    }
  }

  @Test("a page made with an older template is W-STALE, alone and from its project")
  func olderTemplate() throws {
    if SpecTree.isOverridden {
      Issue.record("skipped: SPEC_DIR is set, and the CLI carries the pinned template, not that tree's", severity: .warning)
      return
    }
    let project = try TempProject(copyOf: "warnings/W-STALE-template")
    let bundle = project.path("characters/PELL ARDEN.dossier")

    // The library, given no template, makes no comparison: the finding is the CLI's template.
    #expect(try DossierBundle.validate(at: URL(fileURLWithPath: bundle)).findings.isEmpty)

    for arguments in [["validate", bundle, "--json"], ["validate", bundle, "--cast", project.cast.path, "--json"]] {
      let ran = dossier(arguments)
      #expect(ran.status == 1, "\(ran.stdout)")
      #expect(try codes(ran).contains("W-STALE"), "\(ran.stdout)")
      #expect(ran.stdout.contains(try DossierTemplate.sha256))
    }
    let whole = dossier(["validate", "--cast", project.cast.path])
    #expect(whole.status == 1)
    #expect(whole.stdout.contains("W-STALE"))
  }

  @Test("validate needs a bundle or --cast")
  func needsSomething() {
    #expect(dossier(["validate"]).status == 64)
  }
}
