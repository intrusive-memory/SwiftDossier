import Foundation
import SwiftReparto
import Yams

/// A member's `manifest:` value, resolved as §3 says: without reading the disk.
public struct ManifestPointer: Sendable, Equatable {
  /// The value as it stands in the member.
  public let raw: String
  /// What's left once empty and `.` segments are dropped and each `..` has removed
  /// the segment before it.
  public let segments: [String]

  /// Resolves a `manifest:` value.
  ///
  /// SPEC-GAP: §3, recon N4: a `..` with nothing before it is kept, so the result can't
  /// equal a path below `CAST.md`'s directory. A leading `/` is an empty segment and
  /// dropped, as the text's algorithm has it, so the result never leaves that directory
  /// by way of an absolute path.
  public init(_ raw: String) {
    self.raw = raw
    var resolved: [String] = []
    for segment in raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
      if segment == "." {
        continue
      } else if segment == "..", let last = resolved.last, last != ".." {
        resolved.removeLast()
      } else {
        resolved.append(segment)
      }
    }
    segments = resolved
  }

  /// The resolved path as an NFC string, the form §3 compares.
  public var normalizedPath: String {
    segments.joined(separator: "/").precomposedStringWithCanonicalMapping
  }

  /// Whether the last segment is `manifest.json`, as a pointer's must be (§3).
  public var namesManifest: Bool { segments.last == "manifest.json" }

  /// Whether a member with this pointer points at the bundle manifest at this path,
  /// relative to the same directory (§3): as NFC strings, case-sensitively.
  public func points(at manifestPath: String) -> Bool {
    normalizedPath.hasSameBytes(as: manifestPath.precomposedStringWithCanonicalMapping)
  }
}

/// A project's `CAST.md`, where discovery starts (§3).
public struct Cast: Sendable {
  /// One entry of the `cast` list.
  public struct Member: Sendable {
    /// The member as Reparto reads it.
    public let fields: CastMember
    /// §7's normal form, from the node the member was written as.
    public let normalForm: JSONValue
    /// The provider keys of `voices`, spelled as written. Reparto lowercases them and
    /// drops some, so a writer reporting that (SD-12) reads them here.
    package let voiceProviderSpellings: [String]

    /// §7's canonical JSON of this member.
    public var canonicalJSON: String { normalForm.canonicalEncoded() }
    /// §7's hash of this member, the `castMember` input of a page.
    public var hash: String { Checksum.sha256(canonicalJSON) }
    /// The member's `character`, exactly as written.
    public var character: String { fields.character }
    /// The member's `displayName` (§3, §5.1, DF-88): how people name the character in prose,
    /// captions and prompts. It wins over the manifest's copy. `nil` when absent or not a string.
    public var displayName: String? { normalForm.objectValue?["displayName"]?.stringValue }
    /// The member's `manifest:`. `nil` means no dossier, which is valid (§3).
    public var pointer: ManifestPointer? { fields.manifest.map(ManifestPointer.init) }
    /// The normal form's `voices[provider]` (§7): the voice IDs, or paths, the member names
    /// for that provider. `nil` when it has no such key. The key compares by bytes, so pass it
    /// lowercased, as the normal form holds it.
    public func voiceIDs(provider: String) -> [String]? {
      normalForm.objectValue?["voices"]?.objectValue?[provider]?.arrayValue?.compactMap(\.stringValue)
    }
  }

  /// The `CAST.md` file.
  public let url: URL
  /// The directory `manifest:` paths are relative to.
  public var directory: URL { url.deletingLastPathComponent() }
  /// The members, in document order.
  public let members: [Member]

  /// Reads a `CAST.md`.
  ///
  /// - Throws: ``DossierError/castUnreadable(_:)`` for every fault §14's `E-CAST` names,
  ///   and when the file can't be read at all.
  public static func load(_ url: URL) throws -> Cast {
    let document: CastDocument
    let text: String
    do {
      document = try CastMarkdownParser().parse(fileURL: url)
      text = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw DossierError.castUnreadable(error.localizedDescription)
    }
    guard let yaml = FrontMatter.split(text)?.yaml,
      case .mapping(let root)? = try? Yams.compose(yaml: yaml),
      case .sequence(let nodes)? = root["cast"], nodes.count == document.cast.count
    else {
      throw DossierError.castUnreadable("the cast list doesn't read as YAML nodes")
    }
    let members = zip(document.cast, nodes).map { fields, node in
      Member(
        fields: fields, normalForm: MemberHash.normalForm(of: node),
        voiceProviderSpellings: MemberHash.voiceProviderSpellings(of: node))
    }
    return Cast(url: url, members: members)
  }

  /// §7's canonical JSON of each member of a `CAST.md`'s text, in document order, or `nil`
  /// when the text's front matter has no `cast` list. Reparto isn't involved: this is how a
  /// writer compares the text it's about to write with the text that's there (SD-12).
  package static func canonicalMemberJSON(ofMarkdown text: String) -> [String]? {
    guard let yaml = FrontMatter.split(text)?.yaml,
      case .mapping(let root)? = try? Yams.compose(yaml: yaml),
      case .sequence(let nodes)? = root["cast"]
    else { return nil }
    return nodes.map { MemberHash.normalForm(of: $0).canonicalEncoded() }
  }

  /// The file a member's pointer leads to, or `nil` when it has no `manifest:`.
  /// The disk isn't read.
  public func manifestURL(of member: Member) -> URL? {
    guard let pointer = member.pointer else { return nil }
    return pointer.segments.reduce(directory) { $0.appendingPathComponent($1) }
  }

  /// Opens the bundle a member points at, or returns `nil` when it has no dossier.
  ///
  /// - Throws: ``DossierError/pointerNotManifest(_:)`` when the pointer doesn't name a
  ///   `manifest.json`, and whatever ``DossierBundle/open(at:member:)`` throws.
  public func openBundle(for member: Member) throws -> DossierBundle? {
    guard let pointer = member.pointer, let manifest = manifestURL(of: member) else { return nil }
    guard pointer.namesManifest else { throw DossierError.pointerNotManifest(pointer.raw) }
    return try DossierBundle.open(at: manifest.deletingLastPathComponent(), member: member)
  }
}
