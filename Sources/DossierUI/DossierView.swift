import Dossier
import DossierCore
import Foundation
import SwiftUI

/// Rebuilds the preview of the ``DossierView`` it came from (PV-19).
///
/// An app gets it two ways: `@Environment(\.dossierRebuild)` inside the view's accessory, and
/// `@FocusedValue(\.dossierRebuild)` in a menu or command, where it is `nil` when no
/// ``DossierView`` is in the focused scene.
public struct DossierRebuildAction: Sendable {
  /// Whether a rebuild is running now. A menu item disables itself with it.
  public let isRebuilding: Bool
  private let perform: @MainActor @Sendable () -> Void

  /// An action that calls `perform`.
  public init(isRebuilding: Bool = false, perform: @escaping @MainActor @Sendable () -> Void) {
    self.isRebuilding = isRebuilding
    self.perform = perform
  }

  /// Rebuilds the preview. Does nothing while a rebuild runs.
  @MainActor
  public func callAsFunction() {
    if !isRebuilding { perform() }
  }
}

extension EnvironmentValues {
  /// The rebuild action of the enclosing ``DossierView``. Outside one, it does nothing.
  @Entry public var dossierRebuild: DossierRebuildAction = DossierRebuildAction(perform: {})
}

extension FocusedValues {
  /// The rebuild action of the focused scene's ``DossierView``, or `nil`.
  @Entry public var dossierRebuild: DossierRebuildAction?
}

/// Holds the view's model, made on first use: SwiftUI may run a view's `init` many times, and the
/// model starts a watch.
@MainActor
private final class ModelHolder {
  private var model: DossierViewModel?

  func model(bundleURL: URL, cast: URL?, refreshToken: AnyHashable?) -> DossierViewModel {
    if let model { return model }
    let made = DossierViewModel(bundleURL: bundleURL, cast: cast, refreshToken: refreshToken)
    model = made
    return made
  }
}

/// The whole viewer of one `.dossier` bundle (PV-18): the page in a web view, a header with
/// **Rebuild**, and notes above the page.
///
/// The header has Rebuild and then `accessory`. The view has no other controls and no app-specific
/// actions (PV-24).
///
/// The view needs nothing the app doesn't already hold: the app's security scope on the project
/// folder covers the reads and the `.preview/` and `manifest.json` writes (PV-25).
public struct DossierView<Accessory: View>: View {
  private let bundleURL: URL
  private let cast: URL?
  private let refreshToken: AnyHashable?
  private let accessory: Accessory
  @State private var holder = ModelHolder()

  /// - Parameters:
  ///   - bundleURL: The `.dossier` directory.
  ///   - cast: The project's `CAST.md`, or `nil`.
  ///   - refreshToken: Any value; changing it shows the bundle again.
  ///   - accessory: Controls the app adds to the header, after Rebuild.
  public init(
    bundleURL: URL, cast: URL?, refreshToken: AnyHashable? = nil,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.bundleURL = bundleURL
    self.cast = cast
    self.refreshToken = refreshToken
    self.accessory = accessory()
  }

  public var body: some View {
    let model = holder.model(bundleURL: bundleURL, cast: cast, refreshToken: refreshToken)
    let action = DossierRebuildAction(isRebuilding: model.isRebuilding) { [model] in model.rebuild() }
    VStack(spacing: 0) {
      header(model, action)
      Divider()
      notes(model)
      content(model, action)
    }
    .environment(\.dossierRebuild, action)
    .focusedSceneValue(\.dossierRebuild, action)
    .onChange(of: bundleURL) { _, new in model.bundleURL = new }
    .onChange(of: cast) { _, new in model.cast = new }
    .onChange(of: refreshToken) { _, new in model.refreshToken = new }
  }

  // MARK: Header

  private func header(_ model: DossierViewModel, _ action: DossierRebuildAction) -> some View {
    HStack(spacing: 8) {
      Button {
        action()
      } label: {
        Label("Rebuild", systemImage: "arrow.clockwise")
      }
      .disabled(model.isRebuilding)
      if model.isRebuilding {
        ProgressView().controlSize(.small)
      }
      Spacer()
      accessory
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: Notes

  @ViewBuilder
  private func notes(_ model: DossierViewModel) -> some View {
    if case .updating = model.state {
      note("This character is being updated. Showing the last saved preview.", systemImage: "arrow.triangle.2.circlepath")
    }
    if let text = model.refreshNote {
      note(text, systemImage: "exclamationmark.triangle") { model.dismissRefreshNote() }
    }
    if let text = model.storeNote {
      note(text, systemImage: "externaldrive.badge.exclamationmark") { model.dismissStoreNote() }
    }
  }

  private func note(_ text: String, systemImage: String, dismiss: (() -> Void)? = nil) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage)
      Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
      if let dismiss {
        Button(action: dismiss) { Image(systemName: "xmark") }
          .buttonStyle(.borderless)
          .accessibilityLabel("Dismiss")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.yellow.opacity(0.15))
  }

  // MARK: Body

  @ViewBuilder
  private func content(_ model: DossierViewModel, _ action: DossierRebuildAction) -> some View {
    switch model.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .page(let result), .rebuilding(let result?):
      PreviewWebView(content: Self.content(for: result, bundleURL: model.bundleURL))
    case .rebuilding(nil):
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let reason):
      VStack(spacing: 12) {
        Text(reason.message).multilineTextAlignment(.center)
        Button("Rebuild") { action() }
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .updating(let storedPage):
      if let storedPage {
        PreviewWebView(content: .stored(page: storedPage, bundleURL: model.bundleURL))
      } else {
        Spacer(minLength: 0)
      }
    }
  }

  private static func content(for result: PreviewResult, bundleURL: URL) -> PreviewContent {
    if let page = result.pageURL { return .stored(page: page, bundleURL: bundleURL) }
    return .html(result.html ?? "")
  }
}

extension DossierView where Accessory == EmptyView {
  /// A viewer with nothing in the header after Rebuild.
  public init(bundleURL: URL, cast: URL?, refreshToken: AnyHashable? = nil) {
    self.init(bundleURL: bundleURL, cast: cast, refreshToken: refreshToken) { EmptyView() }
  }
}
