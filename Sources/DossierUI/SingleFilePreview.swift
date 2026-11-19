import Dossier
import SwiftUI

/// A character file's preview, drawn from its text alone (SFV-1, SFV-8). It reads and writes no
/// file and draws no portrait. The page is built by ``CharacterPreviewModel/html`` and shown in
/// a ``PreviewWebView`` from memory.
public struct CharacterPreview: View {
  /// The label and SF Symbol for hosts (SFV-3).
  public static let identity = SingleFileViewIdentity.characterPreview
  public var identity: SingleFileViewIdentity { Self.identity }

  private let model: CharacterPreviewModel
  private let context: SingleFileContext

  public init(text: String, context: SingleFileContext = SingleFileContext()) {
    model = CharacterPreviewModel(text: text)
    self.context = context
  }

  public var body: some View {
    PreviewWebView(content: .html(model.html))
      .accessibilityIdentifier("character.preview")
      #if os(macOS)
        .help(context.displayName ?? "")
      #endif
  }
}

/// A location file's preview, drawn from its text alone (SFV-1, SFV-10). It reads and writes no
/// file.
public struct LocationPreview: View {
  /// The label and SF Symbol for hosts (SFV-3).
  public static let identity = SingleFileViewIdentity.locationPreview
  public var identity: SingleFileViewIdentity { Self.identity }

  private let model: LocationPreviewModel
  private let context: SingleFileContext

  public init(text: String, context: SingleFileContext = SingleFileContext()) {
    model = LocationPreviewModel(text: text)
    self.context = context
  }

  public var body: some View {
    PreviewWebView(content: .html(model.html))
      .accessibilityIdentifier("location.preview")
      #if os(macOS)
        .help(context.displayName ?? "")
      #endif
  }
}
