import DossierCore
import SwiftUI

/// The standard dossier header (DH-3, DH-4): a 40 pt bar with the breadcrumb, the role badge, the
/// update state, **Rebuild**, and then the host's `accessory`.
///
/// At compact horizontal width the role badge and the update label drop out, in that order (DH-5).
public struct DossierHeader<Accessory: View>: View {
  /// One element of the header that can drop out at compact width (DH-5).
  enum Item: Equatable, Sendable {
    case roleBadge
    case updateLabel
  }

  private let model: DossierHeaderModel
  private let accessory: Accessory
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  /// - Parameters:
  ///   - model: What the header shows.
  ///   - accessory: Controls the host adds after Rebuild.
  public init(model: DossierHeaderModel, @ViewBuilder accessory: () -> Accessory) {
    self.model = model
    self.accessory = accessory()
  }

  public var body: some View {
    let compact = horizontalSizeClass == .compact
    let items = Self.visibleItems(compact: compact)
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "person.crop.square")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        breadcrumb
        if items.contains(.roleBadge), let role = model.role {
          Text(role)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityIdentifier("dossier.role")
        }
        Spacer(minLength: 8)
        if model.update.isUpdating {
          HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            if items.contains(.updateLabel) {
              Text(Self.updateLabel(model.update)).font(.callout).foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("dossier.updating")
        }
        rebuildButton(compact: compact)
        accessory
      }
      .padding(.horizontal, 12)
      .frame(height: 40)
      .background(.bar)
      Divider()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("dossier.header")
  }

  private var breadcrumb: some View {
    Text(Self.breadcrumbText(model: model))
      .lineLimit(1)
      .truncationMode(.middle)
      .accessibilityLabel(Self.accessibilityLabel(model: model))
      .accessibilityHint(Self.accessibilityHint(model: model) ?? "")
      .accessibilityIdentifier("dossier.breadcrumb")
      #if os(macOS)
        .help(Self.helpText(model: model) ?? "")
      #endif
  }

  private func rebuildButton(compact: Bool) -> some View {
    HStack(spacing: 4) {
      Button {
        model.rebuild()
      } label: {
        if compact {
          Label("Rebuild", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
        } else {
          Label("Rebuild", systemImage: "arrow.clockwise")
        }
      }
      .disabled(model.rebuild.isRebuilding)
      .accessibilityIdentifier("dossier.rebuild")
      if model.rebuild.isRebuilding {
        ProgressView().controlSize(.small)
      }
    }
  }

  // MARK: Pure parts

  /// "title › shown name", or the shown name alone when there's no title (DH-4.2).
  static func breadcrumbText(model: DossierHeaderModel) -> String {
    let shown = shownName(model)
    guard let title = model.project.title, !title.isEmpty else { return shown }
    return "\(title) › \(shown)"
  }

  /// The items on show (DH-5): at compact width the role badge goes, then the update label.
  static func visibleItems(compact: Bool) -> [Item] {
    compact ? [] : [.roleBadge, .updateLabel]
  }

  /// What VoiceOver reads for the breadcrumb (DH-7): the parts joined by commas, with no `›`.
  static func accessibilityLabel(model: DossierHeaderModel) -> String {
    var parts: [String] = []
    if let title = model.project.title, !title.isEmpty { parts.append(title) }
    parts.append(shownName(model))
    if let role = model.role { parts.append(role) }
    return parts.joined(separator: ", ")
  }

  /// The bundle's path, and the canonical `character` when a display name is shown (DH-6).
  /// `nil` when there's nothing to add.
  static func accessibilityHint(model: DossierHeaderModel) -> String? {
    var parts: [String] = []
    if model.displayName != nil { parts.append(model.character) }
    if let path = model.project.bundlePath, !path.isEmpty { parts.append(path) }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  /// The breadcrumb's help text on macOS (DH-6). The same text as the hint.
  static func helpText(model: DossierHeaderModel) -> String? { accessibilityHint(model: model) }

  /// The update state's label: the marker's, else "Updating…" (DH-4.5).
  static func updateLabel(_ update: UpdateStatus) -> String {
    update.activeMarkers.compactMap(\.label).first { !$0.isEmpty } ?? "Updating…"
  }

  private static func shownName(_ model: DossierHeaderModel) -> String { model.displayName ?? model.character }
}

extension DossierHeader where Accessory == EmptyView {
  /// A header with nothing after Rebuild.
  public init(model: DossierHeaderModel) {
    self.init(model: model) { EmptyView() }
  }
}
