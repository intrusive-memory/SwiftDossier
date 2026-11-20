import Dossier
import SwiftUI

/// A `LOCATIONS.md` preview, from its text (SFV-11, SFV-12). It has no editor.
///
/// With a project folder in the context it shows the full LOCATIONS page through `LocationsView`,
/// built from the index SAVED on disk: the text isn't what that page draws, so the host passes a new
/// `refreshToken` after each save. This is the one view that uses a folder; this file opens none.
/// Without a folder it lists the entries read from the text.
///
/// The accessory (Escribir puts Open Project there) shows above the content in both modes, so the
/// host decides what goes in it, and a host that wants it only without a folder passes a view that
/// is empty when it has one.
public struct LocationsIndexPreview<Accessory: View>: View {
  /// The label and SF Symbol for hosts (SFV-3).
  public static var identity: SingleFileViewIdentity { .locationsIndexPreview }
  public var identity: SingleFileViewIdentity { Self.identity }

  private let model: LocationsIndexPreviewModel
  private let context: SingleFileContext
  private let refreshToken: AnyHashable?
  private let accessory: Accessory

  public init(
    text: String, context: SingleFileContext, refreshToken: AnyHashable? = nil,
    @ViewBuilder accessory: () -> Accessory
  ) {
    model = LocationsIndexPreviewModel(text: text, context: context)
    self.context = context
    self.refreshToken = refreshToken
    self.accessory = accessory()
  }

  public var body: some View {
    VStack(spacing: 0) {
      if Accessory.self != EmptyView.self {
        accessory.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      switch model.mode {
      case .page(let folder):
        LocationsView(projectDirectory: folder, selectedBundleURL: nil, refreshToken: refreshToken)
      case .list, .problem:
        PreviewWebView(content: .html(model.html))
      }
    }
    // The probe gives the VStack a second accessibility child. Without one, a page-mode preview
    // holds only `LocationsView`, which is already an element, and `.accessibilityElement`
    // modifies that element instead of making a new one: `locations.indexPreview` replaced
    // `locations.view`.
    .overlay(alignment: .topLeading) { modeProbe }
    // `.contain` first: without it the identifier collapses the VStack into one element on
    // macOS, and the accessory and the LOCATIONS page inside it vanish from accessibility.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("locations.indexPreview")
  }

  /// The preview's mode as an accessibility value: `page`, `list` or `problem`.
  static func modeValue(_ mode: LocationsIndexPreviewModel.Mode) -> String {
    switch mode {
    case .page: "page"
    case .list: "list"
    case .problem: "problem"
    }
  }

  /// A leaf element whose value is the preview's mode. Drawn clear and 1 pt square, like
  /// `LocationsView`'s section probe: `.opacity(0)` would take it out of the accessibility tree.
  private var modeProbe: some View {
    let value = Self.modeValue(model.mode)
    return Text(value)
      .font(.system(size: 1))
      .foregroundStyle(.clear)
      .frame(width: 1, height: 1)
      .clipped()
      .allowsHitTesting(false)
      .accessibilityValue(value)
      .accessibilityIdentifier("locations.indexPreview.mode")
  }
}

extension LocationsIndexPreview where Accessory == EmptyView {
  public init(text: String, context: SingleFileContext, refreshToken: AnyHashable? = nil) {
    self.init(text: text, context: context, refreshToken: refreshToken) { EmptyView() }
  }
}
