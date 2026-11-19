import Foundation

/// Every way reading or editing a description file (`CHARACTER.md`, `LOCATION.md`) can fail. A
/// write's own failures are ``DossierWriteError``.
public enum DescriptionError: Error, Equatable, Sendable, LocalizedError {
  /// The file can't be read.
  case unreadable(String)
  /// The file isn't UTF-8 (§9).
  case notUTF8(String)
  /// The front matter doesn't parse, or isn't a mapping.
  case frontMatterUnreadable(String)
  /// The front matter can't be edited by key without changing the text of other keys.
  case frontMatterNotEditable(String)
  /// `LOCATION.md` was written to a bundle that isn't a location bundle (§16.1).
  case notALocationBundle(String)

  /// A description of the failure, for people.
  public var errorDescription: String? {
    switch self {
    case .unreadable(let path): return "Can't read \(path)"
    case .notUTF8(let path): return "\(path) isn't UTF-8"
    case .frontMatterUnreadable(let detail): return "The front matter can't be read: \(detail)"
    case .frontMatterNotEditable(let detail): return "The front matter can't be edited by key: \(detail)"
    case .notALocationBundle(let path): return "\(path) isn't a location bundle, so it can't hold LOCATION.md"
    }
  }
}

/// The name ``DescriptionError`` had when only `CHARACTER.md` used it. Existing callers compile
/// unchanged.
public typealias CharacterDescriptionError = DescriptionError
