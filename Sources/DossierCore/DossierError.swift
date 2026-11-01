import Foundation

/// Every way reading a cast or a bundle through `DossierCore` can fail.
public enum DossierError: Error, Equatable, Sendable, LocalizedError {
  /// `CAST.md` can't be read: its YAML doesn't parse, or a member is malformed (§14 `E-CAST`).
  case castUnreadable(String)
  /// The directory has no `manifest.json` (§14 `E-MANIFEST`).
  case manifestMissing(path: String)
  /// `manifest.json` isn't UTF-8 JSON (§14 `E-MANIFEST`).
  case manifestNotJSON(String)
  /// `manifest.json` is JSON, but not an object (§14 `E-MANIFEST`).
  case manifestNotObject
  /// `manifestVersion` is absent or isn't a version this package reads (§14 `E-VERSION`).
  case unknownVersion(String?)
  /// A version 2 manifest in a directory without `.dossier` (§14 `E-NOT-BUNDLE`).
  case notABundle(path: String)
  /// A member's `manifest:` doesn't end in `manifest.json` (§3 `W-POINTER`).
  case pointerNotManifest(String)
  /// A bundled data file is missing or doesn't have the shape this package reads.
  case resourceUnreadable(String)
  /// `tiers.json` has a check row whose ID isn't implemented (§8.3).
  case unknownCheckRow(String)
  /// The text given isn't a YAML mapping describing one `CAST.md` member (§7).
  case memberUnreadable(String)

  /// A description of the failure, for people.
  public var errorDescription: String? {
    switch self {
    case .castUnreadable(let detail): return "CAST.md can't be read: \(detail)"
    case .manifestMissing(let path): return "No manifest.json at \(path)"
    case .manifestNotJSON(let detail): return "manifest.json isn't JSON: \(detail)"
    case .manifestNotObject: return "manifest.json isn't a JSON object"
    case .unknownVersion(let value): return "Unknown manifestVersion: \(value ?? "absent")"
    case .notABundle(let path): return "A version 2 manifest outside a .dossier directory: \(path)"
    case .pointerNotManifest(let value): return "manifest: doesn't name a manifest.json: \(value)"
    case .resourceUnreadable(let detail): return "Bundled resource unreadable: \(detail)"
    case .unknownCheckRow(let id): return "tiers.json names an unimplemented check row: \(id)"
    case .memberUnreadable(let detail): return "Not a cast member: \(detail)"
    }
  }
}

extension String {
  /// Exact equality of the UTF-8 form. Swift's `==` is canonical equivalence, so it
  /// calls NFC and NFD spellings equal, which is what §2's checks must tell apart.
  package func hasSameBytes(as other: String) -> Bool {
    utf8.elementsEqual(other.utf8)
  }

  /// Byte order of the UTF-8 form (§5.2, §5.3, §7). Swift's `<` isn't this order.
  package func precedesInByteOrder(_ other: String) -> Bool {
    utf8.lexicographicallyPrecedes(other.utf8)
  }
}
