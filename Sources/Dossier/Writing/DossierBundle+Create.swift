import DossierCore
import Foundation
import SwiftReparto

/// What ``DossierBundle/create(character:role:in:cast:beforeCastWrite:)`` made.
public struct CreatedBundle: Sendable {
  /// The new bundle, with its `CAST.md` member when one was given.
  public let bundle: DossierBundle
  /// SD-12's report on the `CAST.md`, as it was before the write. `nil` when none was given.
  public let castReport: CastWriteReport?
  /// Whether the member was new to `CAST.md`.
  public let memberAdded: Bool
}

extension DossierBundle {
  /// Makes an empty bundle, and updates `CAST.md` through Reparto (SD-12).
  ///
  /// The member is added when absent. This package sets its `role`, and its `manifest` when it
  /// has none, and no other field. Nothing is changed unless everything checks out first: if
  /// `CAST.md` then can't be written, the new bundle is removed.
  ///
  /// SPEC-GAP: §2, §3: §3 calls the orphan listing "the only directory listing the format uses",
  /// and §2's refusal can't be made without one. The refusal is a MUST, so the directory the bundle
  /// goes in is listed, along with the bundle names in the members' pointers. A bundle anywhere
  /// else isn't seen.
  ///
  /// SPEC-GAP: §3, SD-12: a member whose name only canonicalizes to this one would be
  /// `E-NAME-MISMATCH` once it pointed here, and this package doesn't own `character`. That's
  /// refused, in favour of `reparto canonicalize --apply`.
  ///
  /// SPEC-GAP: §3, Reparto RQ-24: a `manifest:` that's already set and leads elsewhere is a
  /// deliberate pointer. That's refused, not overwritten.
  ///
  /// - Parameters:
  ///   - character: The name, as typed. It's canonicalized (§2).
  ///   - role: The tier (§8.3).
  ///   - directory: Where the bundle goes, by convention `characters/`. Made if absent.
  ///   - castURL: The `CAST.md`. It must exist. `nil` leaves the bundle an orphan.
  ///   - beforeCastWrite: Given SD-12's report before anything is written, so a caller can
  ///     show it. Throwing stops the call with nothing changed.
  /// - Returns: The bundle, and SD-12's report.
  /// - Throws: ``DossierWriteError``, ``DossierCore/DossierError/castUnreadable(_:)``, or what
  ///   `beforeCastWrite` throws.
  @discardableResult
  public static func create(
    character: String, role: String, in directory: URL, cast castURL: URL? = nil,
    beforeCastWrite: ((CastWriteReport) throws -> Void)? = nil
  ) throws -> CreatedBundle {
    let name: String
    do {
      name = try CanonicalName.canonicalize(character)
    } catch {
      throw DossierWriteError.nameNotAllowed(name: character, detail: error.localizedDescription)
    }
    guard let tier = CastRole(rawValue: role) else { throw DossierWriteError.roleNotATier(role) }
    let bundleURL = directory.appendingPathComponent(name + ".dossier", isDirectory: true)
    try refuseCollision(of: name, in: directory, at: bundleURL)

    var change: MemberChange?
    let castFile = try castURL.map { try CastFile(url: $0) }
    if let castFile {
      change = try MemberChange(name: name, tier: tier, bundle: bundleURL, file: castFile)
      try beforeCastWrite?(castFile.report)
    }

    let manifest = try writeEmptyBundle(name: name, role: role, in: directory, at: bundleURL)

    var member: Cast.Member?
    if let castFile, let change {
      do {
        try castFile.write(change.document)
      } catch {
        try? FileManager.default.removeItem(at: bundleURL)
        throw error
      }
      member = (try? Cast.load(castFile.url))?.members.first { $0.character.hasSameBytes(as: name) }
    }
    return CreatedBundle(
      bundle: DossierBundle(url: bundleURL, manifest: manifest, member: member),
      castReport: castFile?.report, memberAdded: change?.isNew ?? false)
  }

  /// §2: the MUST on case, and a plain refusal to reuse a name.
  private static func refuseCollision(of name: String, in directory: URL, at bundleURL: URL) throws {
    let suffix = ".dossier"
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for entry in entries where entry.lowercased().hasSuffix(suffix) {
      let stem = String(entry.dropLast(suffix.count))
      if Self.sameName(stem, name) { throw DossierWriteError.bundleExists(bundleURL.path) }
      if Self.sameUppercased(stem, name) {
        throw DossierWriteError.bundleNameCollision(name: name, existing: entry)
      }
    }
  }

  fileprivate static func sameName(_ first: String, _ second: String) -> Bool {
    first.precomposedStringWithCanonicalMapping.hasSameBytes(as: second.precomposedStringWithCanonicalMapping)
  }

  fileprivate static func sameUppercased(_ first: String, _ second: String) -> Bool {
    sameName(first.uppercased(), second.uppercased())
  }

  /// Builds the bundle in a hidden directory beside its destination and renames it there, so
  /// a bundle is either whole or absent. The manifest goes through ``ManifestWriter`` (SD-3, SD-5).
  private static func writeEmptyBundle(
    name: String, role: String, in directory: URL, at bundleURL: URL
  ) throws -> Manifest {
    let manager = FileManager.default
    let temporary = directory.appendingPathComponent(".create-\(UUID().uuidString)", isDirectory: true)
    do {
      try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
      try Manifest(character: name, updatedAt: Timestamp.string(from: Date())).encoded()
        .write(to: temporary.appendingPathComponent("manifest.json"))
    } catch {
      try? manager.removeItem(at: temporary)
      throw DossierWriteError.replaceFailed(error.localizedDescription)
    }
    defer { try? manager.removeItem(at: temporary) }
    let manifest = try ManifestWriter(bundle: temporary).update { manifest, _ in manifest.role = role }
    do {
      try manager.moveItem(at: temporary, to: bundleURL)
    } catch {
      if manager.fileExists(atPath: bundleURL.path) { throw DossierWriteError.bundleExists(bundleURL.path) }
      throw DossierWriteError.replaceFailed(error.localizedDescription)
    }
    return manifest
  }
}

/// `create`'s change to a `CAST.md`, worked out before anything is written.
private struct MemberChange {
  let document: CastDocument
  let isNew: Bool

  init(name: String, tier: CastRole, bundle: URL, file: CastFile) throws {
    guard let pointer = CastFile.pointer(toBundle: bundle, castDirectory: file.cast.directory) else {
      throw DossierWriteError.bundleOutsideCastDirectory(bundle.path)
    }
    for member in file.cast.members {
      guard let existing = member.pointer?.segments.dropLast().last, existing.hasSuffix(".dossier") else { continue }
      let stem = String(existing.dropLast(".dossier".count))
      if !DossierBundle.sameName(stem, name), DossierBundle.sameUppercased(stem, name) {
        throw DossierWriteError.bundleNameCollision(name: name, existing: existing)
      }
    }

    let matches = file.cast.members.enumerated().filter { _, member in
      (try? CanonicalName.canonicalize(member.character)).map { $0.hasSameBytes(as: name) } ?? false
    }
    guard matches.count <= 1 else {
      throw DossierWriteError.memberAmbiguous(canonical: name, members: matches.map(\.element.character))
    }

    var document = file.document
    guard let (index, member) = matches.first else {
      document.cast.append(CastMember(character: name, role: tier, manifest: pointer))
      self.document = document
      isNew = true
      return
    }
    guard member.character.hasSameBytes(as: name) else {
      throw DossierWriteError.memberNotCanonical(member: member.character, canonical: name)
    }
    if let existing = member.pointer, !existing.points(at: pointer) {
      throw DossierWriteError.memberPointsElsewhere(member: member.character, pointer: existing.raw)
    }
    document.cast[index].role = tier
    if member.pointer == nil { document.cast[index].manifest = pointer }
    self.document = document
    isNew = false
  }
}
