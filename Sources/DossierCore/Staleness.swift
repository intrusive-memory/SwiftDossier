import Foundation

/// The page template a validator or renderer carries (§11).
public struct PageTemplate: Sendable, Equatable {
  /// The version it's published with.
  public let version: String
  /// The hash it's published with.
  public let sha256: String

  /// A template identity.
  public init(version: String, sha256: String) {
    self.version = version
    self.sha256 = sha256
  }
}

/// One reason a selected asset is stale (§7).
public struct StaleFinding: Sendable, Equatable {
  /// What changed.
  public enum Reason: Sendable, Equatable {
    /// An input's hash differs from the current one. `current` is `nil` when that role has
    /// no selected asset.
    case input(role: String, recorded: String, current: String?)
    /// The image's `provenance.artStyle` differs from the front matter's. `current` is `nil`
    /// when the front matter has none.
    case artStyle(recorded: String, current: String?)
    /// The `dossier-template` meta element's hash differs from the current template's.
    case pageTemplate(recorded: String, current: String)
    /// A `voice` input's `voiceId` isn't in the member's normal-form `voices[provider]` (§7,
    /// DF-76). `current` is that array, or `nil` when the member has no such key.
    case voice(provider: String, voiceId: String, current: [String]?)
  }

  /// The stale asset's bundle path.
  public let path: String
  /// Why it's stale.
  public let reason: Reason
}

extension DossierBundle {
  /// The reasons selected assets are stale (§7). Empty on a version 1 manifest (Appendix A).
  ///
  /// The inputs read from the member, `castMember` and `voice`, are compared only when the
  /// bundle was opened with its ``member``; without one neither is checked, and neither makes
  /// an asset stale (§7). An imported `face`, `view` or `expression` (``Asset/isImported``)
  /// is never reported: neither its inputs nor its `artStyle` are compared (DF-77). Neither is a
  /// `plate`, which isn't derived (§16.4).
  ///
  /// - Parameter template: The current template; `Dossier` bundles one as `DossierTemplate.current`.
  ///   `nil` makes no template comparison (§11).
  public func stale(template: PageTemplate? = nil) -> [StaleFinding] {
    guard manifest.manifestVersion == 2 else { return [] }
    var findings: [StaleFinding] = []
    let currentArtStyle = artStyle
    // §16.4: a plate isn't derived and is never stale, and a location's views are always imported.
    for asset in manifest.assets where asset.status == .selected && !asset.isImported && asset.kind != .plate {
      if isLocation, asset.kind == .view { continue }
      for input in asset.derivedFrom {
        if input.role == "voice" {
          if let reason = staleVoice(input) { findings.append(StaleFinding(path: asset.path, reason: reason)) }
          continue
        }
        guard case .compare(let current) = comparison(for: input, template: template) else { continue }
        if !(current?.hasSameBytes(as: input.sha256) ?? false) {
          findings.append(
            StaleFinding(
              path: asset.path,
              reason: .input(role: input.role, recorded: input.sha256, current: current)))
        }
      }
      // SPEC-GAP: §7: a recorded artStyle with no front-matter artStyle "differs" read
      // literally, so it's reported. It's a warning; a removed style is a change.
      if asset.kind.isImage, let recorded = asset.provenance.artStyle,
        !(currentArtStyle?.hasSameBytes(as: recorded) ?? false)
      {
        findings.append(
          StaleFinding(path: asset.path, reason: .artStyle(recorded: recorded, current: currentArtStyle)))
      }
      if asset.kind == .dossier, let template, let page = fileURL(forPath: asset.path),
        let meta = PageTemplateMeta.read(from: page), !meta.sha256.hasSameBytes(as: template.sha256)
      {
        findings.append(
          StaleFinding(
            path: asset.path, reason: .pageTemplate(recorded: meta.sha256, current: template.sha256)))
      }
    }
    return findings
  }

  /// How an input is measured. `compare(nil)` means its role has nothing current, which
  /// is stale; `skip` means there's nothing to compare it with.
  private enum InputComparison {
    case compare(String?)
    case skip
  }

  private func comparison(for input: DerivedInput, template: PageTemplate?) -> InputComparison {
    switch input.role {
    case "portrait", "face", "vox", "description":
      guard let selected = selectedAsset(kind: AssetKind(rawValue: input.role)) else { return .compare(nil) }
      return .compare(manifest.files.first { $0.path.hasSameBytes(as: selected.path) }?.sha256)
    case "castMember":
      return member.map { .compare($0.hash) } ?? .skip
    case "bundle":
      return .compare(bundleChecksum)
    case "template":
      return template.map { .compare($0.sha256) } ?? .skip
    default:
      // SPEC-GAP: §7: an input role outside the table isn't defined, so it isn't compared.
      return .skip
    }
  }

  /// §7's `voice` input, against the member's normal form. `nil` when it's current, or when
  /// there's no member to check it against.
  private func staleVoice(_ input: DerivedInput) -> StaleFinding.Reason? {
    guard let member else { return nil }
    let provider = input.provider ?? ""
    let voiceId = input.voiceId ?? ""
    let current = member.voiceIDs(provider: provider)
    // SPEC-GAP: §7: a record with no provider or voiceId is E-SCHEMA; it matches no key or
    // element, so it reads as stale too.
    if input.provider != nil, input.voiceId != nil, current?.contains(where: { $0.hasSameBytes(as: voiceId) }) ?? false {
      return nil
    }
    return .voice(provider: provider, voiceId: voiceId, current: current)
  }

  /// Whether a selected asset has a `voice` input that is current (§7): the member's
  /// normal-form `voices[provider]` holds its `voiceId`. `false` with no member.
  package func hasCurrentVoiceInput(_ asset: Asset) -> Bool {
    guard member != nil else { return false }
    return asset.derivedFrom.contains { $0.role == "voice" && staleVoice($0) == nil }
  }

  /// §7's `bundle` input: `manifestChecksum` over every file except the page.
  package var bundleChecksum: String {
    let pages = manifest.assets.filter { $0.kind == .dossier }.map(\.path)
    let hashes = manifest.files.filter { file in
      !pages.contains { $0.hasSameBytes(as: file.path) }
    }.map(\.sha256)
    return Checksum.sorted(hashes)
  }
}

/// The page's `<meta name="dossier-template" content="<version> <sha256>">` (§11).
///
/// SPEC-GAP: §11: a page with no such element, or whose file is absent, has no hash to
/// differ, so it isn't reported as stale here. Comments are skipped, as §11 skips them
/// for `W-PAGE-EXTERNAL`.
enum PageTemplateMeta {
  static func read(from url: URL) -> (version: String, sha256: String)? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return parse(Array(data))
  }

  static func parse(_ bytes: [UInt8]) -> (version: String, sha256: String)? {
    var index = 0
    while index < bytes.count {
      guard bytes[index] == UInt8(ascii: "<") else {
        index += 1
        continue
      }
      if matches(bytes, at: index, "<!--") {
        guard let end = find(bytes, "-->", from: index + 4) else { return nil }
        index = end + 3
      } else if matches(bytes, at: index, "<meta"), let tag = tagEnd(bytes, from: index + 5) {
        let attributes = parseAttributes(bytes[(index + 5)..<tag])
        if attributes["name"] == "dossier-template", let content = attributes["content"] {
          let parts = content.split(whereSeparator: \.isWhitespace).map(String.init)
          guard parts.count >= 2, let hash = parts.last else { return nil }
          return (parts.dropLast().joined(separator: " "), hash)
        }
        index = tag + 1
      } else {
        index += 1
      }
    }
    return nil
  }

  private static func matches(_ bytes: [UInt8], at index: Int, _ text: String) -> Bool {
    let needle = Array(text.utf8)
    guard index + needle.count <= bytes.count else { return false }
    for offset in 0..<needle.count {
      var byte = bytes[index + offset]
      if (0x41...0x5A).contains(byte) { byte += 0x20 }
      if byte != needle[offset] { return false }
    }
    return true
  }

  private static func find(_ bytes: [UInt8], _ text: String, from start: Int) -> Int? {
    var index = start
    while index < bytes.count {
      if matches(bytes, at: index, text) { return index }
      index += 1
    }
    return nil
  }

  /// The `>` that ends a tag, outside any quoted attribute value.
  private static func tagEnd(_ bytes: [UInt8], from start: Int) -> Int? {
    var quote: UInt8?
    for index in start..<bytes.count {
      let byte = bytes[index]
      if let open = quote {
        if byte == open { quote = nil }
      } else if byte == 0x22 || byte == 0x27 {
        quote = byte
      } else if byte == UInt8(ascii: ">") {
        return index
      }
    }
    return nil
  }

  private static func parseAttributes(_ slice: ArraySlice<UInt8>) -> [String: String] {
    var attributes: [String: String] = [:]
    let bytes = Array(slice)
    var index = 0
    func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0D).contains(byte) }
    while index < bytes.count {
      while index < bytes.count, isSpace(bytes[index]) || bytes[index] == UInt8(ascii: "/") { index += 1 }
      let nameStart = index
      while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: "=") { index += 1 }
      let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
      while index < bytes.count, isSpace(bytes[index]) { index += 1 }
      guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { continue }
      index += 1
      while index < bytes.count, isSpace(bytes[index]) { index += 1 }
      guard index < bytes.count else { break }
      let value: String
      if bytes[index] == 0x22 || bytes[index] == 0x27 {
        let quote = bytes[index]
        let start = index + 1
        index = start
        while index < bytes.count, bytes[index] != quote { index += 1 }
        value = String(decoding: bytes[start..<index], as: UTF8.self)
        index += 1
      } else {
        let start = index
        while index < bytes.count, !isSpace(bytes[index]) { index += 1 }
        value = String(decoding: bytes[start..<index], as: UTF8.self)
      }
      if !name.isEmpty { attributes[name] = value }
    }
    return attributes
  }
}
