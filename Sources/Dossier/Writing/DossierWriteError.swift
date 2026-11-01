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
  /// Assets whose files aren't on disk, which the write would record as `E-ASSET-NO-FILE`.
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
  /// The reference sent for a role is no asset in the bundle, so `derivedFrom` can't name it.
  case derivedInputNotInBundle(role: String, sha256: String)
  /// `delete()` only removes a `.dossier` directory holding a `manifest.json`.
  case notADossierDirectory(String)

  /// A description of the failure, for people.
  public var errorDescription: String? {
    switch self {
    case .versionOneManifest: return "A version 1 manifest can't be written; migrate the bundle first"
    case .schemaViolations(let details): return "The manifest fails its schema: \(details.joined(separator: "; "))"
    case .zeroByteFiles(let paths): return "Zero-byte files: \(paths.joined(separator: ", "))"
    case .fileUnreadable(let path): return "Can't read \(path)"
    case .assetFilesMissing(let paths): return "Assets with no file: \(paths.joined(separator: ", "))"
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
    case .loraVersionMissing: return "A lora asset needs a lora object with an integer version"
    case .assetExists(let path): return "An asset already has the path \(path)"
    case .destinationExists(let path): return "A different file is already at \(path)"
    case .destinationNotInBundle(let path): return "\(path) leads through a symbolic link"
    case .assetNotFound(let path): return "No asset has the path \(path)"
    case .missingDerivedInput(let kind, let role): return "A \(kind) needs a \(role) input, and there is none"
    case .derivedInputNotInBundle(let role, let sha256):
      return "The \(role) reference sent (\(sha256)) is no asset in the bundle"
    case .notADossierDirectory(let path): return "Not a .dossier directory with a manifest: \(path)"
    }
  }
}
