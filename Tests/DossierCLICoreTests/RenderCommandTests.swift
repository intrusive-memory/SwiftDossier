import Foundation
import Testing

@testable import DossierCLICore

@Suite("dossier render")
struct RenderCommandTests {
  private let bundleName = "characters/WREN HALLOWAY.dossier"
  private let pageName = "WREN HALLOWAY-dossier.html"

  private func page(_ project: TempProject) -> String { project.path("\(bundleName)/\(pageName)") }

  @Test("A bundle, with --cast")
  func bundleWithCast() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let before = try sha256(of: page(project))
    let ran = dossier(["render", project.path(bundleName), "--cast", project.cast.path, "--json"])
    #expect(ran.status == 0, "\(ran.stdout)")
    let object = try ran.object()
    #expect(object["character"] as? String == "WREN HALLOWAY")
    #expect(object["status"] as? String == "rendered")
    #expect(object["role"] as? String == "lead")
    #expect(object["page"] as? String == page(project))
    #expect((object["sizeBytes"] as? Int ?? 0) > 100_000)
    #expect((object["banner"] as? [Any])?.isEmpty == true)
    #expect(try sha256(of: page(project)) != before)

    let first = try sha256(of: page(project))
    let again = dossier(["render", project.path(bundleName), "--cast", project.cast.path])
    #expect(again.status == 0, "\(again.stderr)")
    #expect(again.stdout.contains("Rendered"))
    #expect(try sha256(of: page(project)) == first)

    let validated = dossier(["validate", project.path(bundleName), "--cast", project.cast.path, "--json"])
    let findings = try validated.object()["findings"] as? [[String: Any]] ?? []
    #expect(findings.filter { $0["level"] as? String == "error" }.isEmpty, "\(findings)")
    #expect(!findings.contains { $0["code"] as? String == "W-STALE" }, "\(findings)")
  }

  @Test("A bundle with no --cast fails with cast-required, even with a CAST.md in its parent and grandparent")
  func castRequired() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    // The grandparent already holds the project's CAST.md; put one in the parent too.
    try FileManager.default.copyItem(at: project.cast, to: project.characters.appendingPathComponent("CAST.md"))
    let before = try sha256(of: page(project))
    let ran = dossier(["render", project.path(bundleName)])
    #expect(ran.status == 1)
    #expect(ran.stderr.contains("--cast CAST.md"))
    let json = dossier(["render", project.path(bundleName), "--json"])
    #expect(json.status == 1)
    let error = try #require(try json.object()["error"] as? [String: Any])
    #expect(error["code"] as? String == "cast-required")
    #expect(try sha256(of: page(project)) == before)

    let withCast = dossier(["render", project.path(bundleName), "--cast", project.cast.path])
    #expect(withCast.status == 0, "\(withCast.stderr)")
    #expect(try sha256(of: page(project)) != before)
  }

  @Test("A member that doesn't point at the bundle is refused")
  func wrongMember() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let before = try sha256(of: page(project))
    let other = project.root.appendingPathComponent("OTHER.md")
    try Data(plainCast.utf8).write(to: other)
    let ran = dossier(["render", project.path(bundleName), "--cast", other.path, "--json"])
    #expect(ran.status == 1)
    let error = try #require(try ran.object()["error"] as? [String: Any])
    #expect(error["code"] as? String == "member-not-found")
    #expect(try sha256(of: page(project)) == before)
  }

  @Test("--cast renders every member with a dossier and reports each")
  func everyMember() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let ran = dossier(["render", "--cast", project.cast.path, "--json"])
    #expect(ran.status == 0, "\(ran.stdout)")
    let members = try #require(try ran.object()["members"] as? [[String: Any]])
    #expect(members.map { $0["character"] as? String } == ["WREN HALLOWAY"])
    #expect(members[0]["status"] as? String == "rendered")
    #expect(try ran.object()["error"] == nil)

    let plain = dossier(["render", "--cast", project.cast.path])
    #expect(plain.status == 0, "\(plain.stderr)")
    #expect(plain.stdout.contains("WREN HALLOWAY: rendered"))
    #expect(plain.stdout.contains("1 of 1 rendered"))
  }

  @Test("--cast goes on after a failure, reports it, and exits non-zero")
  func oneFails() throws {
    let project = try TempProject(copyOf: "valid/complete-lead")
    let goodPage = page(project)
    var text = String(decoding: try project.castBytes(), as: UTF8.self)
    text = text.replacingOccurrences(
      of: "- character: COUNTER CLERK\n  role: background\n  voices: {}\n",
      with: "- character: COUNTER CLERK\n  role: background\n  voices: {}\n  manifest: characters/COUNTER CLERK.dossier/manifest.json\n")
    try Data(text.utf8).write(to: project.cast)
    let before = try sha256(of: goodPage)
    let ran = dossier(["render", "--cast", project.cast.path, "--json"])
    #expect(ran.status == 1, "\(ran.stdout)")
    let object = try ran.object()
    let members = try #require(object["members"] as? [[String: Any]])
    #expect(members.map { $0["status"] as? String } == ["rendered", "failed"])
    #expect(members[1]["error"] is [String: Any])
    #expect(object["error"] is [String: Any])
    #expect(try sha256(of: goodPage) != before)

    let plain = dossier(["render", "--cast", project.cast.path])
    #expect(plain.status == 1)
    #expect(plain.stderr.contains("COUNTER CLERK: failed"))
    #expect(plain.stdout.contains("1 of 2 rendered"))
  }

  @Test("A failed render reports as an error, with a non-zero status")
  func failure() throws {
    let project = try TempProject(copyOf: "valid/empty-background")
    let bundle = project.path("characters/BYSTANDER #2.dossier")
    let ran = dossier(["render", bundle, "--cast", project.cast.path, "--json"])
    #expect(ran.status == 1)
    #expect(try ran.object()["error"] is [String: Any])
  }

  @Test("It needs a bundle or a CAST.md")
  func usage() {
    #expect(dossier(["render"]).status == 64)
    #expect(dossier(["render", "--json"]).status == 64)
  }

  @Test("add --kind dossier gets the template from this tool, and is then short of a member")
  func addPage() throws {
    let project = try TempProject(copyOf: "valid/shape-within-tolerance")
    let name = try #require(try FileManager.default.contentsOfDirectory(atPath: project.characters.path).first { $0.hasSuffix(".dossier") })
    let html = project.root.appendingPathComponent("some.html")
    try Data("<!DOCTYPE html>".utf8).write(to: html)
    let ran = dossier(["add", project.characters.appendingPathComponent(name).path, html.path, "--kind", "dossier", "--json"])
    #expect(ran.status == 1)
    let error = try #require(try ran.object()["error"] as? [String: Any])
    #expect((error["message"] as? String)?.contains("castMember") == true, "\(error)")
  }

  @Test("migrate stays unavailable, and the help no longer says render is")
  func helpText() {
    #expect(dossier(["migrate", "somewhere"]).status == 69)
    let help = dossier(["--help"]).stdout
    #expect(help.contains("migrate gives 69"))
    #expect(!help.contains("render and migrate"))
    #expect(dossier(["render", "--help"]).stdout.contains("--cast"))
  }
}
