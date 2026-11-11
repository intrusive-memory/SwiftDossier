import Foundation
import Testing

@testable import DossierCLICore

@Suite("dossier create, add, select, reject, remove, list, prompt, refresh, candidates")
struct CommandTests {
  @Test("create makes the bundle and the CAST.md member; --json is one object")
  func create() throws {
    let project = try TempProject(castText: plainCast)
    let ran = dossier(
      ["create", "The  Tinker", "--role", "guest", "--in", project.characters.path, "--cast", project.cast.path, "--json"])
    #expect(ran.status == 0)
    let object = try ran.object()
    #expect(object["character"] as? String == "THE TINKER")
    #expect(object["memberAdded"] as? Bool == true)
    #expect(object["castReport"] != nil)
    #expect(FileManager.default.fileExists(atPath: project.path("characters/THE TINKER.dossier/manifest.json")))
    #expect(String(decoding: try project.castBytes(), as: UTF8.self).contains("THE TINKER"))
  }

  @Test("create shows the SD-12 report on stderr before CAST.md is written, and proceeds")
  func createReportsBeforeWriting() throws {
    // Not written by Reparto, with a voices value Reparto drops: both must be said first.
    let text = """
      ---
      type: cast
      schemaVersion: 1
      cast:
      - character: THE WRONG TYPE
        voices: {apple: 5, voxalta: a.vox}
      ---
      """ + "\n"
    let project = try TempProject(castText: text)
    let before = try project.castBytes()
    let sink = BufferSink()
    let atReport = LockedBox<Data?>(nil)
    sink.onError = { _ in atReport.set(try? Data(contentsOf: project.cast)) }

    let ran = dossier(
      ["create", "THE TINKER", "--role", "guest", "--in", project.characters.path, "--cast", project.cast.path],
      sink: sink)
    #expect(ran.status == 0)
    #expect(ran.stderr.contains("reparto canonicalize --apply"))
    #expect(ran.stderr.contains("voices.apple"))
    #expect(ran.stdout.contains("Created"))
    #expect(atReport.value == before, "CAST.md was unchanged when the report was shown")
    #expect(try project.castBytes() != before, "and the write then proceeded")
  }

  @Test("create with --json carries the report in the object and prints nothing on stderr")
  func createJSONReport() throws {
    let text = """
      ---
      type: cast
      schemaVersion: 1
      cast:
      - character: THE WRONG TYPE
        voices: {apple: 5}
      ---
      """ + "\n"
    let project = try TempProject(castText: text)
    let ran = dossier(
      ["create", "THE TINKER", "--role", "guest", "--in", project.characters.path, "--cast", project.cast.path, "--json"])
    let report = try #require(try ran.object()["castReport"] as? [String: Any])
    #expect((report["exceptions"] as? [String])?.isEmpty == false)
    #expect((report["suggestion"] as? String)?.contains("reparto canonicalize --apply") == true)
    #expect(ran.stderr.isEmpty)
  }

  @Test("create refuses a role that is no tier, as a JSON error with a non-zero exit")
  func createRefusal() throws {
    let project = try TempProject()
    let ran = dossier(["create", "THE TINKER", "--role", "hero", "--in", project.characters.path, "--json"])
    #expect(ran.status == 1)
    let error = try #require(try ran.object()["error"] as? [String: Any])
    #expect(error["code"] as? String == "roleNotATier")
    #expect(!FileManager.default.fileExists(atPath: project.path("characters/THE TINKER.dossier")))
  }

  @Test("create --cast <missing> fails with castUnreadable and creates no file at that path")
  func createMissingCast() throws {
    let project = try TempProject()
    let missing = project.path("nowhere/CAST.md")
    let ran = dossier(["create", "THE TINKER", "--role", "guest", "--in", project.characters.path, "--cast", missing, "--json"])
    #expect(ran.status != 0)
    let error = try #require(try ran.object()["error"] as? [String: Any])
    #expect(error["code"] as? String == "castUnreadable")
    #expect(!FileManager.default.fileExists(atPath: missing))
  }

  @Test("two creates with one --cast leave one CAST.md with both members, and no other CAST.md")
  func createTwiceOneCast() throws {
    let project = try TempProject(castText: plainCast)
    for name in ["THE TINKER", "THE WEAVER"] {
      let ran = dossier(["create", name, "--role", "guest", "--in", project.characters.path, "--cast", project.cast.path])
      #expect(ran.status == 0, "\(ran.stderr)")
    }
    let text = String(decoding: try project.castBytes(), as: UTF8.self)
    #expect(text.contains("THE TINKER") && text.contains("THE WEAVER"))
    let found = FileManager.default.enumerator(atPath: project.root.path)?
      .compactMap { $0 as? String }.filter { $0.hasSuffix("CAST.md") } ?? []
    #expect(found == ["CAST.md"], "\(found)")
  }

  /// A project with one bundle, and a PNG to add.
  private func bundleWithImage() throws -> (project: TempProject, bundle: String, image: URL) {
    let project = try TempProject()
    let made = dossier(["create", "THE TINKER", "--role", "guest", "--in", project.characters.path])
    #expect(made.status == 0)
    let image = try writePNG(named: "front.png", in: project.root.appendingPathComponent("outside"))
    return (project, project.path("characters/THE TINKER.dossier"), image)
  }

  @Test("add, list, select, reject, remove round trip; remove asks for --yes")
  func lifecycle() throws {
    let (_, bundle, image) = try bundleWithImage()
    let anchor = try writePNG(named: "anchor.png", in: image.deletingLastPathComponent(), shade: 15)
    #expect(dossier(["add", bundle, anchor.path, "--kind", "portrait", "--select"]).status == 0)
    let first = dossier(["add", bundle, image.path, "--kind", "view", "--variant", "front", "--select", "--json"])
    #expect(first.status == 0, "\(first.stdout) \(first.stderr)")
    let asset = try #require(try first.object()["asset"] as? [String: Any])
    let path = try #require(asset["path"] as? String)
    #expect(path.hasPrefix("images/view-front-"))
    #expect(asset["status"] as? String == "selected")

    let second = try writePNG(named: "front-two.png", in: image.deletingLastPathComponent(), shade: 90)
    let other = dossier(["add", bundle, second.path, "--kind", "view", "--variant", "front", "--json"])
    let otherPath = try #require((try other.object()["asset"] as? [String: Any])?["path"] as? String)

    let listed = dossier(["list", bundle, "--kind", "view", "--status", "selected", "--json"])
    #expect((try listed.object()["assets"] as? [[String: Any]])?.count == 1)

    #expect(dossier(["select", bundle, otherPath]).status == 0)
    let now = dossier(["list", bundle, "--kind", "view", "--status", "selected", "--json"])
    #expect((try now.object()["assets"] as? [[String: Any]])?.first?["path"] as? String == otherPath)

    let rejected = dossier(["reject", bundle, path, "--json"])
    #expect((try rejected.object()["asset"] as? [String: Any])?["status"] as? String == "rejected")

    let refused = dossier(["remove", bundle, path, "--json"])
    #expect(refused.status == 1)
    #expect((try refused.object()["error"] as? [String: Any])?["code"] as? String == "confirmation-required")
    #expect(FileManager.default.fileExists(atPath: bundle + "/" + path))

    #expect(dossier(["remove", bundle, path, "--yes"]).status == 0)
    #expect(!FileManager.default.fileExists(atPath: bundle + "/" + path))
    #expect(dossier(["validate", bundle]).status == 0)
  }

  @Test("add folds a sidecar in, with --reference-roles and --provenance")
  func addWithSidecar() throws {
    let (project, bundle, image) = try bundleWithImage()
    let portrait = dossier(["add", bundle, image.path, "--kind", "portrait", "--select", "--json"])
    let portraitAsset = try #require(try portrait.object()["asset"] as? [String: Any])
    let portraitPath = try #require(portraitAsset["path"] as? String)
    let portraitHash = try #require((portraitPath.split(separator: "-").last).map { String($0.dropLast(4)) })

    let view = try writePNG(named: "side.png", in: project.root.appendingPathComponent("outside"), shade: 120)
    let sidecar = project.root.appendingPathComponent("outside/side.png.json")
    let record = """
      {"provider": "invented", "prompt": "a lamp", "seed": 7, "generatedAt": "2026-03-04T05:06:07Z",
       "references": [{"sha256": "\(try sha256(of: bundle + "/" + portraitPath))", "source": "/Volumes/nowhere/ref.png"}]}
      """
    try Data(record.utf8).write(to: sidecar)
    let ran = dossier([
      "add", bundle, view.path, "--kind", "view", "--variant", "profile", "--sidecar", sidecar.path,
      "--reference-roles", "portrait", "--provenance", "{\"notes\": \"kept\"}", "--json",
    ])
    #expect(ran.status == 0, "\(ran.stdout) \(ran.stderr)")
    let asset = try #require(try ran.object()["asset"] as? [String: Any])
    let provenance = try #require(asset["provenance"] as? [String: Any])
    #expect(provenance["seed"] as? Int == 7)
    #expect(provenance["notes"] as? String == "kept")
    let reference = try #require((provenance["references"] as? [[String: Any]])?.first)
    #expect(reference["role"] as? String == "portrait")
    #expect(reference["path"] as? String == portraitPath)
    #expect(reference["source"] == nil, "an absolute source path is never recorded")
    _ = portraitHash
  }

  @Test("prompt sets from --set and --file, and prints")
  func prompt() throws {
    let (project, bundle, _) = try bundleWithImage()
    #expect(dossier(["prompt", bundle, "identity", "--set", "A tall figure."]).status == 0)
    #expect(dossier(["prompt", bundle, "identity"]).stdout == "A tall figure.\n")
    let file = project.root.appendingPathComponent("subject.txt")
    try Data("woman".utf8).write(to: file)
    let filed = dossier(["prompt", bundle, "subject", "--file", file.path])
    #expect(filed.status == 0, "\(filed.stdout) \(filed.stderr)")
    let json = dossier(["prompt", bundle, "subject", "--json"])
    #expect(try json.object()["text"] as? String == "woman")
    #expect(dossier(["prompt", bundle, "colour"]).status == 64)
  }

  @Test("refresh adopts a stray file; candidates lists .generations")
  func refreshAndCandidates() throws {
    let (project, bundle, _) = try bundleWithImage()
    _ = try writePNG(named: "portrait-0001.png", in: project.characters.appendingPathComponent(".generations/THE TINKER"))
    let found = dossier(["candidates", bundle, "--json"])
    let names = (try found.object()["candidates"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    #expect(names == ["portrait-0001.png"])
    #expect(dossier(["candidates", bundle, "--kind", "view"]).stdout.isEmpty)

    _ = try writePNG(named: "stray.png", in: URL(fileURLWithPath: bundle).appendingPathComponent("images"), shade: 200)
    let refreshed = dossier(["refresh", bundle, "--json"])
    #expect(refreshed.status == 0, "\(refreshed.stdout)")
    let object = try refreshed.object()
    #expect(object["adopted"] is [Any])
    #expect(object["unclassified"] is [Any])
  }

  @Test("migrate exists and says it is not available")
  func notAvailable() throws {
    let migrate = dossier(["migrate", "somewhere", "--apply", "--json"])
    #expect(migrate.status == 69)
    let message = try #require((try migrate.object()["error"] as? [String: Any])?["message"] as? String)
    #expect(message.contains("phase 4"))
  }

  @Test("a bad command line is a usage error, as JSON when asked")
  func usage() throws {
    #expect(dossier(["add", "--json"]).status == 64)
    let ran = dossier(["add", "--json"])
    #expect((try ran.object()["error"] as? [String: Any])?["code"] as? String == "usage")
    #expect(dossier(["list"]).stderr.contains("error"))
  }
}

@Suite("dossier face")
struct FaceCommandTests {
  @Test("--box crops the selected portrait, records the box, and a second run changes nothing")
  func facesFromBox() throws {
    let project = try TempProject(castText: plainCast)
    #expect(dossier(["create", "THE LAMPLIGHTER", "--role", "lead", "--in", project.path("characters")]).status == 0)
    let bundle = project.path("characters/THE LAMPLIGHTER.dossier")
    let portrait = try writePNG(named: "portrait.png", in: project.root)
    #expect(dossier(["add", bundle, portrait.path, "--kind", "portrait", "--select"]).status == 0)

    let first = dossier(["face", bundle, "--box", "2,4,8,10", "--json"])
    #expect(first.status == 0, "\(first.stderr)\(first.stdout)")
    let object = try first.object()
    let crop = try #require(object["crop"] as? [String: Any])
    // side = round(1.8 * 10) = 18 = the portrait's width; top = round(9 - 9) = 0.
    #expect(crop["side"] as? Int == 18)
    #expect(crop["left"] as? Int == 0)
    #expect(crop["top"] as? Int == 0)
    #expect(object["written"] as? Bool == true)
    #expect(object["handSet"] as? Bool == true)

    let second = dossier(["face", bundle, "--box", "2,4,8,10", "--json"])
    #expect(second.status == 0)
    #expect(try second.object()["written"] as? Bool == false)
    let validated = dossier(["validate", bundle])
    #expect(validated.status != 2, "\(validated.stdout)")
  }

  @Test("A bad --box is a usage error")
  func badBox() throws {
    let project = try TempProject(castText: plainCast)
    for box in ["1,2,3", "a,b,c,d", "1,2,0,4", "-1,2,3,4"] {
      let ran = dossier(["face", project.path("none.dossier"), "--box", box])
      #expect(ran.status != 0)
      #expect(ran.stderr.contains("--box"), "\(box): \(ran.stderr)")
    }
  }

  @Test("A bundle with no selected portrait is a reported error")
  func noPortrait() throws {
    let project = try TempProject(castText: plainCast)
    #expect(dossier(["create", "THE LAMPLIGHTER", "--role", "lead", "--in", project.path("characters")]).status == 0)
    let ran = dossier(["face", project.path("characters/THE LAMPLIGHTER.dossier"), "--box", "1,1,5,5", "--json"])
    #expect(ran.status == 1)
    #expect(ran.stdout.contains("\"error\""))
  }
}

@Suite("Help names the command asked about")
struct HelpTests {
  private static let commands = [
    "create", "add", "select", "reject", "remove", "list", "prompt", "validate", "refresh",
    "candidates", "face", "check", "update", "render", "migrate",
  ]

  @Test("--help, -h and help <command>", arguments: commands)
  func eachCommand(command: String) {
    for line in [[command, "--help"], [command, "-h"], ["help", command]] {
      let ran = dossier(line)
      #expect(ran.status == 0, "\(line)")
      #expect(ran.stdout.contains("USAGE: dossier \(command)"), "\(line): \(ran.stdout)")
      #expect(!ran.stdout.contains("Show subcommand help"), "\(line)")
    }
  }

  @Test("A nested command, and a flag or argument before --help")
  func nested() {
    #expect(dossier(["update", "begin", "--help"]).stdout.contains("USAGE: dossier update begin"))
    #expect(dossier(["help", "update", "renew"]).stdout.contains("USAGE: dossier update renew"))
    #expect(dossier(["add", "some.dossier", "--help"]).stdout.contains("USAGE: dossier add"))
  }

  @Test("The root, and a command with no such subcommand")
  func root() {
    #expect(dossier([]).stdout.contains("USAGE: dossier <subcommand>"))
    #expect(dossier(["--help"]).stdout.contains("USAGE: dossier <subcommand>"))
    #expect(dossier(["help"]).stdout.contains("USAGE: dossier <subcommand>"))
  }
}
