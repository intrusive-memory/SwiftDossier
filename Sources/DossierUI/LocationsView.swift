import Dossier
import Foundation
import SwiftUI

/// Holds the view's model, made on first use: SwiftUI may run a view's `init` many times. A new
/// project directory makes a new model; every other input is pushed into the one there is, so a
/// new selection scrolls the page already showing (LV-6).
@MainActor
private final class LocationsModelHolder {
  private var model: LocationsPaneModel?

  func model(projectDirectory: URL, selectedBundleURL: URL?, refreshToken: AnyHashable?) -> LocationsPaneModel {
    if let model, model.projectDirectory == projectDirectory { return model }
    let made = LocationsPaneModel(
      projectDirectory: projectDirectory, selectedBundleURL: selectedBundleURL, refreshToken: refreshToken)
    model = made
    return made
  }
}

/// The locations pane of a project (LV-1): the ``LocationsHeader``, the validator's findings for
/// what is selected (LV-4), and then the project's LOCATIONS page (§16.6), scrolled to the
/// selected location's section (§16.7).
///
/// In place of the page it shows one of: a note that the selected bundle isn't one of the
/// project's locations (LV-7), the `E-CAST` finding of an index or `PROJECT.md` that can't be read
/// (LV-4), or progress while the page is built.
///
/// The view reads the project when it appears, and again when `refreshToken` changes (LV-11).
/// Changing `selectedBundleURL` to another location on the page only scrolls it (LV-6).
public struct LocationsView: View {
  private let projectDirectory: URL
  private let selectedBundleURL: URL?
  private let refreshToken: AnyHashable?
  private let project: DossierProjectContext
  @State private var holder = LocationsModelHolder()

  /// - Parameters:
  ///   - projectDirectory: The directory holding `PROJECT.md`.
  ///   - selectedBundleURL: The location bundle selected in the host, or `nil` for the whole
  ///     project, shown from the top.
  ///   - refreshToken: Any value; changing it shows the page again.
  ///   - project: What the host knows about the project. The header shows its title.
  public init(
    projectDirectory: URL, selectedBundleURL: URL?, refreshToken: AnyHashable? = nil,
    project: DossierProjectContext = DossierProjectContext()
  ) {
    self.projectDirectory = projectDirectory
    self.selectedBundleURL = selectedBundleURL
    self.refreshToken = refreshToken
    self.project = project
  }

  public var body: some View {
    let model = holder.model(
      projectDirectory: projectDirectory, selectedBundleURL: selectedBundleURL, refreshToken: refreshToken)
    let state = Self.state(of: model)
    VStack(spacing: 0) {
      LocationsHeader(
        title: project.title, path: model.selectedBundlePath, isUpdating: model.isUpdating,
        isBuilding: model.isBuilding, canRebuild: state.canRebuild
      ) {
        Task { await model.rebuild() }
      }
      notes(model)
      findings(Self.listedFindings(model.findings, state: state))
      content(state, section: model.section)
    }
    .overlay(alignment: .topLeading) { sectionProbe(model.section) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("locations.view")
    .task(id: projectDirectory) { await model.show() }
    .onChange(of: selectedBundleURL) { _, new in model.selectedBundleURL = new }
    .onChange(of: refreshToken) { _, new in model.refreshToken = new }
  }

  // MARK: What shows in the page's place

  /// What the view shows under the findings.
  enum State: Equatable {
    /// The page, scrolled to the model's section.
    case page(PreviewContent)
    /// Progress while the page is built and there is no page to show yet.
    case building
    /// The selected bundle isn't one of the project's locations (LV-7).
    case orphan
    /// `PROJECT.md` or the index can't be read: its `E-CAST` findings, in the page's place (LV-4).
    case unreadable([String])
    /// Why nothing can be shown, in plain words.
    case failed(String)
    /// Nothing yet.
    case empty

    /// The accessibility identifier of what's shown, or `nil` for nothing.
    var identifier: String? {
      switch self {
      case .page: return "locations.page"
      case .building: return "locations.building"
      case .orphan: return "locations.orphan"
      case .unreadable: return "locations.unreadable"
      case .failed: return "locations.failed"
      case .empty: return nil
      }
    }

    /// Whether **Rebuild** has a page to build. No page is built for an orphan (LV-7), and
    /// there's none to build from an index that can't be read.
    var canRebuild: Bool {
      switch self {
      case .orphan, .unreadable: return false
      case .page, .building, .failed, .empty: return true
      }
    }
  }

  /// What the model shows in the page's place. A page wins, so a rebuild keeps the page showing.
  static func state(of model: LocationsPaneModel) -> State {
    if let content = model.previewContent { return .page(content) }
    if model.isBuilding { return .building }
    if model.isOrphan { return .orphan }
    let cast = model.findings.filter { $0.code == .cast }
    if !cast.isEmpty { return .unreadable(cast.map(Self.text(of:))) }
    if let failure = model.failure { return .failed(failure) }
    return .empty
  }

  /// The findings listed above the page: all of them, less the `E-CAST` findings shown in the
  /// page's place.
  static func listedFindings(_ findings: [Finding], state: State) -> [Finding] {
    guard case .unreadable = state else { return findings }
    return findings.filter { $0.code != .cast }
  }

  /// What a finding reads as: its code, its path when it has one, and its message.
  static func text(of finding: Finding) -> String {
    if let path = finding.path, !path.isEmpty {
      return "\(finding.code.rawValue) \(path): \(finding.message)"
    }
    return "\(finding.code.rawValue): \(finding.message)"
  }

  /// The section the page is scrolled to, for UI tests: the section id, or `top` in project mode.
  static func sectionValue(_ section: String?) -> String { section ?? "top" }

  // MARK: Notes

  @ViewBuilder
  private func notes(_ model: LocationsPaneModel) -> some View {
    if let text = model.storeNote {
      note(text, systemImage: "externaldrive.badge.exclamationmark")
        .accessibilityIdentifier("locations.note.store")
    }
  }

  /// One note, as ``DossierView`` draws its notes.
  private func note(_ text: String, systemImage: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage)
      Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.yellow.opacity(0.15))
    .accessibilityElement(children: .contain)
  }

  // MARK: Findings (LV-4)

  @ViewBuilder
  private func findings(_ findings: [Finding]) -> some View {
    if !findings.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
          Label {
            Text(Self.text(of: finding)).font(.callout)
          } icon: {
            Image(systemName: finding.level == .error ? "xmark.octagon" : "exclamationmark.triangle")
              .foregroundStyle(finding.level == .error ? .red : .orange)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("locations.findings")
      Divider()
    }
  }

  // MARK: Body

  @ViewBuilder
  private func content(_ state: State, section: String?) -> some View {
    switch state {
    case .page(let content):
      PreviewWebView(content: content, section: section)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("locations.page")
    case .building:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("locations.building")
    case .orphan:
      message("This bundle isn't one of the project's locations, so it has no section on the LOCATIONS page.")
        .accessibilityIdentifier("locations.orphan")
    case .unreadable(let lines):
      message(lines.joined(separator: "\n"))
        .accessibilityIdentifier("locations.unreadable")
    case .failed(let reason):
      message(reason)
        .accessibilityIdentifier("locations.failed")
    case .empty:
      Spacer(minLength: 0)
    }
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .multilineTextAlignment(.center)
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// A leaf element whose value is the section the page is scrolled to. `.opacity(0)` would take
  /// it out of the accessibility tree, so it's drawn clear and 1 pt square instead.
  private func sectionProbe(_ section: String?) -> some View {
    let value = Self.sectionValue(section)
    return Text(value)
      .font(.system(size: 1))
      .foregroundStyle(.clear)
      .frame(width: 1, height: 1)
      .clipped()
      .allowsHitTesting(false)
      .accessibilityValue(value)
      .accessibilityIdentifier("locations.section")
  }
}

/// The locations pane's header (LV-8): the project's title, the selected bundle's path as visible
/// text, the update state, and **Rebuild** (LV-3). It has no accessory, so no character hand-off
/// can be put in it.
struct LocationsHeader: View {
  let title: String?
  let path: String?
  let isUpdating: Bool
  let isBuilding: Bool
  let canRebuild: Bool
  let rebuild: () -> Void
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(
    title: String?, path: String?, isUpdating: Bool, isBuilding: Bool, canRebuild: Bool,
    rebuild: @escaping () -> Void
  ) {
    self.title = title
    self.path = path
    self.isUpdating = isUpdating
    self.isBuilding = isBuilding
    self.canRebuild = canRebuild
    self.rebuild = rebuild
  }

  var body: some View {
    let compact = horizontalSizeClass == .compact
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "map")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(Self.titleText(title))
          .lineLimit(1)
          .accessibilityIdentifier("locations.header.title")
        if let path = Self.pathText(path) {
          Text(path)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityIdentifier("locations.header.path")
        }
        Spacer(minLength: 8)
        if isUpdating {
          HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            if !compact {
              Text(Self.updateLabel).font(.callout).foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("locations.updating")
        }
        HStack(spacing: 4) {
          Button(action: rebuild) {
            if compact {
              Label(Self.rebuildTitle, systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            } else {
              Label(Self.rebuildTitle, systemImage: "arrow.clockwise")
            }
          }
          .disabled(isBuilding || !canRebuild)
          .accessibilityIdentifier("locations.rebuild")
          if isBuilding {
            ProgressView().controlSize(.small)
          }
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 40)
      .background(.bar)
      Divider()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("locations.header")
  }

  // MARK: Pure parts

  /// **Rebuild**'s title, the same as a character's.
  static let rebuildTitle = "Rebuild"

  /// The update state's label, the fallback of ``DossierHeader``'s.
  static let updateLabel = "Updating…"

  /// The project's title, or "Locations" when the host has none.
  static func titleText(_ title: String?) -> String {
    guard let title, !title.isEmpty else { return "Locations" }
    return title
  }

  /// The selected bundle's path relative to the project, shown inline (LV-8), or `nil` in project
  /// mode.
  static func pathText(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    return path
  }

  /// Every string the header can draw, for the LV-8 check that none of it is a hand-off.
  static func texts(title: String?, path: String?) -> [String] {
    [titleText(title), pathText(path), updateLabel, rebuildTitle].compactMap { $0 }
  }
}
