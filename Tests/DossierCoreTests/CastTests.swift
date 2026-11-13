import DossierCore
import Foundation
import Testing

@Suite("Cast (§3)")
struct CastTests {
  @Test("Every E-CAST fixture is refused and every other CAST.md loads")
  func loadOverEveryFixture() throws {
    let conformance = try Fixtures.conformance()
    let listed = conformance.fixtures.map(\.path)
    let onDisk = SpecTree.fixtureDirectories()
    #expect(Set(listed).symmetricDifference(onDisk).sorted().isEmpty, "listed and on disk differ: \(Set(listed).symmetricDifference(onDisk).sorted())")
    #expect(!listed.isEmpty)
    var refused = 0
    for entry in conformance.fixtures {
      let url = Fixtures.project(entry.path).appendingPathComponent("CAST.md")
      // §16.2: E-CAST also covers PROJECT.md and the locations index, whose fixtures have a
      // CAST.md that loads.
      let isAboutLocations = entry.path.hasPrefix("errors/E-CAST-project-") || entry.path.hasPrefix("errors/E-CAST-locations-")
      if entry.codes.contains("E-CAST"), !isAboutLocations {
        #expect(throws: DossierError.self, "\(entry.path)") { try Cast.load(url) }
        refused += 1
      } else {
        #expect(throws: Never.self, "\(entry.path)") { try Cast.load(url) }
      }
    }
    #expect(refused == 5)
  }

  @Test("A missing CAST.md is a thrown error, not an empty cast")
  func missingFile() {
    #expect(throws: DossierError.self) {
      try Cast.load(Fixtures.root.appendingPathComponent("no/such/CAST.md"))
    }
  }

  @Test("Fields read through Reparto, including one with no dossier")
  func fields() throws {
    let cast = try Cast.load(Fixtures.project("valid/complete-lead").appendingPathComponent("CAST.md"))
    #expect(cast.members.map(\.character) == ["WREN HALLOWAY", "COUNTER CLERK"])
    #expect(cast.members[0].fields.role?.rawValue == "lead")
    #expect(cast.members[1].pointer == nil)
    #expect(try cast.openBundle(for: cast.members[1]) == nil)
    let bundle = try #require(try cast.openBundle(for: cast.members[0]))
    #expect(bundle.manifest.character == "WREN HALLOWAY")
    #expect(bundle.member?.character == "WREN HALLOWAY")
  }

  @Test("§3's pointer resolution: lexical, and an NFC comparison")
  func pointerResolution() {
    let target = "characters/ODA.dossier/manifest.json"
    for raw in [
      target, "./characters/ODA.dossier/manifest.json", "characters//ODA.dossier/./manifest.json",
      "characters/x/../ODA.dossier/manifest.json", "characters/ODA.dossier/manifest.json/",
    ] {
      #expect(ManifestPointer(raw).points(at: target), "\(raw)")
    }
    #expect(!ManifestPointer("CHARACTERS/ODA.dossier/manifest.json").points(at: target))
    #expect(!ManifestPointer("characters/ODA.dossier").namesManifest)
    #expect(ManifestPointer(target).namesManifest)
    // SPEC-GAP: §3: a leading `..` is kept, so it can't match a path below the directory.
    #expect(ManifestPointer("../x/manifest.json").segments == ["..", "x", "manifest.json"])
    #expect(ManifestPointer("a/../../x/manifest.json").segments == ["..", "x", "manifest.json"])
    #expect(!ManifestPointer("../characters/ODA.dossier/manifest.json").points(at: target))
    // NFD in the pointer, NFC on the bundle's side.
    #expect(ManifestPointer("JOSE\u{0301}.dossier/manifest.json").points(at: "JOS\u{00C9}.dossier/manifest.json"))
  }

  @Test("valid/pointer-not-normalized opens its bundle")
  func unnormalizedPointer() throws {
    let cast = try Cast.load(Fixtures.project("valid/pointer-not-normalized").appendingPathComponent("CAST.md"))
    let member = try #require(cast.members.first { $0.character == "THE PILOT" })
    #expect(member.pointer?.points(at: "characters/THE PILOT.dossier/manifest.json") == true)
    #expect(try cast.openBundle(for: member)?.manifest.character == "THE PILOT")
  }

  @Test("W-POINTER fixtures don't open; the pointer that names no manifest says so")
  func badPointers() throws {
    let directory = try Cast.load(Fixtures.project("warnings/W-POINTER-directory").appendingPathComponent("CAST.md"))
    let member = try #require(directory.members.first { $0.pointer != nil })
    #expect(throws: DossierError.pointerNotManifest(member.pointer?.raw ?? "")) {
      try directory.openBundle(for: member)
    }
    let nowhere = try Cast.load(Fixtures.project("warnings/W-POINTER-nowhere").appendingPathComponent("CAST.md"))
    let lost = try #require(nowhere.members.first { $0.pointer != nil })
    #expect(throws: DossierError.self) { try nowhere.openBundle(for: lost) }
  }
}
