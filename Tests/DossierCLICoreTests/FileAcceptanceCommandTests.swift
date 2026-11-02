import Foundation
import Testing

@testable import DossierCLICore

@Suite("dossier refresh accepts a changed file; nothing else does")
struct FileAcceptanceCommandTests {
  private let bundleName = "characters/WREN HALLOWAY.dossier"
  private let editedText = "---\ntype: character\ncharacter: WREN HALLOWAY\n---\n\n## Logline\n\nEdited by hand.\n"

  private func codes(_ project: TempProject) throws -> [String] {
    let ran = dossier(["validate", project.path(bundleName), "--cast", project.cast.path, "--json"])
    return (try ran.object()["findings"] as? [[String: Any]])?.compactMap { $0["code"] as? String } ?? []
  }

  private func edit(_ project: TempProject) throws -> URL {
    let file = URL(fileURLWithPath: project.path(bundleName + "/CHARACTER.md"))
    try Data(editedText.utf8).write(to: file)
    return file
  }

  /// A view to select, reject or remove, added before the edit.
  private func addView(_ project: TempProject) throws -> String {
    let source = try writePNG(named: "view.png", in: project.root, shade: 123)
    let added = dossier(["add", project.path(bundleName), source.path, "--kind", "view", "--variant", "left", "--json"])
    #expect(added.status == 0, "\(added.stderr) \(added.stdout)")
    return try #require((try added.object()["asset"] as? [String: Any])?["path"] as? String)
  }

  @Test("Text: render says to refresh, prompt --set doesn't clear it, refresh reports the file, and render works")
  func textFlow() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let bundle = project.path(bundleName)
    let file = try edit(project)

    let refused = dossier(["render", bundle])
    #expect(refused.status == 1)
    #expect(refused.stderr.contains("E-FILE-HASH CHARACTER.md") && refused.stderr.contains("dossier refresh"), "\(refused.stderr)")

    #expect(dossier(["prompt", bundle, "identity", "--set", "A new prompt."]).status == 0)
    #expect(try codes(project).contains("E-FILE-HASH"))
    #expect(!(try codes(project).contains("E-CHECKSUM")))
    #expect(try Data(contentsOf: file) == Data(editedText.utf8))
    #expect(dossier(["render", bundle]).status == 1)

    let refreshed = dossier(["refresh", bundle])
    #expect(refreshed.status == 0, "\(refreshed.stderr)")
    #expect(refreshed.stdout.contains("Accepted CHARACTER.md"), "\(refreshed.stdout)")
    #expect(!(try codes(project).contains("E-FILE-HASH")))
    #expect(!(try codes(project).contains("E-CHECKSUM")))

    let rendered = dossier(["render", bundle])
    #expect(rendered.status == 0, "\(rendered.stderr)")
  }

  @Test("--json: accepted lists the file, then nothing, and the second run leaves the manifest's bytes")
  func jsonFlow() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let bundle = project.path(bundleName)
    _ = try edit(project)

    let refused = dossier(["render", bundle, "--json"])
    #expect(refused.status == 1)
    #expect(refused.stdout.contains("dossier refresh"), "\(refused.stdout)")

    let first = dossier(["refresh", bundle, "--json"])
    #expect(try first.object()["accepted"] as? [String] == ["CHARACTER.md"])
    let manifest = URL(fileURLWithPath: bundle + "/manifest.json")
    let bytes = try Data(contentsOf: manifest)

    let second = dossier(["refresh", bundle, "--json"])
    #expect(try second.object()["accepted"] as? [String] == [])
    #expect(try Data(contentsOf: manifest) == bytes)
  }

  @Test("Every other write leaves E-FILE-HASH and the file's bytes", arguments: ["add", "select", "reject", "remove", "face"])
  func mutators(_ command: String) throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let bundle = project.path(bundleName)
    let view = try addView(project)
    let file = try edit(project)
    let manifest = URL(fileURLWithPath: bundle + "/manifest.json")
    let before = try Data(contentsOf: manifest)

    let arguments: [String]
    switch command {
    case "add":
      let source = try writePNG(named: "other.png", in: project.root, shade: 77)
      arguments = ["add", bundle, source.path, "--kind", "view", "--variant", "right"]
    case "select": arguments = ["select", bundle, view]
    case "reject": arguments = ["reject", bundle, view]
    case "remove": arguments = ["remove", bundle, view, "--yes"]
    default: arguments = ["face", bundle, "--box", "1,1,8,8"]
    }
    let ran = dossier(arguments)
    #expect(ran.status == 0, "\(ran.stderr)")
    #expect(try Data(contentsOf: manifest) != before, "the write happened")
    #expect(try codes(project).contains("E-FILE-HASH"))
    #expect(!(try codes(project).contains("E-CHECKSUM")))
    #expect(try Data(contentsOf: file) == Data(editedText.utf8))

    #expect(dossier(["refresh", bundle]).stdout.contains("Accepted CHARACTER.md"))
    #expect(!(try codes(project).contains("E-FILE-HASH")))
  }

  @Test("A missing file: render says to restore it, and refresh doesn't clear it")
  func missing() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let bundle = project.path(bundleName)
    try FileManager.default.removeItem(atPath: bundle + "/CHARACTER.md")
    let refused = dossier(["render", bundle])
    #expect(refused.status == 1)
    #expect(refused.stderr.contains("E-FILE-MISSING CHARACTER.md") && refused.stderr.contains("restored"), "\(refused.stderr)")

    #expect(dossier(["refresh", bundle]).status == 0)
    #expect(try codes(project).contains("E-FILE-MISSING"))

    let prompted = dossier(["prompt", bundle, "identity", "--set", "No."])
    #expect(prompted.status != 0)
    #expect(prompted.stderr.contains("dossier remove"), "\(prompted.stderr)")
  }

  @Test("Help says what refresh and render do about it")
  func help() throws {
    let refresh = dossier(["refresh", "--help"])
    #expect(refresh.stdout.contains("E-FILE-HASH") && refresh.stdout.contains("E-FILE-MISSING"))
    let render = dossier(["render", "--help"])
    #expect(render.stdout.contains("refresh"))
  }
}
