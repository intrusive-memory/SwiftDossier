import Foundation
import Testing

@testable import DossierCLICore

@Suite("dossier preview")
struct PreviewCommandTests {
  private let bundleName = "characters/THE LAMPLIGHTER.dossier"

  /// `dossier` for a command that suspends.
  private func run(_ arguments: [String]) async -> Ran {
    let sink = BufferSink()
    let status = await DossierCLI.run(arguments, sink: sink)
    return Ran(status: status, stdout: sink.stdout, stderr: sink.stderr)
  }

  /// A project with one invented character, `CHARACTER.md` and a CAST.md beside the bundle.
  private func project() throws -> TempProject {
    let project = try TempProject(castText: plainCast)
    let created = dossier(
      ["create", "THE LAMPLIGHTER", "--role", "lead", "--in", project.characters.path, "--cast", project.cast.path])
    #expect(created.status == 0, "\(created.stderr)")
    let character = project.root.appendingPathComponent("\(bundleName)/CHARACTER.md")
    if !FileManager.default.fileExists(atPath: character.path) {
      try Data("---\nname: THE LAMPLIGHTER\n---\n\nShe lights the lamps.\n".utf8).write(to: character)
    }
    return project
  }

  private func previewDirectory(_ project: TempProject) -> String { project.path("\(bundleName)/.preview") }

  @Test("The first run builds and stores; the second is a hit with the same key")
  func storesThenHits() async throws {
    let project = try project()
    let first = await run(["preview", project.path(bundleName), "--json"])
    #expect(first.status == 0, "\(first.stderr)")
    let one = try first.object()
    #expect(one["hit"] as? Bool == false)
    let page = try #require(one["page"] as? String)
    #expect(page.hasPrefix(previewDirectory(project)))
    #expect(FileManager.default.fileExists(atPath: page))

    let second = await run(["preview", project.path(bundleName), "--json"])
    let two = try second.object()
    #expect(two["hit"] as? Bool == true)
    #expect(two["key"] as? String == one["key"] as? String)
    #expect(two["page"] as? String == page)
    #expect(two["character"] as? String == "THE LAMPLIGHTER")

    let text = await run(["preview", project.path(bundleName)])
    #expect(text.stdout == page + "\n")
  }

  @Test("--to writes the page there and leaves no .preview/")
  func toFile() async throws {
    let project = try project()
    let target = project.path("out.html")
    let ran = await run(["preview", project.path(bundleName), "--to", target, "--json"])
    #expect(ran.status == 0, "\(ran.stderr)")
    let object = try ran.object()
    #expect(object["page"] as? String == target)
    #expect(object["hit"] as? Bool == false)
    #expect(try String(contentsOfFile: target, encoding: .utf8).contains("<html"))
    #expect(!FileManager.default.fileExists(atPath: previewDirectory(project)))
  }

  @Test("--to with --rebuild is a usage error and writes nothing")
  func toWithRebuild() async throws {
    let project = try project()
    let target = project.path("out.html")
    let ran = await run(["preview", project.path(bundleName), "--to", target, "--rebuild", "--json"])
    #expect(ran.status == 64)
    #expect(!FileManager.default.fileExists(atPath: target))
    #expect(!FileManager.default.fileExists(atPath: previewDirectory(project)))
  }

  @Test("--rebuild on an unchanged bundle builds again and gets the same key")
  func rebuildUnchanged() async throws {
    let project = try project()
    let first = try await run(["preview", project.path(bundleName), "--json"]).object()
    let rebuilt = await run(["preview", project.path(bundleName), "--rebuild", "--json"])
    #expect(rebuilt.status == 0, "\(rebuilt.stderr)")
    let object = try rebuilt.object()
    #expect(object["hit"] as? Bool == false)
    #expect(object["key"] as? String == first["key"] as? String)
    #expect(object["refreshError"] == nil)
  }

  @Test("--rebuild with an asset's file missing reports refreshError and exits 0")
  func rebuildMissingAsset() async throws {
    let project = try project()
    let image = try writePNG(named: "lamp.png", in: project.root.appendingPathComponent("outside"))
    let added = dossier(["add", project.path(bundleName), image.path, "--kind", "portrait", "--select", "--json"])
    #expect(added.status == 0, "\(added.stderr)")
    let path = try #require((try added.object()["asset"] as? [String: Any])?["path"] as? String)
    try FileManager.default.removeItem(atPath: project.path("\(bundleName)/\(path)"))

    let ran = await run(["preview", project.path(bundleName), "--rebuild", "--json"])
    #expect(ran.status == 0, "\(ran.stdout) \(ran.stderr)")
    let object = try ran.object()
    let refresh = try #require(object["refreshError"] as? [String: Any])
    #expect(refresh["code"] is String)
    #expect(!(refresh["message"] as? String ?? "").isEmpty)
    #expect(FileManager.default.fileExists(atPath: try #require(object["page"] as? String)))
  }

  @Test("Without --cast there is no member, even with a CAST.md beside the bundle; --cast gives one")
  func member() async throws {
    let project = try project()
    // A CAST.md in the parent of the bundle, where a search would have found it.
    try FileManager.default.copyItem(at: project.cast, to: project.characters.appendingPathComponent("CAST.md"))
    let without = try await run(["preview", project.path(bundleName), "--json"]).object()
    #expect(without["member"] as? Bool == false)

    let with = await run(["preview", project.path(bundleName), "--cast", project.cast.path, "--json"])
    #expect(with.status == 0, "\(with.stderr)")
    let object = try with.object()
    #expect(object["member"] as? Bool == true)
    #expect(object["key"] as? String != without["key"] as? String)

    let rebuilt = try await run(["preview", project.path(bundleName), "--rebuild", "--json"]).object()
    #expect(rebuilt["member"] as? Bool == false, "--rebuild without --cast keeps no member")
  }

  @Test("A missing CHARACTER.md exits 1 and stores nothing")
  func missingCharacter() async throws {
    let project = try project()
    try FileManager.default.removeItem(atPath: project.path("\(bundleName)/CHARACTER.md"))
    for extra in [[], ["--rebuild"], ["--to", project.path("out.html")]] {
      let ran = await run(["preview", project.path(bundleName), "--json"] + extra)
      #expect(ran.status == 1, "\(extra): \(ran.stdout)")
      #expect(try ran.object()["error"] != nil)
    }
    #expect(!FileManager.default.fileExists(atPath: project.path("out.html")))
  }
}
