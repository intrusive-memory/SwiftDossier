import Dossier
import DossierCore
import Foundation
import Testing

@testable import DossierCLICore

private func makeBundle(_ project: TempProject) throws -> String {
  let ran = dossier(["create", "THE TINKER", "--role", "guest", "--in", project.characters.path])
  #expect(ran.status == 0)
  return project.path("characters/THE TINKER.dossier")
}

private func hiddenNames(_ bundle: String) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: bundle).filter { $0.hasPrefix(".") }.sorted()
}

private func status(_ bundle: String) -> UpdateStatus {
  UpdateStatus.read(bundle: URL(fileURLWithPath: bundle), at: Date())
}

@Suite("dossier update begin, renew, end")
struct UpdateSpanCommandTests {
  @Test("begin prints the id; renew and end take it; the marker is §5.7's throughout")
  func text() throws {
    let bundle = try makeBundle(try TempProject())
    let begun = dossier(["update", "begin", bundle, "--label", "a long job", "--writer", "a tool"])
    #expect(begun.status == 0)
    let id = begun.stdout.trimmingCharacters(in: .newlines)
    #expect(UpdateMarker.isValidID(id))
    #expect(try hiddenNames(bundle) == [UpdateMarker.name(forID: id)])
    #expect(status(bundle).activeMarkers.map(\.id) == [id])
    #expect(status(bundle).activeMarkers.map(\.label) == ["a long job"])
    #expect(status(bundle).activeMarkers.map(\.writer) == ["a tool"])

    let renewed = dossier(["update", "renew", bundle, id, "--ttl", "3600"])
    #expect(renewed.status == 0)
    #expect(renewed.stdout.hasPrefix("Renewed \(id) until "))
    #expect(status(bundle).isUpdating)

    let ended = dossier(["update", "end", bundle, id])
    #expect(ended.status == 0)
    #expect(try hiddenNames(bundle).isEmpty)
    #expect(!status(bundle).isUpdating)
  }

  @Test("--json is one object from each, and errors are the error object")
  func json() throws {
    let bundle = try makeBundle(try TempProject())
    let begun = try dossier(["update", "begin", bundle, "--ttl", "600", "--json"]).object()
    let id = try #require(begun["id"] as? String)
    let expiresAt = try #require(begun["expiresAt"] as? String)
    #expect(UpdateMarker.date(fromTimestamp: expiresAt) != nil)

    let renewed = try dossier(["update", "renew", bundle, id, "--json"]).object()
    #expect(renewed["id"] as? String == id)
    #expect(UpdateMarker.date(fromTimestamp: renewed["expiresAt"] as? String ?? "") != nil)

    #expect(try dossier(["update", "end", bundle, id, "--json"]).object()["ended"] as? String == id)

    let again = dossier(["update", "end", bundle, id, "--json"])
    #expect(again.status == 1)
    let error = try #require(try again.object()["error"] as? [String: Any])
    #expect(error["code"] as? String == "updateMarkerNotFound")
  }

  @Test("--ttl over 3600, or under 1, is a bad command line; a mid-path id is refused")
  func limits() throws {
    let bundle = try makeBundle(try TempProject())
    #expect(dossier(["update", "begin", bundle, "--ttl", "3601"]).status == 64)
    #expect(dossier(["update", "begin", bundle, "--ttl", "0"]).status == 64)
    #expect(dossier(["update", "renew", bundle, "x", "--ttl", "3601"]).status == 64)
    #expect(try hiddenNames(bundle).isEmpty)
    let escape = dossier(["update", "end", bundle, "../../manifest"])
    #expect(escape.status == 1)
    #expect(FileManager.default.fileExists(atPath: bundle + "/manifest.json"))
  }

  @Test("A bundle that can't be opened fails and writes nothing")
  func noBundle() throws {
    let project = try TempProject()
    #expect(dossier(["update", "begin", project.path("characters/NOBODY.dossier")]).status == 1)
    #expect(!FileManager.default.fileExists(atPath: project.path("characters/NOBODY.dossier")))
  }

  @Test("A mutation between begin and end changes the bundle, and the begun marker stays")
  func mutationBetween() throws {
    let bundle = try makeBundle(try TempProject())
    let id = dossier(["update", "begin", bundle]).stdout.trimmingCharacters(in: .newlines)
    #expect(dossier(["prompt", bundle, "identity", "--set", "a tinker"]).status == 0)
    #expect(try hiddenNames(bundle) == [UpdateMarker.name(forID: id)])
    #expect(dossier(["update", "end", bundle, id]).status == 0)
  }

  @Test("`dossier update` alone prints its own help")
  func help() {
    let ran = dossier(["update"])
    #expect(ran.status == 0)
    #expect(ran.stdout.contains("begin"))
    #expect(ran.stdout.contains("renew"))
  }
}

#if os(macOS)
  /// Serialized: `run` sets this process's signal handlers while its command runs.
  @Suite("dossier update run", .serialized)
  struct UpdateRunCommandTests {
    @Test("The command runs with the marker active, and it's gone afterwards")
    func holds() throws {
      let project = try TempProject()
      let bundle = try makeBundle(project)
      let copy = project.path("seen.json")
      let ran = dossier(["update", "run", bundle, "--", "/bin/sh", "-c", #"cat "$0"/.update-*.json > "$1""#, bundle, copy])
      #expect(ran.status == 0)
      #expect(try hiddenNames(bundle).isEmpty)

      let object = try #require(UpdateMarker.object(in: Data(contentsOf: URL(fileURLWithPath: copy))))
      #expect(object["writer"]?.stringValue == "SwiftDossier")
      let expiresAt = try #require(UpdateMarker.expiresAt(of: object))
      #expect(UpdateMarker.isActive(expiresAt: expiresAt, at: Date()))
      #expect(object["label"]?.stringValue?.hasPrefix("/bin/sh -c") == true, "the command, with no --label")
    }

    @Test("--label is the marker's")
    func label() throws {
      let project = try TempProject()
      let bundle = try makeBundle(project)
      let copy = project.path("seen.json")
      let ran = dossier([
        "update", "run", bundle, "--label", "rendering", "--", "/bin/sh", "-c", #"cat "$0"/.update-*.json > "$1""#, bundle, copy,
      ])
      #expect(ran.status == 0)
      let object = try #require(UpdateMarker.object(in: Data(contentsOf: URL(fileURLWithPath: copy))))
      #expect(object["label"]?.stringValue == "rendering")
    }

    @Test("A failing command's status comes through, and the marker is removed", arguments: [1, 3, 64, 255] as [Int32])
    func failing(_ code: Int32) throws {
      let bundle = try makeBundle(try TempProject())
      let ran = dossier(["update", "run", bundle, "--", "/bin/sh", "-c", "exit \(code)"])
      #expect(ran.status == code)
      #expect(try hiddenNames(bundle).isEmpty)
    }

    @Test("A command killed by a signal gives 128 + the signal, and the marker is removed")
    func killed() throws {
      let bundle = try makeBundle(try TempProject())
      let ran = dossier(["update", "run", bundle, "--", "/bin/sh", "-c", "kill -KILL $$"])
      #expect(ran.status == 128 + SIGKILL)
      #expect(try hiddenNames(bundle).isEmpty)
    }

    @Test("SIGTERM to dossier goes on to the command, and the marker is still removed")
    func forwardsTerm() throws {
      let bundle = try makeBundle(try TempProject())
      // If it weren't passed on, this would run for a minute and exit 0.
      let ran = dossier(["update", "run", bundle, "--", "/bin/sh", "-c", "kill -TERM $PPID; exec /bin/sleep 60"])
      #expect(ran.status == 128 + SIGTERM)
      #expect(try hiddenNames(bundle).isEmpty)
    }

    @Test("Nothing is read by a shell: metacharacters reach the command as they are")
    func noShell() throws {
      let project = try TempProject()
      let bundle = try makeBundle(project)
      let copy = project.path("args.txt")
      let canary = project.path("canary")
      let hostile = ["$(touch \(canary))", "`touch \(canary)`", "; touch \(canary)", "*", "a b", "--json", "--"]
      let ran = dossier(
        ["update", "run", bundle, "--", "/bin/sh", "-c", #"printf '%s\n' "$@" > "$0""#, copy] + hostile)
      #expect(ran.status == 0)
      #expect(ran.stdout.isEmpty, "--json after -- is the command's")
      #expect(!FileManager.default.fileExists(atPath: canary))
      #expect(try String(contentsOfFile: copy, encoding: .utf8) == hostile.joined(separator: "\n") + "\n")

      let line = dossier(["update", "run", bundle, "--", "/usr/bin/true; touch \(canary)"])
      #expect(line.status == 127, "one argument is one executable's name")
      #expect(!FileManager.default.fileExists(atPath: canary))
    }

    @Test("A command that isn't there gives 127, one that can't run 126, and neither leaves a marker")
    func notRun() throws {
      let project = try TempProject()
      let bundle = try makeBundle(project)
      let missing = dossier(["update", "run", bundle, "--", "/nonexistent/command"])
      #expect(missing.status == 127)
      #expect(missing.stderr.contains("can't run /nonexistent/command"))
      let notOnPath = try dossier(["update", "run", bundle, "--json", "--", "no-such-command-here"]).object()
      #expect((notOnPath["error"] as? [String: Any])?["code"] as? String == "command-not-run")

      let plain = project.path("plain.txt")
      try Data("text".utf8).write(to: URL(fileURLWithPath: plain))
      #expect(dossier(["update", "run", bundle, "--", plain]).status == 126)
      #expect(try hiddenNames(bundle).isEmpty)
    }

    @Test("A command with no slash is found on PATH")
    func path() throws {
      let bundle = try makeBundle(try TempProject())
      #expect(dossier(["update", "run", bundle, "--", "true"]).status == 0)
      #expect(dossier(["update", "run", bundle, "--", "false"]).status == 1)
    }

    @Test("--json is one object, with the command's stdout kept out of it, whatever the status")
    func json() throws {
      let bundle = try makeBundle(try TempProject())
      let ran = dossier(["update", "run", bundle, "--json", "--", "/bin/sh", "-c", "echo not json; exit 5"])
      #expect(ran.status == 5)
      let object = try ran.object()
      #expect(object["exitStatus"] as? Int == 5)
      #expect((object["command"] as? [String])?.first == "/bin/sh")
      #expect(try hiddenNames(bundle).isEmpty)
    }

    @Test("A bad command line, or a bundle that can't be opened, runs nothing")
    func refused() throws {
      let project = try TempProject()
      let bundle = try makeBundle(project)
      #expect(dossier(["update", "run", bundle]).status == 64)
      #expect(dossier(["update", "run", bundle, "--"]).status == 64)
      let canary = project.path("canary")
      let ran = dossier(["update", "run", project.path("characters/NOBODY.dossier"), "--", "/usr/bin/touch", canary])
      #expect(ran.status == 1)
      #expect(!FileManager.default.fileExists(atPath: canary))
    }

    @Test("A bundle validates clean after a run: nothing is left that a validator could see")
    func validAfter() throws {
      let bundle = try makeBundle(try TempProject())
      let ran = dossier(["update", "run", bundle, "--", "/usr/bin/true"])
      #expect(ran.status == 0)
      #expect(dossier(["validate", bundle]).status == 0)
    }
  }
#endif
