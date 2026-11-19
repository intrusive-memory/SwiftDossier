import Dossier
import DossierCore
import Foundation

/// One location an index lists, as the no-folder preview shows it.
public struct LocationsIndexPreviewEntry: Sendable, Equatable {
  /// The entry's `location` key.
  public let location: String
  /// The entry's `name` field, or `nil` when it has none or it isn't a string.
  public let name: String?
  /// Whether the entry has a `manifest:` pointer. `false` means no bundle yet, which is valid.
  public let hasManifest: Bool
}

/// What `LocationsIndexPreview` shows, from the file's text (SFV-11). Reads nothing from disk.
///
/// With a project folder, ``mode`` is ``Mode/page(projectFolder:)``: the view hands the folder to
/// `LocationsView`, which builds the page from the saved index on disk by its own code. Without one,
/// ``mode`` is ``Mode/list(entries:)`` for text that reads, or ``Mode/problem(_:)`` with the
/// `LocationsError` message for text that doesn't.
public struct LocationsIndexPreviewModel: Sendable, Equatable {
  public enum Mode: Sendable, Equatable {
    /// The full LOCATIONS page for this project folder.
    case page(projectFolder: URL)
    /// The index's entries, in document order.
    case list(entries: [LocationsIndexPreviewEntry])
    /// Why the text can't be read as an index.
    case problem(String)
  }

  public let mode: Mode

  /// - Parameters:
  ///   - text: The whole `LOCATIONS.md`.
  ///   - context: The folder, when known, picks the page mode. The file URL is only the index's URL.
  public init(text: String, context: SingleFileContext) {
    if let folder = context.projectFolder {
      mode = .page(projectFolder: folder)
      return
    }
    let url = context.fileURL ?? URL(fileURLWithPath: "/LOCATIONS.md")
    do {
      let index = try LocationsIndex(text: text, url: url)
      mode = .list(
        entries: index.entries.map {
          LocationsIndexPreviewEntry(
            location: $0.location, name: $0.fields["name"]?.stringValue, hasManifest: $0.pointer != nil)
        })
    } catch {
      mode = .problem((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
  }

  /// The list or problem as one HTML page: every value escaped, no script and no image. Empty for
  /// the page mode, which `LocationsView` draws.
  public var html: String {
    let esc = SingleFilePage.escaped
    switch mode {
    case .page:
      return ""
    case .problem(let message):
      return SingleFilePage.page(content: "<p class=\"problem\">\(esc(message))</p>")
    case .list(let entries):
      var out = "<h1>Locations</h1>"
      if entries.isEmpty { out += "<p class=\"meta\">No locations.</p>" }
      for entry in entries {
        out += "<h2>\(esc(entry.location))</h2>"
        if let name = entry.name { out += "<p>\(esc(name))</p>" }
        out += "<p class=\"meta\">\(entry.hasManifest ? "Has a manifest" : "No manifest yet")</p>"
      }
      return SingleFilePage.page(content: out)
    }
  }
}
