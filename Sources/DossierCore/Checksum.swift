import CryptoKit
import Foundation

/// SHA-256 and the two forms of `manifestChecksum`.
public enum Checksum {
  /// The SHA-256 of some bytes, as 64 lowercase hexadecimal characters (§1).
  public static func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
  }

  /// The SHA-256 of a string's UTF-8 form.
  public static func sha256(_ text: String) -> String {
    hex(SHA256.hash(data: Data(text.utf8)))
  }

  /// Version 2's form (§5.3): the hashes sorted by byte order, concatenated, hashed.
  public static func sorted(_ hashes: [String]) -> String {
    sha256(hashes.sorted { $0.precedesInByteOrder($1) }.joined())
  }

  /// Version 1's form (Appendix A): the hashes concatenated in `files` order, hashed.
  public static func pathOrder(_ hashes: [String]) -> String {
    sha256(hashes.joined())
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { byte in
      let text = String(byte, radix: 16)
      return text.count == 1 ? "0" + text : text
    }.joined()
  }
}
