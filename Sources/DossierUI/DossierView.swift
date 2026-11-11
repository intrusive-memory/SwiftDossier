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

/// The whole viewer of one `.dossier` bundle (PV-18): the standard ``DossierHeader``, notes under
/// it, and the page in a web view.
///
/// The header has the breadcrumb, the role, the update state, **Rebuild** and then the host's
/// `accessory` (DH-8). A host that needs its own header passes `header:` instead, and the view
/// draws none of its own (DH-9). The notes stay under whichever header is used (DH-10). The view
/// has no other controls and no app-specific actions (PV-24).
///
/// The view needs nothing the app doesn't already hold: the app's security scope on the project
/// folder covers the reads and the `.preview/` and `manifest.json` writes (PV-25).
public struct DossierView<Header: View>: View {
  private let bundleURL: URL
  private let cast: URL?
  private let refreshToken: AnyHashable?
  private let project: DossierProjectContext
  private let onField: (@MainActor (String) -> Void)?
  private let makeHeader: (DossierHeaderModel) -> Header
  /// Whether the header is the standard ``DossierHeader`` (DH-8), or the host's own (DH-9).
  let drawsStandardHeader: Bool
  @State private var holder = ModelHolder()

  private init(
    bundleURL: URL, cast: URL?, refreshToken: AnyHashable?, project: DossierProjectContext,
    onField: (@MainActor (String) -> Void)?, drawsStandardHeader: Bool,
    header: @escaping (DossierHeaderModel) -> Header
  ) {
    self.bundleURL = bundleURL
    self.cast = cast
    self.refreshToken = refreshToken
    self.project = project
    self.onField = onField
    self.drawsStandardHeader = drawsStandardHeader
    makeHeader = header
  }

  /// A viewer with the standard ``DossierHeader`` (DH-8).
  ///
  /// - Parameters:
  ///   - bundleURL: The `.dossier` directory.
  ///   - cast: The project's `CAST.md`, or `nil`.
  ///   - refreshToken: Any value; changing it shows the bundle again.
  ///   - project: What the host knows about the project. The header shows its title.
  ///   - onField: Called with the key of each field clicked in the page, e.g.
  ///     `expressions.happy` (DH-12). `nil` ignores clicks.
  ///   - accessory: Controls the app adds to the header, after Rebuild.
  public init<Accessory: View>(
    bundleURL: URL, cast: URL?, refreshToken: AnyHashable? = nil,
    project: DossierProjectContext = DossierProjectContext(),
    onField: (@MainActor (String) -> Void)? = nil,
    @ViewBuilder accessory: () -> Accessory
  ) where Header == DossierHeader<Accessory> {
    let accessory = accessory()
    self.init(
      bundleURL: bundleURL, cast: cast, refreshToken: refreshToken, project: project,
      onField: onField, drawsStandardHeader: true
    ) { model in
      DossierHeader(model: model) { accessory }
    }
  }

  /// A viewer with the host's own header in place of the standard one (DH-9). The notes, the page
  /// and the states are the same.
  ///
  /// - Parameters:
  ///   - bundleURL: The `.dossier` directory.
  ///   - cast: The project's `CAST.md`, or `nil`.
  ///   - refreshToken: Any value; changing it shows the bundle again.
  ///   - project: What the host knows about the project. It's passed on in the header's model.
  ///   - onField: Called with the key of each field clicked in the page (DH-12). `nil` ignores
  ///     clicks.
  ///   - header: Draws the header from what the standard one would show.
  public init(
    bundleURL: URL, cast: URL?, refreshToken: AnyHashable? = nil,
    project: DossierProjectContext = DossierProjectContext(),
    onField: (@MainActor (String) -> Void)? = nil,
    @ViewBuilder header: @escaping (DossierHeaderModel) -> Header
  ) {
    self.init(
      bundleURL: bundleURL, cast: cast, refreshToken: refreshToken, project: project,
      onField: onField, drawsStandardHeader: false, header: header)
  }

  public var body: some View {
    let model = holder.model(bundleURL: bundleURL, cast: cast, refreshToken: refreshToken)
    let action = DossierRebuildAction(isRebuilding: model.isRebuilding) { [model] in model.rebuild() }
    VStack(spacing: 0) {
      makeHeader(Self.headerModel(model, project: project, rebuild: action))
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

  /// The header's model, from the bundle the view model already opened (DH-11).
  static func headerModel(
    _ model: DossierViewModel, project: DossierProjectContext, rebuild: DossierRebuildAction
  ) -> DossierHeaderModel {
    let bundle = model.bundle
    return DossierHeaderModel(
      project: project, bundleURL: model.bundleURL, bundle: bundle, member: bundle?.member?.fields,
      update: model.updateStatus, rebuild: rebuild)
  }

  // MARK: Field clicks

  /// Passes a page message on to `onField` when it's a `dossier` message with a string body, a
  /// field key (DH-12). Any other message is ignored.
  @MainActor
  static func handleMessage(name: String, body: Any, onField: (@MainActor (String) -> Void)?) {
    guard let onField, name == previewMessageHandlerName, let key = body as? String else { return }
    onField(key)
  }

  private var messageHandler: ((String, Any) -> Void)? {
    guard let onField else { return nil }
    return { name, body in
      MainActor.assumeIsolated { Self.handleMessage(name: name, body: body, onField: onField) }
    }
  }

  // MARK: Notes

  @ViewBuilder
  private func notes(_ model: DossierViewModel) -> some View {
    if case .updating = model.state {
      note("This character is being updated. Showing the last saved preview.", systemImage: "arrow.triangle.2.circlepath")
        .accessibilityIdentifier("dossier.note.updating")
    }
    if let text = model.refreshNote {
      note(text, systemImage: "exclamationmark.triangle") { model.dismissRefreshNote() }
        .accessibilityIdentifier("dossier.note.refresh")
    }
    if let text = model.storeNote {
      note(text, systemImage: "externaldrive.badge.exclamationmark") { model.dismissStoreNote() }
        .accessibilityIdentifier("dossier.note.store")
    }
  }

  /// One note. It's a container, so the caller's identifier keeps its Dismiss button reachable.
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
    .accessibilityElement(children: .contain)
  }

  // MARK: Body

  @ViewBuilder
  private func content(_ model: DossierViewModel, _ action: DossierRebuildAction) -> some View {
    switch model.state {
    case .loading, .rebuilding(nil):
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("dossier.loading")
    case .page(let result), .rebuilding(let result?):
      page(Self.content(for: result, bundleURL: model.bundleURL))
    case .failed(let reason):
      VStack(spacing: 12) {
        Text(reason.message).multilineTextAlignment(.center)
        Button("Rebuild") { action() }
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("dossier.failed")
    case .updating(let storedPage):
      if let storedPage {
        page(.stored(page: storedPage, bundleURL: model.bundleURL))
      } else {
        Spacer(minLength: 0)
      }
    }
  }

  private func page(_ content: PreviewContent) -> some View {
    PreviewWebView(content: content, onMessage: messageHandler)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("dossier.page")
  }

  private static func content(for result: PreviewResult, bundleURL: URL) -> PreviewContent {
    if let page = result.pageURL { return .stored(page: page, bundleURL: bundleURL) }
    return .html(result.html ?? "")
  }
}

extension DossierView where Header == DossierHeader<EmptyView> {
  /// A viewer with the standard header and nothing in it after Rebuild.
  public init(
    bundleURL: URL, cast: URL?, refreshToken: AnyHashable? = nil,
    project: DossierProjectContext = DossierProjectContext(),
    onField: (@MainActor (String) -> Void)? = nil
  ) {
    self.init(
      bundleURL: bundleURL, cast: cast, refreshToken: refreshToken, project: project,
      onField: onField
    ) { EmptyView() }
  }
}
