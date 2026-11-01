import Foundation
import Testing

@testable import DossierCLICore

@Suite("dossier check")
struct CheckCommandTests {
  private let bundleName = "characters/WREN HALLOWAY.dossier"

  /// Every file under a directory, with its bytes.
  private func tree(_ root: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = walker?.nextObject() as? URL {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[url.path] = try Data(contentsOf: url)
      }
    }
    return result
  }

  private func characterFile(_ project: TempProject) -> URL {
    URL(fileURLWithPath: project.path(bundleName + "/CHARACTER.md"))
  }

  private func append(_ text: String, to url: URL) throws {
    let current = try String(decoding: Data(contentsOf: url), as: UTF8.self)
    try Data((current + text).utf8).write(to: url)
  }

  @Test("clean exits 0, reports each part, and writes nothing")
  func clean() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let before = try tree(project.root)
    let ran = dossier(["check", project.path(bundleName), "--json"])
    #expect(ran.status == 0, "\(ran.stdout)")
    let object = try ran.object()
    #expect(object["status"] as? Int == 0)
    #expect(object["hasFile"] as? Bool == true)
    #expect(object["tier"] as? String == "lead")
    #expect(object["tierSource"] as? String == "description")
    #expect((object["frontMatterKeys"] as? [String])?.contains("character") == true)
    #expect((object["sections"] as? [[String: Any]])?.count == 11)
    #expect((object["issues"] as? [Any])?.isEmpty == true)
    let footnotes = try #require(object["footnotes"] as? [String: [String]])
    #expect(footnotes["undefined"] == [] && footnotes["unused"] == [] && footnotes["unclassified"] == [])
    let groups = try #require(object["openQuestions"] as? [[String: Any]])
    #expect(groups.map { $0["group"] as? String } == ["Needed before Portrait / Views", "Optional"])
    #expect(groups[0]["empty"] as? Bool == true)
    #expect(groups[1]["items"] as? [String] == ["What the station's call sign is."])
    #expect(try tree(project.root) == before)

    let text = dossier(["check", project.path(bundleName)])
    #expect(text.status == 0)
    #expect(text.stdout.contains("tier: lead (from description)"))
    #expect(text.stdout.contains("sections: 11 of 11"))
    #expect(text.stdout.contains("Optional: 1"))
    #expect(text.stdout.contains("0 errors, 0 warnings"))
    #expect(try tree(project.root) == before)
  }

  @Test("warnings only exit 1, and name their code")
  func warnings() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    try append("\nA stray reference.[^missing]\n", to: characterFile(project))
    let ran = dossier(["check", project.path(bundleName), "--json"])
    #expect(ran.status == 1)
    let object = try ran.object()
    #expect(object["status"] as? Int == 1)
    let issues = try #require(object["issues"] as? [[String: Any]])
    #expect(issues.map { $0["code"] as? String } == ["W-FOOTNOTE"])
    #expect(issues.first?["area"] as? String == "footnotes")
    #expect(issues.first?["level"] as? String == "warning")
    #expect((object["footnotes"] as? [String: [String]])?["undefined"] == ["missing"])

    let text = dossier(["check", project.path(bundleName)])
    #expect(text.status == 1)
    #expect(text.stdout.contains("warning W-FOOTNOTE [footnotes]: [^missing] has no definition"))
    #expect(text.stdout.contains("0 errors, 1 warnings"))
  }

  @Test("errors exit 2: a name mismatch, a missing required key, no file")
  func errors() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let file = characterFile(project)
    let original = try Data(contentsOf: file)

    let renamed = String(decoding: original, as: UTF8.self)
      .replacingOccurrences(of: "character: WREN HALLOWAY", with: "character: THE MENDER")
    try Data(renamed.utf8).write(to: file)
    let mismatch = dossier(["check", project.path(bundleName), "--json"])
    #expect(mismatch.status == 2)
    let codes = (try mismatch.object()["issues"] as? [[String: Any]])?.compactMap { $0["code"] as? String }
    #expect(codes == ["E-NAME-MISMATCH"])

    let keyless = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "type: character\n", with: "")
    try Data(keyless.utf8).write(to: file)
    #expect(dossier(["check", project.path(bundleName)]).status == 2)

    try FileManager.default.removeItem(at: file)
    let none = dossier(["check", project.path(bundleName), "--json"])
    #expect(none.status == 2)
    #expect(try none.object()["hasFile"] as? Bool == false)
    #expect(dossier(["check", project.path(bundleName)]).stdout.contains("no CHARACTER.md"))
  }

  @Test("--cast: the member gives the tier")
  func cast() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let ran = dossier(["check", project.path(bundleName), "--cast", project.cast.path, "--json"])
    #expect(ran.status == 0, "\(ran.stdout)")
    let object = try ran.object()
    #expect(object["tier"] as? String == "lead")
    #expect(object["tierSource"] as? String == "cast")
  }

  @Test("--cast: no member is W-ORPHAN; an unreadable CAST.md is a failure")
  func castFailures() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let moved = project.path("characters/THE STRAY.dossier")
    try FileManager.default.copyItem(atPath: project.path(bundleName), toPath: moved)
    let orphan = dossier(["check", moved, "--cast", project.cast.path, "--json"])
    let codes = (try orphan.object()["issues"] as? [[String: Any]])?.compactMap { $0["code"] as? String } ?? []
    #expect(codes.contains("W-ORPHAN"))
    #expect(orphan.status >= 1)

    try Data("no front matter\n".utf8).write(to: project.cast)
    let unreadable = dossier(["check", project.path(bundleName), "--cast", project.cast.path, "--json"])
    #expect(unreadable.status == 2)
    #expect((try unreadable.object()["error"] as? [String: Any])?["code"] as? String == "E-CAST")
  }

  @Test("a path that isn't a bundle is a failure, with status 2 and an error object")
  func notABundle() throws {
    let project = try TempProject(castText: plainCast)
    let ran = dossier(["check", project.path("characters/NOBODY.dossier"), "--json"])
    #expect(ran.status == 2)
    #expect(try ran.object()["error"] != nil)
    #expect(dossier(["check"]).status == 64)
  }

  @Test("the root help lists check")
  func help() {
    #expect(DossierCommand.helpMessage().contains("check"))
  }
}
