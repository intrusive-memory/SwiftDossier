import Foundation
import SwiftReparto

/// A character's one name (§2). Reparto owns the algorithm; this is the format's view of it.
public enum CanonicalName {
  /// The canonical form of a name read from a screenplay, typed in, or found in `CAST.md`.
  ///
  /// - Throws: Reparto's `CharacterNameError` when there is no canonical form (`E-NAME`).
  public static func canonicalize(_ raw: String) throws -> String {
    try CastMember.canonicalName(raw)
  }

  /// Whether canonicalizing leaves the name byte for byte as it is.
  ///
  /// By bytes, because Swift's `==` calls an NFD name equal to its NFC form, and
  /// §2 requires that name to be reported.
  public static func isCanonical(_ name: String) -> Bool {
    guard let canonical = try? CastMember.canonicalName(name) else { return false }
    return canonical.hasSameBytes(as: name)
  }
}
