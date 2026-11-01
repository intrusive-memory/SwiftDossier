import DossierCore
import Foundation
import SwiftReparto

/// What a Reparto write would do to a `CAST.md` beyond the call's own change (SD-12).
///
/// A file Reparto hasn't written is normalized whole by the first write. That keeps every
/// member's §7 hash, except for ``exceptions``.
public struct CastWriteReport: Sendable, Equatable {
  /// A change the write makes to a member's data or to a path.
  public enum Exception: Sendable, Equatable, CustomStringConvertible {
    /// A `voices` provider whose value Reparto doesn't read as a string or a list of strings.
    case voiceValueDropped(member: String, provider: String)
    /// Providers that are one once lowercased. One value is kept: `kept`, the one this write
    /// writes. Reparto's choice differs from one parse to the next (recon N6), so a report
    /// holds only for the parse it came from, which is why there's no report apart from a write.
    case voiceProviderCollision(member: String, provider: String, spellings: [String], kept: [String])
    /// An absolute path under the project becomes relative. `field` is `manifest`, or
    /// `voices.<provider>`.
    case absolutePathRelativized(member: String, field: String, from: String, to: String)
    /// The member's §7 hash changes for a reason SD-12 doesn't name. Nothing expected causes
    /// this; it's here so a report can't call a change harmless by not looking.
    case hashChanged(member: String, from: String, to: String)

    /// The member it happens to.
    public var member: String {
      switch self {
      case .voiceValueDropped(let member, _), .voiceProviderCollision(let member, _, _, _),
        .absolutePathRelativized(let member, _, _, _), .hashChanged(let member, _, _):
        return member
      }
    }

    /// A description, for people.
    public var description: String {
      switch self {
      case .voiceValueDropped(let member, let provider):
        return "\(member): the voices.\(provider) value isn't a string or a list of strings, and is dropped"
      case .voiceProviderCollision(let member, let provider, let spellings, let kept):
        return
          "\(member): voices has \(spellings.joined(separator: ", ")), which are one provider; "
          + "voices.\(provider) keeps \(kept.joined(separator: ", "))"
      case .absolutePathRelativized(let member, let field, let from, let to):
        return "\(member): \(field) changes from \(from) to \(to)"
      case .hashChanged(let member, let from, let to):
        return "\(member): the member's hash changes from \(from) to \(to)"
      }
    }
  }

  /// What the write changes, for every member it touches or doesn't.
  public let exceptions: [Exception]
  /// Whether a write leaves other members' lines alone: `generate(parse(x)) == x`.
  public let isNormalized: Bool
  /// Members whose names aren't canonical (§2), which `reparto canonicalize --apply` renames.
  public let nonCanonicalMembers: [String]

  /// What to do about it, when there's anything to do.
  public var suggestion: String? {
    guard !isNormalized || !exceptions.isEmpty || !nonCanonicalMembers.isEmpty else { return nil }
    return
      "Run `reparto canonicalize --apply` first: it takes this normalizing write on its own, "
      + "and renames non-canonical members."
  }
}

/// A `CAST.md`, read for one write through Reparto. No byte of it is written any other way.
///
/// ``report`` and the document written come from one parse, so the report is true of that write.
struct CastFile {
  let url: URL
  let cast: Cast
  let document: CastDocument
  let report: CastWriteReport

  init(url: URL) throws {
    self.url = url
    cast = try Cast.load(url)
    let parser = CastMarkdownParser()
    do {
      let text = try String(contentsOf: url, encoding: .utf8)
      document = try parser.parse(fileURL: url)
      let generated = try parser.generate(document: document)
      report = Self.report(
        members: cast.members, asWritten: try parser.parse(content: text), document: document,
        text: text, generated: generated)
    } catch {
      throw DossierError.castUnreadable(error.localizedDescription)
    }
  }

  /// `parser.write`, Reparto's own atomic write.
  func write(_ document: CastDocument) throws {
    do {
      try CastMarkdownParser().write(document: document, to: url)
    } catch {
      throw DossierWriteError.castWriteFailed(error.localizedDescription)
    }
  }

  private static func report(
    members: [Cast.Member], asWritten: CastDocument, document: CastDocument, text: String, generated: String
  ) -> CastWriteReport {
    let after = Cast.canonicalMemberJSON(ofMarkdown: generated)
    var exceptions: [CastWriteReport.Exception] = []
    for (index, member) in members.enumerated() {
      let fields = document.cast[index]
      let spellings = Dictionary(grouping: member.voiceProviderSpellings) { $0.lowercased() }
      var found: [CastWriteReport.Exception] = []

      for provider in spellings.keys.sorted() {
        if let values = spellings[provider], values.count > 1 {
          found.append(
            .voiceProviderCollision(
              member: member.character, provider: provider, spellings: values.sorted(),
              kept: fields.voices[provider] ?? []))
        } else if fields.voices[provider] == nil {
          found.append(.voiceValueDropped(member: member.character, provider: provider))
        }
      }

      // `parse(fileURL:)` relativizes and `parse(content:)` doesn't, so where they differ is
      // exactly where a path changes.
      let written = asWritten.cast[index]
      if let from = written.manifest, let to = fields.manifest, !from.hasSameBytes(as: to) {
        found.append(.absolutePathRelativized(member: member.character, field: "manifest", from: from, to: to))
      }
      for provider in fields.voices.keys.sorted() where spellings[provider]?.count == 1 {
        for (from, to) in zip(written.voices[provider] ?? [], fields.voices[provider] ?? [])
        where !from.hasSameBytes(as: to) {
          found.append(
            .absolutePathRelativized(member: member.character, field: "voices.\(provider)", from: from, to: to))
        }
      }

      if found.isEmpty, let after, index < after.count, !after[index].hasSameBytes(as: member.canonicalJSON) {
        found.append(
          .hashChanged(member: member.character, from: member.hash, to: Checksum.sha256(after[index])))
      }
      exceptions += found
    }
    return CastWriteReport(
      exceptions: exceptions, isNormalized: generated.hasSameBytes(as: text),
      nonCanonicalMembers: members.map(\.character).filter { !CanonicalName.isCanonical($0) })
  }

  /// A member's `manifest:` value for a bundle, or `nil` when the bundle isn't under the
  /// directory holding `CAST.md`.
  ///
  /// SPEC-GAP: §3: a pointer is "relative to the directory holding `CAST.md`", and nothing says
  /// whether it may climb out with `..`. A bundle outside it isn't pointed at. Symbolic links
  /// are resolved here only to compare the two; the value itself has no reading of the disk in it.
  static func pointer(toBundle bundle: URL, castDirectory: URL) -> String? {
    let base = resolvedComponents(castDirectory)
    let target = resolvedComponents(bundle)
    func key(_ text: String) -> [UInt8] { Array(text.precomposedStringWithCanonicalMapping.utf8) }
    guard target.count > base.count, zip(base, target).allSatisfy({ key($0) == key($1) }) else { return nil }
    return (target[base.count...] + ["manifest.json"]).joined(separator: "/")
  }

  /// The path's components with the part that exists resolved. A bundle or a directory that
  /// isn't there yet has no links to resolve.
  private static func resolvedComponents(_ url: URL) -> [String] {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
      missing.insert(existing.lastPathComponent, at: 0)
      existing = existing.deletingLastPathComponent()
    }
    return existing.resolvingSymlinksInPath().standardizedFileURL.pathComponents + missing
  }
}
