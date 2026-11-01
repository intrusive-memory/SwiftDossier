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

  @Test("an unreadable CAST.md is E-CAST and exit 2")
  func unreadableCast() throws {
    let project = try TempProject(castText: "no front matter here\n")
    let ran = dossier(["validate", "--cast", project.cast.path, "--json"])
    #expect(ran.status == 2)
    let codes = (try ran.object()["findings"] as? [[String: Any]])?.compactMap { $0["code"] as? String }
    #expect(codes == ["E-CAST"])
  }

  @Test("validate needs a bundle or --cast")
  func needsSomething() {
    #expect(dossier(["validate"]).status == 64)
  }
}
