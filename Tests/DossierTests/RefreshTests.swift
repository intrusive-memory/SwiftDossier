import DossierCore
import Foundation
import SwiftReparto
import Testing

@testable import Dossier

private let character = "THE TINKER"
private let models = #"{"models": ["Qwen3-TTS-12Hz-1.7B-Base-bf16", "Qwen3-TTS-12Hz-0.6B-Base-bf16"]}"#

@Suite("refresh")
struct RefreshTests {
  private func bundle(in project: SyntheticProject) throws -> DossierBundle {
    try DossierBundle.create(character: character, role: "lead", in: project.characters).bundle
  }

  private func drop(_ path: String, in bundle: DossierBundle, _ text: String = "bytes") throws {
    let url = bundle.url.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  /// A selected `vox` with `provenance.models`, added the way a producer would.
  private func selectVox(in bundle: inout DossierBundle, project: SyntheticProject) throws {
    let source = project.root.appendingPathComponent("made.vox")
    try Data("a voice".utf8).write(to: source)
    let provenance = try #require(try JSONValue.parse(Data(models.utf8)).objectValue)
    try bundle.add(source, kind: .vox, options: AddOptions(provenance: provenance, select: true))
  }

  private func reason(of path: String, in report: RefreshReport) -> RefreshReport.UnclassifiedReason? {
    report.unclassified.first { $0.path == path }?.reason
  }

  @Test("§5.6: voice/<CHARACTER>.vox is adopted as a candidate; a second run has nothing to do")
  func adoptsVox() throws {
    let project = try SyntheticProject()
    var bundle = try bundle(in: project)
    try drop("voice/\(character).vox", in: bundle)
    let report = try bundle.refresh()

    #expect(report.adopted.map(\.path) == ["voice/\(character).vox"])
    #expect(report.adopted.first?.kind == .vox)
    #expect(report.adopted.first?.status == .candidate)
    #expect(report.adopted.first?.provenance.provider == "import")
    #expect(report.unclassified.isEmpty)
    #expect(report.orphan == nil)
    try expectManifestValidates(bundle)
    let codes = try DossierBundle.validate(at: bundle.url).findings
    #expect(!codes.contains { $0.level == .error }, "\(codes)")
    #expect(!codes.contains { $0.code == .unclassified })

    let manifest = try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json"))
    #expect(try bundle.refresh().adopted.isEmpty)
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json")) == manifest)
  }

  @Test("A vox adopted as a candidate doesn't let a sample in until it's selected")
  func candidateVoxIsNotEnough() throws {
    let project = try SyntheticProject()
    var bundle = try bundle(in: project)
    try drop("voice/\(character).vox", in: bundle)
    try drop("voice/sample-neutral.m4a", in: bundle)
    try drop("voice/samples.yaml", in: bundle, "- {variant: neutral, text: Hello there.}\n")

    let first = try bundle.refresh()
    #expect(first.adopted.map(\.kind) == [.vox])
    #expect(reason(of: "voice/sample-neutral.m4a", in: first) == .noSelectedVox)

    try bundle.select(path: "voice/\(character).vox")
    let second = try bundle.refresh()
    #expect(second.adopted.isEmpty)
    // The adopted vox has no `provenance.models`, which it can't get from this package.
    #expect(reason(of: "voice/sample-neutral.m4a", in: second) == .noModelSize)
  }

  @Test("§5.6: a sample takes its model, text, language, instruction and source, and derives from the vox")
  func adoptsSamples() throws {
    let project = try SyntheticProject()
    var bundle = try bundle(in: project)
    try selectVox(in: &bundle, project: project)
    try drop("voice/sample-neutral.m4a", in: bundle)
    try drop("voice/sample-neutral-0.6B.m4a", in: bundle)
    try drop("voice/sample-wry-aside.m4a", in: bundle)
    try drop(
      "voice/samples.yaml", in: bundle,
      """
      - variant: neutral
        text: Any model.
      - variant: neutral
        model: 0.6b
        text: The small model.
        language: es
        instruct: Quietly.
        source: scripts/one.fountain:12-14
      - variant: wry-aside
        text: Oh, indeed.

      """)

    let report = try bundle.refresh()
    #expect(report.unclassified.isEmpty, "\(report.unclassified)")
    #expect(report.adopted.count == 3)
    let vox = try #require(bundle.selectedAsset(kind: .vox))
    let voxHash = try #require(bundle.manifest.files.first { $0.path == vox.path }?.sha256)

    let small = try #require(report.adopted.first { $0.path == "voice/sample-neutral-0.6B.m4a" })
    #expect(small.variant == "neutral")
    #expect(small.model == "0.6b")
    #expect(small.sampleText == "The small model.")
    #expect(small.language == "es")
    #expect(small.status == .candidate)
    #expect(small.provenance.json["instruct"]?.stringValue == "Quietly.")
    #expect(small.provenance.json["source"]?.stringValue == "scripts/one.fountain:12-14")
    #expect(small.derivedFrom.count == 1)
    #expect(small.derivedFrom.first?.role == "vox")
    #expect(small.derivedFrom.first?.path == vox.path)
    #expect(small.derivedFrom.first?.sha256 == voxHash)

    let plain = try #require(report.adopted.first { $0.path == "voice/sample-neutral.m4a" })
    #expect(plain.variant == "neutral")
    #expect(plain.model == "1.7b", "The first size in provenance.models")
    #expect(plain.sampleText == "Any model.")
    #expect(plain.language == nil)

    #expect(report.adopted.first { $0.path == "voice/sample-wry-aside.m4a" }?.variant == "wry-aside")

    try expectManifestValidates(bundle)
    let findings = try DossierBundle.validate(at: bundle.url).findings
    #expect(!findings.contains { $0.level == .error }, "\(findings)")
    #expect(!findings.contains { $0.code == .unclassified }, "\(findings)")
    #expect(!findings.contains { $0.code == .stale }, "\(findings)")
  }

  @Test("§5.6: each reason a sample stays unclassified is reported")
  func sampleReasons() throws {
    let project = try SyntheticProject()
    var bundle = try bundle(in: project)
    try drop("voice/sample-neutral.m4a", in: bundle)
    #expect(reason(of: "voice/sample-neutral.m4a", in: try bundle.refresh()) == .noSelectedVox)

    try selectVox(in: &bundle, project: project)
    #expect(reason(of: "voice/sample-neutral.m4a", in: try bundle.refresh()) == .noSamplesFile)

    try drop("voice/samples.yaml", in: bundle, "- {variant: other, text: Not this one.}\n")
    #expect(
      reason(of: "voice/sample-neutral.m4a", in: try bundle.refresh())
        == .noSamplesEntry(variant: "neutral", model: "1.7b"))

    // An entry for another model doesn't match; only one with no model matches any.
    try drop("voice/samples.yaml", in: bundle, "- {variant: neutral, model: 0.6b, text: Too small.}\n")
    #expect(
      reason(of: "voice/sample-neutral.m4a", in: try bundle.refresh())
        == .noSamplesEntry(variant: "neutral", model: "1.7b"))

    // A size the vox doesn't hold is part of the variant, as §5.6 has it, so it's no near match.
    try drop("voice/sample-neutral-9.9b.m4a", in: bundle)
    #expect(
      reason(of: "voice/sample-neutral-9.9b.m4a", in: try bundle.refresh())
        == .noSamplesEntry(variant: "neutral-9.9b", model: "1.7b"))

    // Fails samples.schema.json: no `text`.
    try drop("voice/samples.yaml", in: bundle, "- {variant: neutral}\n")
    guard case .samplesUnreadable = try #require(reason(of: "voice/sample-neutral.m4a", in: try bundle.refresh()))
    else {
      Issue.record("Expected samplesUnreadable")
      return
    }

    try drop("voice/samples.yaml", in: bundle, "- {variant: [unclosed\n")
    guard case .samplesUnreadable = try #require(reason(of: "voice/sample-neutral.m4a", in: try bundle.refresh()))
    else {
      Issue.record("Expected samplesUnreadable")
      return
    }

    try drop("voice/sample--0.6b.m4a", in: bundle)
    #expect(reason(of: "voice/sample--0.6b.m4a", in: try bundle.refresh()) == .noVariant)
    #expect(bundle.assets(kind: .voiceSample).isEmpty)
  }

  @Test("§5.6: anything else stays unclassified with a reason; samples.yaml and hidden files aren't reported")
  func otherFiles() throws {
    let project = try SyntheticProject()
    var bundle = try bundle(in: project)
    for path in [
      "voice/SOMEONE ELSE.vox", "voice/the tinker.vox", "voice/sample-x.wav", "voice/deep/sample-x.m4a",
      "images/portrait-aaaaaaaa.png", "notes.txt", "voice/samples.yaml", ".hidden", "voice/.tmp",
    ] {
      try drop(path, in: bundle)
    }
    let report = try bundle.refresh()
    #expect(report.adopted.isEmpty)
    #expect(report.unclassified.allSatisfy { $0.reason == .noRule })
    #expect(report.unclassified.map(\.path).sorted() == [
      "images/portrait-aaaaaaaa.png", "notes.txt", "voice/SOMEONE ELSE.vox", "voice/deep/sample-x.m4a",
      "voice/sample-x.wav", "voice/the tinker.vox",
    ])
    #expect(report.unclassified.allSatisfy { !$0.reason.description.isEmpty })
    #expect(try bundle.manifest.assets.isEmpty)
  }

  @Test("A version 1 manifest is refused, and a zero-byte file stops an adoption")
  func refusals() throws {
    let project = try SyntheticProject()
    var bundle = try bundle(in: project)
    try drop("voice/\(character).vox", in: bundle)
    try drop("empty.txt", in: bundle, "")
    #expect(throws: DossierWriteError.zeroByteFiles(["empty.txt"])) { try bundle.refresh() }
    #expect(bundle.manifest.assets.isEmpty)

    let v1 = project.characters.appendingPathComponent("OLD.dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: v1, withIntermediateDirectories: true)
    var old = try Manifest(character: "OLD", updatedAt: "2026-01-01T00:00:00Z").encoded()
    old = Data(String(decoding: old, as: UTF8.self).replacingOccurrences(of: "\"manifestVersion\": 2", with: "\"manifestVersion\": 1").utf8)
    try old.write(to: v1.appendingPathComponent("manifest.json"))
    var opened = try DossierBundle.open(at: v1)
    #expect(throws: DossierWriteError.versionOneManifest) { try opened.refresh() }
  }

  // MARK: - §3 orphans

  private func castText(_ members: String) -> String {
    "---\ntype: cast\nschemaVersion: 1\ncast:\n\(members)---\n"
  }

  @Test("§3: an orphan is adopted by a member of its exact name with no manifest:")
  func adoptsOrphan() throws {
    let project = try SyntheticProject(
      castText: castText("- character: \(character)\n  role: lead\n  bio: Kept.\n- character: THE MILLINER\n"))
    var bundle = try bundle(in: project)
    let before = try DossierBundle.validate(cast: project.cast)
    #expect(before.findings.contains { $0.code == .orphan })
    let milliner = try project.hashes()["THE MILLINER"]

    var seen = false
    let report = try bundle.refresh(cast: project.cast) { _ in seen = true }

    let pointer = "characters/\(character).dossier/manifest.json"
    #expect(report.orphan == .pointerSet(member: character, manifest: pointer))
    #expect(seen)
    #expect(report.castReport != nil)
    #expect(bundle.member?.fields.manifest == pointer)
    #expect(bundle.member?.fields.role == .lead)
    #expect(bundle.member?.fields[extra: "bio"] != nil)
    #expect(try project.hashes()["THE MILLINER"] == milliner)

    let after = try DossierBundle.validate(cast: project.cast)
    #expect(!after.findings.contains { $0.code == .orphan })
    #expect(!after.findings.contains { $0.level == .error }, "\(after.findings)")

    let bytes = try project.castBytes()
    seen = false
    let again = try bundle.refresh(cast: project.cast) { _ in seen = true }
    #expect(again.orphan == .alreadyPointedAt(member: character))
    #expect(again.castReport == nil)
    #expect(!seen)
    #expect(try project.castBytes() == bytes)
  }

  @Test("§3: refresh never adopts on a near match, and says why")
  func nearMatches() throws {
    let cases: [(members: String, expected: RefreshReport.OrphanOutcome)] = [
      ("- character: the tinker\n", .nearMatch(["the tinker"])),
      ("- character: THE  TINKER\n", .nearMatch(["THE  TINKER"])),
      ("- character: THE TINKER (V.O.)\n", .nearMatch(["THE TINKER (V.O.)"])),
      ("- character: THE TINKERER\n", .noMember),
      (
        "- character: THE TINKER\n  manifest: elsewhere/THE TINKER.dossier/manifest.json\n",
        .memberPointsElsewhere(member: character, pointer: "elsewhere/THE TINKER.dossier/manifest.json")
      ),
      ("- character: THE TINKER\n- character: THE TINKER\n", .memberAmbiguous),
    ]
    for (members, expected) in cases {
      let project = try SyntheticProject(castText: castText(members))
      var bundle = try bundle(in: project)
      let bytes = try project.castBytes()
      let report = try bundle.refresh(cast: project.cast)
      #expect(report.orphan == expected, "\(members)")
      #expect(report.castReport == nil)
      #expect(try project.castBytes() == bytes, "\(members)")
    }
  }

  @Test("§3: a bundle with no one name, or outside the project, isn't adopted")
  func notAdoptable() throws {
    let project = try SyntheticProject(castText: castText("- character: \(character)\n"))
    var outside = try bundle(in: try SyntheticProject())
    #expect(try outside.refresh(cast: project.cast).orphan == .outsideCastDirectory)

    let directory = project.characters.appendingPathComponent("\(character).dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Manifest(character: "SOMEONE ELSE", updatedAt: "2026-01-01T00:00:00Z").encoded()
      .write(to: directory.appendingPathComponent("manifest.json"))
    var mismatched = try DossierBundle.open(at: directory)
    let bytes = try project.castBytes()
    #expect(
      try mismatched.refresh(cast: project.cast).orphan
        == .nameMismatch(directory: "\(character).dossier", character: "SOMEONE ELSE"))
    #expect(try project.castBytes() == bytes)
  }

  @Test("An unreadable CAST.md stops the call before the manifest changes")
  func unreadableCast() throws {
    let project = try SyntheticProject(castText: "no front matter\n")
    var bundle = try bundle(in: project)
    try drop("voice/\(character).vox", in: bundle)
    #expect { try bundle.refresh(cast: project.cast) } throws: { error in
      if case DossierError.castUnreadable = error { return true }
      return false
    }
    #expect(try DossierBundle.open(at: bundle.url).manifest.assets.isEmpty)
  }
}
