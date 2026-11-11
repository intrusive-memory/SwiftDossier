import Foundation

/// What the host knows about the project a bundle belongs to (DH-1).
///
/// SwiftDossier never reads `PROJECT.md`: the host passes in what it shows. That keeps the
/// package free of a project-file dependency.
public struct DossierProjectContext: Sendable, Equatable {
  /// The project's title, from `PROJECT.md`, e.g. "The Lighthouse Keepers". `nil` when the host
  /// has none.
  public var title: String?
  /// The bundle's path relative to the project, e.g. `characters/WREN HALLOWAY.dossier`. It's
  /// help text and an accessibility hint, never shown inline.
  public var bundlePath: String?

  /// A context with whatever the host knows. Both default to `nil`.
  public init(title: String? = nil, bundlePath: String? = nil) {
    self.title = title
    self.bundlePath = bundlePath
  }
}
