import DossierCore
import Foundation
import SwiftReparto

/// Everything one dossier header shows, already resolved (DH-2).
///
/// It never carries completeness or tier facts: those belong to the page.
public struct DossierHeaderModel: Sendable {
  /// What the host knows about the project.
  public let project: DossierProjectContext
  /// The manifest's `character`, or the bundle's stem when the bundle can't be opened (DH-11).
  public let character: String
  /// The member's `displayName`. `nil` when it's absent, empty or whitespace-only.
  public let displayName: String?
  /// The role's display name, e.g. "Lead": the member's role, else the manifest's, else `nil`.
  public let role: String?
  /// The bundle's live update-marker state.
  public let update: UpdateStatus
  /// Rebuilds the bundle's preview.
  public let rebuild: DossierRebuildAction

  /// Resolves a header from what the viewer already holds, with no further reads (DH-11).
  ///
  /// - Parameters:
  ///   - project: What the host knows about the project.
  ///   - bundleURL: The `.dossier` directory. Its stem is the `character` when `bundle` is `nil`.
  ///   - bundle: The bundle as opened, or `nil` when it couldn't be opened.
  ///   - member: The bundle's `CAST.md` member, or `nil` when it has none.
  ///   - update: The bundle's update-marker state.
  ///   - rebuild: The viewer's rebuild action.
  public init(
    project: DossierProjectContext = DossierProjectContext(),
    bundleURL: URL,
    bundle: DossierBundle?,
    member: CastMember?,
    update: UpdateStatus,
    rebuild: DossierRebuildAction
  ) {
    self.project = project
    self.character = bundle?.manifest.character ?? Self.stem(of: bundleURL)
    self.displayName = Self.displayName(member?.displayName)
    self.role = Self.role(member: member?.role, manifest: bundle?.manifest.role)
    self.update = update
    self.rebuild = rebuild
  }

  // MARK: - Resolution

  /// A bundle directory's name without `.dossier`.
  static func stem(of bundleURL: URL) -> String {
    bundleURL.deletingPathExtension().lastPathComponent
  }

  /// The value as written, or `nil` when it's absent, empty or whitespace-only. A value with
  /// text in it isn't trimmed.
  static func displayName(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
  }

  /// The member's role, else the manifest's, as a ``SwiftReparto/CastRole/displayName``.
  ///
  /// The manifest's copy is a string, written lowercase as `CAST.md` writes it, so it's mapped
  /// through `CastRole(rawValue:)`. A manifest value that isn't a `CastRole` gives `nil`.
  static func role(member: CastRole?, manifest: String?) -> String? {
    if let member { return member.displayName }
    return manifest.flatMap(CastRole.init(rawValue:))?.displayName
  }
}
