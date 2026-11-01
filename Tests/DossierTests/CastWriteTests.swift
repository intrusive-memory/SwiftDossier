import DossierCore
import Foundation
import SwiftReparto
import Testing

@testable import Dossier

/// A project in a temporary directory. Invented characters only.
struct SyntheticProject {
  let root: URL
  var cast: URL { root.appendingPathComponent("CAST.md") }
  var characters: URL { root.appendingPathComponent("characters", isDirectory: true) }

  init(castText: String? = nil) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CastWriteTests-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: characters, withIntermediateDirectories: true)
    if let castText { try Data(castText.utf8).write(to: cast) }
  }

  func castBytes() throws -> Data { try Data(contentsOf: cast) }

  func hashes() throws -> [String: String] {
    Dictionary(uniqueKeysWithValues: try Cast.load(cast).members.map { ($0.character, $0.hash) })
  }

  /// The front matter's lines before the first member, one string per member, and the body.
  func layout() throws -> (header: String, members: [String], body: String) {
    let text = String(decoding: try castBytes(), as: UTF8.self)
    let split = try #require(FrontMatter.split(text))
    var header = ""
    var members: [String] = []
    // Split on line ends, so the last member's block doesn't differ for being last.
    for line in split.yaml.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) {
      if line.hasPrefix("- character:") {
        members.append(line + "\n")
      } else if members.isEmpty {
        header += line + "\n"
      } else {
        members[members.count - 1] += line + "\n"
      }
    }
    return (header, members, split.body)
  }
}

func expectManifestValidates(_ bundle: DossierBundle) throws {
  let data = try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json"))
  let violations = try SchemaEvaluator.pinned()
    .validate(try JSONValue.parse(data), against: "manifest-v2.schema.json")
  #expect(violations.isEmpty, "\(violations)")
}

/// Every layout quirk at once: key order, quoting, comments, multi-line values, odd scalars,
/// a legacy key, a scalar voice, CRLF and no final newline in the body.
let quirkyCast =
  """
  ---
  # A comment before the keys, which come in an unusual order.
  schemaVersion: 1
  cast:
    # The list is indented.
    - role: lead   # Before the name.
      "character": "THE LAMPLIGHTER"
      voiceDescription: >
        A folded voice
        over two lines.
      bio: |
        Keeps a ledger.
          With one indented line.
      manifest: null
    - character: 'THE ORGAN GRINDER'
      language: no
      actor: 5
      voices: {VoxAlta: voices/grinder.vox}
      aFloat: 1.5
      trailingZero: 1.50
      anOctal: 0755
      aDate: 2026-08-01
      aYes: yes
      aTrue: True
      aTilde: ~
      anEmpty:
      quotedInt: "5"
      quotedTrue: 'true'
      tooBig: 99999999999999999999
      plusSign: +5
      leadingZero: 007
      aList: [1, true, x, null, 1.5]
      aMap: {k: 1.5, t: true}
    - voicePrompt: "Says \\"hush\\": often"
      character: THE MILLINER
      gender: NB
      voices:
        voxalta:
          - voices/milliner.vox
          - voices/milliner-alt.vox
  type: cast
  ---
  """ + "\n# Cast\r\n\r\nNotes, with CRLF and no final newline.  "

@Suite("CAST.md writes through Reparto")
struct CastWriteTests {
  @Test("§7 hashes survive a first write to a non-normalized file; the body is byte-identical")
  func nonNormalizedKeepsHashes() throws {
    let project = try SyntheticProject(castText: quirkyCast)
    let before = try project.hashes()
    let body = try project.layout().body
    #expect(before.count == 3)

    let created = try DossierBundle.create(
      character: "THE TINKER", role: "guest", in: project.characters, cast: project.cast)

    let report = try #require(created.castReport)
    #expect(!report.isNormalized)
    #expect(report.exceptions.isEmpty, "\(report.exceptions)")
    #expect(report.suggestion?.contains("reparto canonicalize --apply") == true)

    var after = try project.hashes()
    #expect(after.removeValue(forKey: "THE TINKER") != nil)
    #expect(after == before)
    #expect(try project.layout().body == body)
    #expect(try Data(contentsOf: project.cast).suffix(5) == Data("ne.  ".utf8))
  }

  @Test("Touching an existing member of a non-normalized file leaves every other member's hash")
  func nonNormalizedExistingMember() throws {
    let project = try SyntheticProject(castText: quirkyCast)
    var before = try project.hashes()
    try DossierBundle.create(character: "THE MILLINER", role: "supporting", in: project.characters, cast: project.cast)
    var after = try project.hashes()
    #expect(before.removeValue(forKey: "THE MILLINER") != after.removeValue(forKey: "THE MILLINER"))
    #expect(after == before)
  }

  @Test("On a normalized file, adding a member changes only that member's lines")
  func normalizedAdd() throws {
    let project = try SyntheticProject(castText: quirkyCast)
    let parser = CastMarkdownParser()
    try parser.write(document: try parser.parse(fileURL: project.cast), to: project.cast)
    let before = try project.layout()

    let created = try DossierBundle.create(
      character: "THE TINKER", role: "guest", in: project.characters, cast: project.cast)
    let after = try project.layout()

    #expect(created.castReport?.isNormalized == true)
    #expect(created.castReport?.suggestion == nil)
    #expect(created.memberAdded)
    #expect(after.header == before.header)
    #expect(after.body == before.body)
    #expect(Array(after.members.prefix(before.members.count)) == before.members)
    #expect(after.members.count == before.members.count + 1)
    let added = try #require(after.members.last)
    #expect(added.contains("character: THE TINKER"))
    #expect(added.contains("role: guest"))
    #expect(added.contains("manifest: characters/THE TINKER.dossier/manifest.json"))
  }

  @Test("On a normalized file, updating a member changes only that member's lines")
  func normalizedUpdate() throws {
    let project = try SyntheticProject(castText: quirkyCast)
    let parser = CastMarkdownParser()
    try parser.write(document: try parser.parse(fileURL: project.cast), to: project.cast)
    let before = try project.layout()
    let index = try #require(before.members.firstIndex { $0.contains("THE ORGAN GRINDER") })

    let created = try DossierBundle.create(
      character: "THE ORGAN GRINDER", role: "costar", in: project.characters, cast: project.cast)
    let after = try project.layout()

    #expect(!created.memberAdded)
    #expect(after.header == before.header)
    #expect(after.body == before.body)
    #expect(after.members.count == before.members.count)
    for position in before.members.indices where position != index {
      #expect(after.members[position] == before.members[position])
    }
    // Within the member: only the two owned fields' lines are new.
    let lines = Set(after.members[index].components(separatedBy: "\n"))
    let added = lines.subtracting(before.members[index].components(separatedBy: "\n"))
    #expect(added == ["  role: costar", "  manifest: characters/THE ORGAN GRINDER.dossier/manifest.json"])
    #expect(lines.isSuperset(of: before.members[index].components(separatedBy: "\n")))
  }

  @Test("SD-12's exceptions are reported, and only those members' hashes change")
  func exceptions() throws {
    let project = try SyntheticProject()
    let absolute = project.root.path + "/voices/keeper.vox"
    let manifest = project.root.path + "/characters/THE KEEPER.dossier/manifest.json"
    let text = """
      ---
      type: cast
      schemaVersion: 1
      cast:
      - character: THE WRONG TYPE
        voices: {apple: 5, voxalta: a.vox}
      - character: THE COLLIDER
        voices: {VoxAlta: a.vox, voxalta: b.vox}
      - character: THE KEEPER
        voices: {voxalta: "\(absolute)"}
        manifest: "\(manifest)"
      - character: THE BYSTANDER
        bio: Unaffected.
      ---
      """ + "\n"
    try Data(text.utf8).write(to: project.cast)
    let before = try project.hashes()
    var shown: CastWriteReport?

    let created = try DossierBundle.create(
      character: "THE TINKER", role: "guest", in: project.characters, cast: project.cast
    ) { (report: CastWriteReport) throws in
      shown = report
      #expect(try project.castBytes() == Data(text.utf8), "Reported before anything is written")
    }
    let report = try #require(created.castReport)
    #expect(report == shown)

    #expect(report.exceptions.contains(.voiceValueDropped(member: "THE WRONG TYPE", provider: "apple")))
    // Reparto's winner differs per parse (recon N6). What's reported must be what was written.
    let kept = report.exceptions.compactMap { exception -> [String]? in
      if case .voiceProviderCollision("THE COLLIDER", "voxalta", ["VoxAlta", "voxalta"], let kept) = exception {
        return kept
      }
      return nil
    }
    let collider = try #require(try Cast.load(project.cast).members.first { $0.character == "THE COLLIDER" })
    let written = try #require(collider.fields.voices["voxalta"])
    #expect(kept == [written])
    #expect(
      report.exceptions.contains(
        .absolutePathRelativized(
          member: "THE KEEPER", field: "manifest", from: manifest,
          to: "characters/THE KEEPER.dossier/manifest.json")))
    #expect(
      report.exceptions.contains(
        .absolutePathRelativized(
          member: "THE KEEPER", field: "voices.voxalta", from: absolute, to: "voices/keeper.vox")))
    #expect(!report.exceptions.contains { $0.member == "THE BYSTANDER" })
    #expect(report.suggestion?.contains("reparto canonicalize --apply") == true)
    #expect(report.exceptions.allSatisfy { !$0.description.isEmpty })

    let after = try project.hashes()
    #expect(after["THE BYSTANDER"] == before["THE BYSTANDER"])
    #expect(after["THE KEEPER"] != before["THE KEEPER"])
  }

  @Test("The report comes before any write, and throwing from it changes nothing")
  func reportBeforeWriting() throws {
    struct Stop: Error {}
    let project = try SyntheticProject(castText: quirkyCast)
    let bytes = try project.castBytes()
    var seen: CastWriteReport?

    #expect(throws: Stop.self) {
      try DossierBundle.create(
        character: "THE TINKER", role: "guest", in: project.characters, cast: project.cast
      ) { report in
        seen = report
        #expect(try project.castBytes() == bytes)
        throw Stop()
      }
    }
    #expect(seen?.isNormalized == false)
    #expect(try project.castBytes() == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.characters.path).isEmpty)
  }

  @Test("A new bundle validates, and the member has only what this package owns")
  func createdBundleValidates() throws {
    let project = try SyntheticProject(
      castText: """
        ---
        type: cast
        schemaVersion: 1
        cast:
        - character: THE LAMPLIGHTER
          role: lead
          voicePrompt: A low voice.
          bio: Keeps a ledger.
        ---

        """)
    let new = try DossierBundle.create(
      character: "@the  tinker (V.O.)", role: "guest", in: project.characters, cast: project.cast)
    let existing = try DossierBundle.create(
      character: "THE LAMPLIGHTER", role: "supporting", in: project.characters, cast: project.cast)

    #expect(new.bundle.url.lastPathComponent == "THE TINKER.dossier")
    #expect(new.bundle.manifest.character == "THE TINKER")
    #expect(new.bundle.manifest.role == "guest")
    #expect(new.bundle.manifest.generator?.name == ManifestWriter.generatorName)
    try expectManifestValidates(new.bundle)
    try expectManifestValidates(existing.bundle)

    let member = try #require(new.bundle.member)
    #expect(member.fields == CastMember(
      character: "THE TINKER", role: .guest, manifest: "characters/THE TINKER.dossier/manifest.json"))

    let kept = try #require(existing.bundle.member)
    #expect(kept.fields.role == .supporting)
    #expect(kept.fields.voicePrompt == "A low voice.")
    #expect(kept.fields[extra: "bio"] != nil)

    let report = try DossierBundle.validate(cast: project.cast)
    #expect(!report.findings.contains { $0.level == .error }, "\(report.findings)")
    #expect(!report.findings.contains { $0.code == .orphan || $0.code == .pointer || $0.code == .role })
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.characters.path).sorted()
      == ["THE LAMPLIGHTER.dossier", "THE TINKER.dossier"], "No temporary directory is left")
  }

  @Test("§2: a name with no canonical form is refused", arguments: ["AC/DC", ".HIDDEN", "A:B", "  ", "(V.O.)"])
  func badNames(name: String) throws {
    let project = try SyntheticProject()
    #expect(throws: DossierWriteError.self) {
      try DossierBundle.create(character: name, role: "lead", in: project.characters)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.characters.path).isEmpty)
  }

  @Test("A role that isn't a tier is refused")
  func badRole() throws {
    let project = try SyntheticProject()
    #expect(throws: DossierWriteError.roleNotATier("hero")) {
      try DossierBundle.create(character: "THE TINKER", role: "hero", in: project.characters)
    }
  }

  @Test("§2: a name differing from an existing bundle's only by case is refused, and the same name too")
  func caseCollision() throws {
    let project = try SyntheticProject(castText: "---\ntype: cast\nschemaVersion: 1\ncast: []\n---\n")
    let manager = FileManager.default
    try manager.createDirectory(
      at: project.characters.appendingPathComponent("the Tinker.dossier"), withIntermediateDirectories: true)
    let bytes = try project.castBytes()

    #expect(throws: DossierWriteError.bundleNameCollision(name: "THE TINKER", existing: "the Tinker.dossier")) {
      try DossierBundle.create(character: "THE TINKER", role: "guest", in: project.characters, cast: project.cast)
    }
    #expect(try project.castBytes() == bytes)

    try DossierBundle.create(character: "THE MILLINER", role: "guest", in: project.characters)
    #expect {
      try DossierBundle.create(character: "the milliner", role: "guest", in: project.characters)
    } throws: { error in
      if case DossierWriteError.bundleExists = error { return true }
      return false
    }
  }

  @Test("§2: a bundle a member points at elsewhere counts for the case refusal")
  func caseCollisionThroughPointer() throws {
    let project = try SyntheticProject(
      castText: """
        ---
        type: cast
        schemaVersion: 1
        cast:
        - character: THE LAMPLIGHTER
          manifest: elsewhere/the tinker.dossier/manifest.json
        ---

        """)
    #expect(throws: DossierWriteError.bundleNameCollision(name: "THE TINKER", existing: "the tinker.dossier")) {
      try DossierBundle.create(character: "THE TINKER", role: "guest", in: project.characters, cast: project.cast)
    }
  }

  @Test("Fields this package can't honestly set stop it: name, pointer, location")
  func memberRefusals() throws {
    let project = try SyntheticProject(
      castText: """
        ---
        type: cast
        schemaVersion: 1
        cast:
        - character: the lamplighter
        - character: THE KEEPER
          manifest: elsewhere/THE KEEPER.dossier/manifest.json
        - character: THE TWIN
        - character: the twin
        ---

        """)
    let bytes = try project.castBytes()
    #expect(throws: DossierWriteError.memberNotCanonical(member: "the lamplighter", canonical: "THE LAMPLIGHTER")) {
      try DossierBundle.create(character: "THE LAMPLIGHTER", role: "lead", in: project.characters, cast: project.cast)
    }
    #expect(
      throws: DossierWriteError.memberPointsElsewhere(
        member: "THE KEEPER", pointer: "elsewhere/THE KEEPER.dossier/manifest.json")
    ) {
      try DossierBundle.create(character: "THE KEEPER", role: "lead", in: project.characters, cast: project.cast)
    }
    #expect(throws: DossierWriteError.memberAmbiguous(canonical: "THE TWIN", members: ["THE TWIN", "the twin"])) {
      try DossierBundle.create(character: "THE TWIN", role: "lead", in: project.characters, cast: project.cast)
    }
    let outside = try SyntheticProject().characters
    #expect {
      try DossierBundle.create(character: "THE TINKER", role: "lead", in: outside, cast: project.cast)
    } throws: { error in
      if case DossierWriteError.bundleOutsideCastDirectory = error { return true }
      return false
    }
    #expect(try project.castBytes() == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.characters.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test("A CAST.md that's missing is refused, and one that can't be written removes the bundle")
  func castFailures() throws {
    let project = try SyntheticProject()
    #expect {
      try DossierBundle.create(character: "THE TINKER", role: "lead", in: project.characters, cast: project.cast)
    } throws: { error in
      if case DossierError.castUnreadable = error { return true }
      return false
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: project.characters.path).isEmpty)

    try Data("---\ntype: cast\nschemaVersion: 1\ncast: []\n---\n".utf8).write(to: project.cast)
    let manager = FileManager.default
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.root.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.root.path) }
    #expect {
      try DossierBundle.create(character: "THE TINKER", role: "lead", in: project.characters, cast: project.cast)
    } throws: { error in
      if case DossierWriteError.castWriteFailed = error { return true }
      return false
    }
    #expect(try manager.contentsOfDirectory(atPath: project.characters.path).isEmpty)
  }

  @Test("No CAST.md given: the bundle is made and no cast report exists")
  func noCast() throws {
    let project = try SyntheticProject()
    let nested = project.root.appendingPathComponent("a/b", isDirectory: true)
    let created = try DossierBundle.create(character: "THE TINKER", role: "lead", in: nested)
    #expect(created.castReport == nil)
    #expect(created.bundle.member == nil)
    try expectManifestValidates(created.bundle)
  }
}

@Suite("Prompts and candidates")
struct PromptAndCandidateTests {
  @Test("§5.5: each key is set alone, unknown keys stay, and the manifest validates")
  func prompts() throws {
    let project = try SyntheticProject()
    var bundle = try DossierBundle.create(character: "THE TINKER", role: "lead", in: project.characters).bundle
    try bundle.setPrompt(.identity, "A wiry build, no glasses.")
    try bundle.setPrompt(.portrait, "Three-quarter view.")
    try bundle.setPrompt(.subject, "person")
    #expect(bundle.identityPrompt == "A wiry build, no glasses.")
    #expect(bundle.manifest.prompts?.portrait == "Three-quarter view.")
    #expect(bundle.manifest.prompts?.subject == "person")
    try expectManifestValidates(bundle)
    #expect(try DossierBundle.open(at: bundle.url).manifest == bundle.manifest)
    let written = try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json"))
    #expect(try Manifest(data: written).computedChecksum == bundle.manifest.manifestChecksum)

    // An unknown key in `prompts` is preserved.
    let url = bundle.url.appendingPathComponent("manifest.json")
    var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    text = text.replacingOccurrences(of: "\"prompts\": {", with: "\"prompts\": {\n    \"extra\": \"kept\",")
    try Data(text.utf8).write(to: url)
    try bundle.setPrompt(.identity, "Changed.")
    #expect(bundle.manifest.prompts?.json["extra"]?.stringValue == "kept")
    #expect(bundle.identityPrompt == "Changed.")
  }

  @Test("A subject outside §5.5's words is refused, and an unchanged prompt writes nothing")
  func promptRefusals() throws {
    let project = try SyntheticProject()
    var bundle = try DossierBundle.create(character: "THE TINKER", role: "lead", in: project.characters).bundle
    let url = bundle.url.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: url)
    #expect {
      try bundle.setPrompt(.subject, "automaton")
    } throws: { error in
      if case DossierWriteError.schemaViolations = error { return true }
      return false
    }
    #expect(try Data(contentsOf: url) == before)

    try bundle.setPrompt(.subject, "person")
    let once = try Data(contentsOf: url)
    try bundle.setPrompt(.subject, "person")
    #expect(try Data(contentsOf: url) == once)
  }

  @Test("§4: candidates are listed from .generations, by kind and variant, with sidecars")
  func candidates() throws {
    let project = try SyntheticProject()
    let bundle = try DossierBundle.create(character: "THE TINKER", role: "lead", in: project.characters).bundle
    #expect(bundle.candidates().isEmpty, "No directory holds nothing")

    let directory = project.characters.appendingPathComponent(".generations/THE TINKER", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let other = project.characters.appendingPathComponent(".generations/scenes", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: other.appendingPathComponent("portrait-z.png"))
    for name in [
      "portrait-v3-seed1.png", "portrait-v3-seed1.json", "view-front-aaaaaaaa.png", "view-back-bbbbbbbb.png",
      "view-back-bbbbbbbb.png.json", "expression-happy-cccccccc.png", "THE TINKER.vox", "sample-neutral-0.6b.m4a",
      "sample-wry.m4a", "unnamed.png", ".hidden.png",
    ] {
      try Data("x".utf8).write(to: directory.appendingPathComponent(name))
    }

    let all = bundle.candidates()
    #expect(all.map(\.name).sorted() == [
      "THE TINKER.vox", "expression-happy-cccccccc.png", "portrait-v3-seed1.png", "sample-neutral-0.6b.m4a",
      "sample-wry.m4a", "unnamed.png", "view-back-bbbbbbbb.png", "view-front-aaaaaaaa.png",
    ])
    #expect(all.first { $0.name == "unnamed.png" }?.kind == nil)
    #expect(bundle.candidates(kind: .portrait).map(\.name) == ["portrait-v3-seed1.png"])
    #expect(bundle.candidates(kind: .portrait).first?.sidecar?.lastPathComponent == "portrait-v3-seed1.json")
    #expect(bundle.candidates(kind: .view).count == 2)
    #expect(bundle.candidates(kind: .view, variant: "back").first?.sidecar?.lastPathComponent == "view-back-bbbbbbbb.png.json")
    #expect(bundle.candidates(variant: "happy").map(\.kind) == [.expression])
    #expect(bundle.candidates(kind: .voiceSample, variant: "neutral").map(\.name) == ["sample-neutral-0.6b.m4a"])
    #expect(bundle.candidates(kind: .vox).count == 1)
    #expect(bundle.candidates(in: project.root).isEmpty, "Another characters directory holds another list")
  }
}
