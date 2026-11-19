import Foundation

/// What the host knows about the one file a single-file view shows (SFV-2).
///
/// This is deliberately not ``DossierProjectContext``. That type describes a *bundle inside a
/// project* (a project title and a bundle path, for the header). A single-file view shows a loose
/// `CHARACTER.md` or `LOCATION.md` that may belong to no bundle at all, so it needs the file's own
/// URL and an optional project folder instead. Keeping them apart stops a bundle-shaped field
/// from meaning two things.
///
/// The context is read-only data. A view never reads or writes ``fileURL``: it is for display
/// (a title, a help tag) only, and the view's text comes from the host (SFV-1).
public struct SingleFileContext: Sendable, Equatable {
  /// The file's URL, used only for display. `nil` for text that has no file yet.
  public var fileURL: URL?
  /// The project folder the file is in, or `nil` for a loose file. Only the LOCATIONS page uses it.
  public var projectFolder: URL?

  /// - Parameters:
  ///   - fileURL: The file's URL, for display only.
  ///   - projectFolder: The project folder, or `nil`.
  public init(fileURL: URL? = nil, projectFolder: URL? = nil) {
    self.fileURL = fileURL
    self.projectFolder = projectFolder
  }

  /// The file's name for display, or `nil` without a URL.
  public var displayName: String? { fileURL?.lastPathComponent }
}
