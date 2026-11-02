import DossierCore
import Foundation

/// Every way a write to a bundle can be refused or fail. When one is thrown, `manifest.json`
/// holds what it held before the call.
public enum DossierWriteError: Error, Equatable, Sendable, LocalizedError {
  /// A writer must not write version 1 (Appendix A). Migrate the bundle first.
  case versionOneManifest
  /// The manifest, as it stands or as it would be written, fails `manifest-v2`.
  case schemaViolations([String])
  /// Zero-byte files, which a writer must not write (§5.2).
  case zeroByteFiles([String])
  /// A file the rescan couldn't read.
  case fileUnreadable(String)
  /// Assets whose files aren't on disk. Every write but `remove` refuses them.
  case assetFilesMissing([String])
  /// Two assets would have this path (§5.4).
  case duplicateAsset(String)
  /// More than one asset would be `selected` for one combination (§5.4).
  case multipleSelected(String)
  /// `manifest.json` didn't read back as written. The prior manifest was put back.
  case verificationFailed
  /// A temporary file couldn't be written, or couldn't replace its target.
  case replaceFailed(String)
  /// The file to add can't be read as a regular file.
  case sourceUnreadable(String)
  /// The sidecar, or a PNG's embedded metadata, isn't a JSON object.
  case provenanceUnreadable(String)
  /// Provenance has a value of a shape this writer can't fold.
  case provenanceMalformed(String)
  /// `generatedAt` isn't a timestamp.
  case timestampUnreadable(String)
  /// More reference roles than the sidecar has references.
  case referenceRolesMismatch(roles: Int, references: Int)
  /// A kind a version 2 writer must not produce, or that this package doesn't know (§8.1).
  case kindNotWritable(String)
  /// A variant on a kind with none, or one that can't be part of a file name (§4, §8.1).
  case variantNotAllowed(String)
  /// The name a file would have in the bundle can't be used (§5.2).
  case fileNameNotAllowed(String)
  /// A file added under `images/` must be a PNG (§4).
  case notPNG(String)
  /// A file with a PNG signature that isn't a well-formed PNG, so its metadata can't be removed.
  case pngMalformed(String)
  /// A `lora` asset needs a `lora` object with a `version` (§8.4).
  case loraVersionMissing
  /// An asset already has this path. `select`, or `remove` it first.
  case assetExists(String)
  /// A different file is already at this path. Nothing is overwritten.
  case destinationExists(String)
  /// The path leads through a symbolic link, which could leave the bundle.
  case destinationNotInBundle(String)
  /// No asset has this path.
  case assetNotFound(String)
  /// A derived kind's input isn't available (§7).
  case missingDerivedInput(kind: String, role: String)
  /// `delete()` only removes a `.dossier` directory holding a `manifest.json`.
  case notADossierDirectory(String)
  /// There is no selected portrait to take a face from.
  case noSelectedPortrait
  /// A face box with a negative edge, a size of zero, or a value that isn't finite.
  case faceBoxInvalid
  /// The portrait's file can't be read as an image.
  case imageUnreadable(String)
  /// No face was found in the portrait and no box was given. Nothing was written.
  case noFaceFound(String)
  /// The crop couldn't be encoded as PNG.
  case faceEncodeFailed
  /// A character name with no canonical form (§2, `E-NAME`).
  case nameNotAllowed(name: String, detail: String)
  /// A role that isn't a tier (§8.3).
  case roleNotATier(String)
  /// A bundle of this name is already there.
  case bundleExists(String)
  /// A bundle's name differs from this one's only by case (§2).
  case bundleNameCollision(name: String, existing: String)
  /// The `CAST.md` member would match this name only after canonicalizing. Its name belongs to
  /// `reparto canonicalize --apply`, not to this package (SD-12).
  case memberNotCanonical(member: String, canonical: String)
  /// More than one `CAST.md` member has this canonical name.
  case memberAmbiguous(canonical: String, members: [String])
  /// The `CAST.md` member already points somewhere else.
  case memberPointsElsewhere(member: String, pointer: String)
  /// A bundle outside the directory holding `CAST.md` can't be pointed at from it.
  case bundleOutsideCastDirectory(String)
  /// `CAST.md` couldn't be written. A bundle made for the write was removed.
  case castWriteFailed(String)
  /// The page's record fails `record.schema.json` (§11). Nothing was written.
  case pageRecordInvalid([String])
  /// A file changed while the page was being made, so it no longer describes the bundle.
  case bundleChangedDuringRender
  /// A file doesn't match its `files` entry, `E-FILE-HASH` or `E-FILE-MISSING` (§11), so a render
  /// refuses. `refresh` accepts a changed file, and a missing one must be restored. Each element is
  /// a finding's code and path. Nothing was written.
  case renderRefusedByIntegrity([String])
  /// A marker's id isn't one or more ASCII letters, digits or hyphens (§5.7).
  case updateIDNotAllowed(String)
  /// The bundle has no marker with this id (§5.7).
  case updateMarkerNotFound(String)
  /// The marker isn't a JSON object, so it can't be renewed (§5.7).
  case updateMarkerUnreadable(String)
  /// A marker's lifetime is above 0 and no more than 3600 seconds (§5.7).
  case updateLifetimeNotAllowed(TimeInterval)
  /// A marker couldn't be written or removed.
  case updateMarkerFailed(String)

  /// A description of the failure, for people.
  public var errorDescription: String? {
    switch self {
    case .versionOneManifest: return "A version 1 manifest can't be written; migrate the bundle first"
    case .schemaViolations(let details): return "The manifest fails its schema: \(details.joined(separator: "; "))"
    case .zeroByteFiles(let paths): return "Zero-byte files: \(paths.joined(separator: ", "))"
    case .fileUnreadable(let path): return "Can't read \(path)"
    case .assetFilesMissing(let paths):
      return "Assets with no file: \(paths.joined(separator: ", ")). Restore each file, or take its asset out with `dossier remove`"
    case .duplicateAsset(let path): return "Two assets with the path \(path)"
    case .multipleSelected(let path): return "More than one selected for the combination of \(path)"
    case .verificationFailed: return "manifest.json didn't read back as written; the prior manifest was restored"
    case .replaceFailed(let detail): return "Couldn't replace the file: \(detail)"
    case .sourceUnreadable(let path): return "Can't read \(path) as a regular file"
    case .provenanceUnreadable(let detail): return "Provenance isn't a JSON object: \(detail)"
    case .provenanceMalformed(let detail): return "Provenance can't be folded: \(detail)"
    case .timestampUnreadable(let value): return "Not a timestamp: \(value)"
    case .referenceRolesMismatch(let roles, let references):
      return "\(roles) reference roles for \(references) references"
    case .kindNotWritable(let kind): return "A version 2 writer can't produce the kind \(kind)"
    case .variantNotAllowed(let detail): return "Variant not allowed: \(detail)"
    case .fileNameNotAllowed(let name): return "File name not allowed: \(name)"
    case .notPNG(let path): return "Not a PNG: \(path)"
    case .pngMalformed(let path): return "Not a well-formed PNG: \(path)"
    case .loraVersionMissing: return "A lora asset needs a lora object with an integer version"
    case .assetExists(let path): return "An asset already has the path \(path)"
    case .destinationExists(let path): return "A different file is already at \(path)"
    case .destinationNotInBundle(let path): return "\(path) leads through a symbolic link"
    case .assetNotFound(let path): return "No asset has the path \(path)"
    case .missingDerivedInput(let kind, let role): return "A \(kind) needs a \(role) input, and there is none"
    case .notADossierDirectory(let path): return "Not a .dossier directory with a manifest: \(path)"
    case .noSelectedPortrait: return "There is no selected portrait to take a face from"
    case .faceBoxInvalid: return "A face box needs x and y of 0 or more, and a width and height above 0"
    case .imageUnreadable(let path): return "Can't read \(path) as an image"
    case .noFaceFound(let path): return "No face found in \(path); pass --box x,y,w,h"
    case .faceEncodeFailed: return "The crop couldn't be encoded as PNG"
    case .nameNotAllowed(let name, let detail): return "The name \"\(name)\" can't be used: \(detail)"
    case .roleNotATier(let role): return "\(role) isn't a tier"
    case .bundleExists(let path): return "A bundle is already at \(path)"
    case .bundleNameCollision(let name, let existing):
      return "\(name) differs from the existing bundle \(existing) only by case"
    case .memberNotCanonical(let member, let canonical):
      return "CAST.md has \"\(member)\", not \"\(canonical)\". Run `reparto canonicalize --apply` first"
    case .memberAmbiguous(let canonical, let members):
      return "CAST.md has more than one member named \(canonical): \(members.joined(separator: ", "))"
    case .memberPointsElsewhere(let member, let pointer): return "\(member) already points at \(pointer)"
    case .bundleOutsideCastDirectory(let path): return "\(path) isn't under the directory holding CAST.md"
    case .castWriteFailed(let detail): return "CAST.md couldn't be written: \(detail)"
    case .pageRecordInvalid(let details): return "The page's record fails its schema: \(details.joined(separator: "; "))"
    case .renderRefusedByIntegrity(let findings):
      var message = "Can't render: \(findings.joined(separator: "; ")). Nothing was changed."
      if findings.contains(where: { $0.hasPrefix("E-FILE-HASH") }) {
        message += " To keep a changed file as it now is, run `dossier refresh`."
      }
      if findings.contains(where: { $0.hasPrefix("E-FILE-MISSING") }) {
        message += " A missing file must be restored: `dossier refresh` doesn't clear it."
      }
      return message
    case .bundleChangedDuringRender: return "A file in the bundle changed during the render; run it again"
    case .updateIDNotAllowed(let id): return "\(id) isn't an update id: it needs ASCII letters, digits or hyphens"
    case .updateMarkerNotFound(let id): return "The bundle has no update marker with the id \(id)"
    case .updateMarkerUnreadable(let id): return "The update marker \(id) isn't a JSON object"
    case .updateLifetimeNotAllowed(let seconds): return "\(seconds) seconds isn't above 0 and at most 3600"
    case .updateMarkerFailed(let detail): return "The update marker couldn't be changed: \(detail)"
    }
  }
}
