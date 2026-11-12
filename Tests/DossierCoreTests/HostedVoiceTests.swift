import DossierCore
import Foundation
import Testing

/// rc.9's rules on synthetic projects, so each is tested apart from the fixtures: the `voice`
/// input (§7, DF-76), the inputs read from the member, imported assets (DF-77) and the hosted
/// tier rule (§8.3, DF-78). Invented characters and voice IDs only.
private final class SyntheticProject {
  static let character = "TESS QUILLON"
  static let provider = "vocalsmith"
  static let voiceID = "SYNTH0VOICE0000001"

  let url: URL
  var bundleURL: URL { url.appendingPathComponent("characters/\(Self.character).dossier", isDirectory: true) }

  /// - Parameters:
  ///   - voices: The member's `voices` line, as YAML, or `nil` for no `voices` key.
  ///   - assets: The manifest's `assets`, as JSON objects.
  ///   - artStyle: `CHARACTER.md`'s front-matter `artStyle`.
  init(voices: String? = "{VocalSmith: \(voiceID)}", role: String = "supporting", assets: [String], artStyle: String = "ink wash")
    throws
  {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("HostedVoiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let voicesLine = voices.map { "  voices: \($0)\n" } ?? ""
    let cast = """
      ---
      type: cast
      schemaVersion: 1
      cast:
      - character: \(Self.character)
        role: \(role)
        voicePrompt: A level, careful mezzo.
      \(voicesLine)  manifest: characters/\(Self.character).dossier/manifest.json
      ---
      # Cast

      """
    try Data(cast.utf8).write(to: url.appendingPathComponent("CAST.md"))
    let description = """
      ---
      type: character
      character: \(Self.character)
      artStyle: \(artStyle)
      ---

      """
    try Data(description.utf8).write(to: bundleURL.appendingPathComponent("CHARACTER.md"))
    let manifest = """
      {"manifestVersion": 2, "character": "\(Self.character)", "updatedAt": "2026-01-01T00:00:00Z",
       "files": [], "assets": [\(assets.joined(separator: ","))], "manifestChecksum": "x"}
      """
    try Data(manifest.utf8).write(to: bundleURL.appendingPathComponent("manifest.json"))
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  /// The bundle, opened through its member, or with none.
  func bundle(withMember: Bool = true) throws -> DossierBundle {
    guard withMember else { return try DossierBundle.open(at: bundleURL) }
    let cast = try Cast.load(url.appendingPathComponent("CAST.md"))
    return try #require(try cast.openBundle(for: cast.members[0]))
  }

  /// A selected `voiceSample` with the given inputs.
  static func sample(
    _ variant: String, model: String = "synthetic-hosted-tts", inputs: [String] = [voiceInput()]
  ) -> String {
    """
    {"path": "voice/sample-\(variant)-\(model).m4a", "kind": "voiceSample", "status": "selected",
     "variant": "\(variant)", "model": "\(model)", "sampleText": "Mind the step.",
     "createdAt": "2026-01-01T00:00:00Z", "provenance": {"provider": "synthetic"},
     "derivedFrom": [\(inputs.joined(separator: ","))]}
    """
  }

  static func voiceInput(provider: String = provider, voiceId: String = voiceID) -> String {
    #"{"role": "voice", "provider": "\#(provider)", "voiceId": "\#(voiceId)"}"#
  }

  /// A `vox` input whose `vox` is selected and current, so only the voice rule is in play.
  static let voxInput = #"{"role": "vox", "path": "voice/TESS QUILLON.vox", "sha256": "\#(voxHash)"}"#
  static let voxHash = String(repeating: "a", count: 64)
  static let vox = """
    {"path": "voice/TESS QUILLON.vox", "kind": "vox", "status": "selected",
     "createdAt": "2026-01-01T00:00:00Z", "provenance": {"provider": "synthetic", "models": ["synthetic-1.7B"]}}
    """

  /// A selected image whose portrait input has no selection (stale) and whose artStyle differs
  /// from the front matter's (stale), unless it's imported.
  static func image(_ kind: String, variant: String? = nil, copiedFrom: String?) -> String {
    let variantKey = variant.map { #""variant": "\#($0)","# } ?? ""
    let copied = copiedFrom.map { #", "copiedFrom": "\#($0)""# } ?? ""
    let portraitInput = #"{"role": "portrait", "path": "images/portrait-x.png", "sha256": "\#(String(repeating: "b", count: 64))"}"#
    let inputs = kind == "portrait" ? "" : #", "derivedFrom": [\#(portraitInput)]"#
    return """
      {"path": "images/\(kind)-x.png", "kind": "\(kind)", "status": "selected", \(variantKey)
       "createdAt": "2026-01-01T00:00:00Z",
       "provenance": {"provider": "import", "artStyle": "charcoal"\(copied)}\(inputs)}
      """
  }
}

@Suite("Hosted voices and imported assets (§7, §8.3, DF-75 to DF-78)")
struct HostedVoiceTests {
  // MARK: The model (§6, §7)

  @Test("§6, §7: a voice record, instructMethod (any string) and copiedFrom on any kind decode")
  func model() throws {
    let manifest = try Manifest(
      data: Data(
        """
        {"manifestVersion": 2, "character": "TESS QUILLON", "updatedAt": "2026-01-01T00:00:00Z",
         "files": [], "manifestChecksum": "x", "assets": [
          {"path": "voice/s.m4a", "kind": "voiceSample", "status": "selected",
           "provenance": {"provider": "synthetic", "instruct": "[whispers] Mind the step.",
                          "instructMethod": "audio-tag", "instructApplied": "unverified"},
           "derivedFrom": [{"role": "voice", "provider": "vocalsmith", "voiceId": "SYNTH0VOICE0000001"}]},
          {"path": "voice/t.m4a", "kind": "voiceSample", "status": "selected",
           "provenance": {"provider": "synthetic", "instructMethod": "a-word-of-its-own"}},
          {"path": "images/portrait-x.png", "kind": "portrait", "status": "selected",
           "provenance": {"provider": "import", "copiedFrom": "art/tess.png"}},
          {"path": "images/view-front-x.png", "kind": "view", "variant": "front", "status": "selected",
           "provenance": {"provider": "import", "copiedFrom": "art/tess-front.png"}}
        ]}
        """.utf8))
    let assets = manifest.assets
    let input = try #require(assets[0].derivedFrom.first)
    #expect(input.role == "voice")
    #expect(input.provider == "vocalsmith")
    #expect(input.voiceId == "SYNTH0VOICE0000001")
    #expect(input.sha256.isEmpty && input.path == nil)
    #expect(assets[0].provenance.instructMethod == "audio-tag")
    #expect(assets[0].provenance.instructApplied == "unverified")
    #expect(assets[1].provenance.instructMethod == "a-word-of-its-own")
    #expect(assets[2].provenance.copiedFrom == "art/tess.png")
    #expect(!assets[2].isImported, "a portrait with copiedFrom isn't imported (DF-77)")
    #expect(assets[3].isImported)
    #expect(!assets[0].isImported)
  }

  // MARK: Staleness of a voice input (§7, DF-76)

  private func voiceReasons(_ bundle: DossierBundle) -> [StaleFinding.Reason] {
    bundle.stale().map(\.reason).filter {
      if case .voice = $0 { return true }
      return false
    }
  }

  @Test("§7: a voice input is current when the member's normal-form voices[provider] holds its voiceId")
  func voiceCurrent() throws {
    // The member writes the key in mixed case and the ID as a scalar; the normal form reads
    // {"vocalsmith": ["SYNTH0VOICE0000001"]}. A list holding the ID is current too.
    for voices in ["{VocalSmith: \(SyntheticProject.voiceID)}", "{vocalsmith: [OTHER0ID, \(SyntheticProject.voiceID)]}"] {
      let project = try SyntheticProject(voices: voices, assets: [SyntheticProject.sample("neutral")])
      #expect(try project.bundle().stale().isEmpty, "\(voices)")
    }
  }

  @Test("§7: a voice input is stale when the member's array doesn't hold its voiceId")
  func voiceStale() throws {
    let project = try SyntheticProject(
      voices: "{VocalSmith: SYNTH0VOICE0000002}", assets: [SyntheticProject.sample("neutral")])
    let reasons = voiceReasons(try project.bundle())
    #expect(reasons == [.voice(provider: "vocalsmith", voiceId: SyntheticProject.voiceID, current: ["SYNTH0VOICE0000002"])])
  }

  @Test("§7: the comparison is exact: an ID differing in case, or a provider in capitals, is stale")
  func voiceExact() throws {
    let lowerID = try SyntheticProject(
      voices: "{VocalSmith: \(SyntheticProject.voiceID.lowercased())}", assets: [SyntheticProject.sample("neutral")])
    #expect(voiceReasons(try lowerID.bundle()).count == 1)
    let capitalProvider = try SyntheticProject(
      assets: [SyntheticProject.sample("neutral", inputs: [SyntheticProject.voiceInput(provider: "VocalSmith")])])
    #expect(voiceReasons(try capitalProvider.bundle()) == [
      .voice(provider: "VocalSmith", voiceId: SyntheticProject.voiceID, current: nil)
    ])
  }

  @Test("§7: a voice input is stale when the member has no key for its provider", arguments: ["{}", nil, "{VoxAlta: voice/x.vox}"] as [String?])
  func voiceProviderAbsent(voices: String?) throws {
    let project = try SyntheticProject(voices: voices, assets: [SyntheticProject.sample("neutral")])
    #expect(voiceReasons(try project.bundle()) == [
      .voice(provider: "vocalsmith", voiceId: SyntheticProject.voiceID, current: nil)
    ])
  }

  @Test("§7: only voices is read: a changed voicePrompt doesn't make a voice input stale")
  func voiceIgnoresOtherFields() throws {
    let project = try SyntheticProject(assets: [SyntheticProject.sample("neutral")])
    let castURL = project.url.appendingPathComponent("CAST.md")
    let text = try String(contentsOf: castURL, encoding: .utf8)
      .replacingOccurrences(of: "A level, careful mezzo.", with: "A brighter, quicker mezzo.")
    try Data(text.utf8).write(to: castURL)
    #expect(try project.bundle().stale().isEmpty)
  }

  @Test("§7: a candidate with a stale voice input isn't reported")
  func voiceCandidate() throws {
    let candidate = SyntheticProject.sample("neutral").replacingOccurrences(of: #""selected""#, with: #""candidate""#)
    let project = try SyntheticProject(voices: "{}", assets: [candidate])
    #expect(try project.bundle().stale().isEmpty)
  }

  // MARK: Inputs read from the member (§7)

  @Test("§7: with no member, neither a voice nor a castMember input is checked or makes the asset stale")
  func noMember() throws {
    let page = """
      {"path": "TESS QUILLON-dossier.html", "kind": "dossier", "status": "selected",
       "createdAt": "2026-01-01T00:00:00Z", "provenance": {"provider": "synthetic"},
       "derivedFrom": [{"role": "castMember", "sha256": "\(String(repeating: "c", count: 64))"}]}
      """
    // The member's voices doesn't hold the ID and its hash isn't the recorded one: with the
    // member both are stale; without it, neither is.
    let project = try SyntheticProject(voices: "{}", assets: [SyntheticProject.sample("neutral"), page])
    let withMember = try project.bundle().stale()
    #expect(withMember.contains { if case .voice = $0.reason { return true } else { return false } })
    #expect(withMember.contains { if case .input("castMember", _, _) = $0.reason { return true } else { return false } })
    #expect(try project.bundle(withMember: false).stale().isEmpty)
  }

  // MARK: Imported assets (§7, DF-77)

  @Test(
    "DF-77: an imported face, view or expression is never stale, its inputs and artStyle included",
    arguments: [("face", nil), ("view", "front"), ("expression", "happy")] as [(String, String?)])
  func importedNeverStale(kind: String, variant: String?) throws {
    let imported = try SyntheticProject(
      assets: [SyntheticProject.image(kind, variant: variant, copiedFrom: "art/tess-\(kind).png")])
    #expect(try imported.bundle().stale().isEmpty)
    // The same asset without copiedFrom is stale twice: its portrait input and its artStyle.
    let derived = try SyntheticProject(assets: [SyntheticProject.image(kind, variant: variant, copiedFrom: nil)])
    let reasons = try derived.bundle().stale().map(\.reason)
    #expect(reasons.count == 2, "\(reasons)")
    #expect(reasons.contains(.artStyle(recorded: "charcoal", current: "ink wash")))
  }

  @Test("DF-77: a portrait with copiedFrom keeps its artStyle check")
  func importedPortraitKeepsArtStyle() throws {
    let project = try SyntheticProject(assets: [SyntheticProject.image("portrait", copiedFrom: "art/tess.png")])
    #expect(try project.bundle().stale().map(\.reason) == [.artStyle(recorded: "charcoal", current: "ink wash")])
    let sameStyle = try SyntheticProject(
      assets: [SyntheticProject.image("portrait", copiedFrom: "art/tess.png")], artStyle: "charcoal")
    #expect(try sameStyle.bundle().stale().isEmpty)
  }

  // MARK: The hosted tier rule (§8.3, DF-78)

  private static let voiceRows = ["vox.1.7b", "vox.0.6b", "sample.neutral.1.7b", "sample.neutral.0.6b"]

  /// Each of the four voice rows' state, in ``voiceRows`` order.
  private func voiceRowStates(_ bundle: DossierBundle) throws -> [Bool] {
    let report = try #require(try bundle.completeness(tier: .supporting))
    return try Self.voiceRows.map { id in try #require(report.rows.first { $0.id == id }).isSatisfied }
  }

  @Test("DF-78: a current voice input on a neutral sample satisfies all four voice rows, whatever its model")
  func hostedNeutral() throws {
    let project = try SyntheticProject(assets: [SyntheticProject.sample("neutral"), SyntheticProject.sample("wry")])
    #expect(try voiceRowStates(project.bundle()) == [true, true, true, true])
    let report = try #require(try project.bundle().completeness())
    #expect(!report.missingRequired.contains { Self.voiceRows.contains($0) })
  }

  @Test("DF-78: hosted with no neutral sample: the vox rows are met, both neutral rows aren't")
  func hostedNoNeutral() throws {
    let project = try SyntheticProject(assets: [SyntheticProject.sample("wry")])
    #expect(try voiceRowStates(project.bundle()) == [true, true, false, false])
  }

  @Test("DF-78: a stale voice input doesn't make the voice hosted")
  func notHostedWhenStale() throws {
    for voices in ["{VocalSmith: SYNTH0VOICE0000002}", "{}"] {
      let project = try SyntheticProject(voices: voices, assets: [SyntheticProject.sample("neutral")])
      #expect(try voiceRowStates(project.bundle()) == [false, false, false, false], "\(voices)")
    }
  }

  @Test("DF-78: with no member no voice is hosted, so the voice rows are measured without it")
  func notHostedWithoutMember() throws {
    let project = try SyntheticProject(assets: [SyntheticProject.sample("neutral")])
    #expect(try voiceRowStates(project.bundle(withMember: false)) == [false, false, false, false])
  }

  @Test("DF-78: a vox-made neutral sample counts only for its own size, even when the voice is hosted")
  func voxNeutralCountsForItsSize() throws {
    let voxNeutral = SyntheticProject.sample("neutral", model: "1.7b", inputs: [SyntheticProject.voxInput])
    let files = #"{"path": "voice/TESS QUILLON.vox", "sha256": "\#(SyntheticProject.voxHash)", "sizeBytes": 1}"#
    func project(_ assets: [String]) throws -> SyntheticProject {
      let project = try SyntheticProject(assets: assets)
      let manifestURL = project.bundleURL.appendingPathComponent("manifest.json")
      let text = try String(contentsOf: manifestURL, encoding: .utf8)
        .replacingOccurrences(of: #""files": []"#, with: #""files": [\#(files)]"#)
      try Data(text.utf8).write(to: manifestURL)
      return project
    }
    // Hosted by the wry sample: the vox rows are met. The vox's provenance.models holds only
    // 1.7B, and the neutral sample is vox-made, so it meets 1.7B's neutral row and not 0.6B's.
    let hosted = try project([SyntheticProject.vox, voxNeutral, SyntheticProject.sample("wry")])
    #expect(try hosted.bundle().stale().isEmpty)
    #expect(try voiceRowStates(hosted.bundle()) == [true, true, true, false])
    // Without a hosted sample, the same vox meets only its own size.
    let local = try project([SyntheticProject.vox, voxNeutral])
    #expect(try voiceRowStates(local.bundle()) == [true, false, true, false])
  }

  @Test("DF-78: sample.range and voicePrompt are unchanged by a hosted voice")
  func rangeAndPromptUnchanged() throws {
    let samples = ["neutral", "wry", "brisk"].map { SyntheticProject.sample($0) }
    let project = try SyntheticProject(assets: samples)
    let report = try #require(try project.bundle().completeness(tier: .lead))
    #expect(report.rows.first { $0.id == "sample.range" }?.isSatisfied == false, "two range samples, three needed")
    #expect(report.rows.first { $0.id == "voicePrompt" }?.isSatisfied == true)
    let more = try SyntheticProject(assets: samples + [SyntheticProject.sample("hushed")])
    #expect(try more.bundle().completeness(tier: .lead)?.rows.first { $0.id == "sample.range" }?.isSatisfied == true)
  }
}
