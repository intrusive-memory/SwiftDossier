import DossierCore
import Foundation
import SwiftUI
import Testing

@testable import DossierUI

@Suite("DossierHeader")
struct DossierHeaderTests {
  private static func model(
    title: String? = "The Lamp Keepers", bundlePath: String? = nil,
    character: String = "WREN", displayName: String? = nil, role: String? = "Lead"
  ) -> DossierHeaderModel {
    DossierHeaderModel(
      project: DossierProjectContext(title: title, bundlePath: bundlePath),
      character: character, displayName: displayName, role: role,
      update: UpdateStatus.read(bundle: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), at: Date()),
      rebuild: DossierRebuildAction(perform: {}))
  }

  typealias Header = DossierHeader<EmptyView>

  @Test func breadcrumbWithTitle() {
    #expect(Header.breadcrumbText(model: Self.model()) == "The Lamp Keepers › WREN")
  }

  @Test func breadcrumbWithoutTitle() {
    #expect(Header.breadcrumbText(model: Self.model(title: nil)) == "WREN")
  }

  @Test func breadcrumbShowsDisplayName() {
    #expect(Header.breadcrumbText(model: Self.model(displayName: "Wren")) == "The Lamp Keepers › Wren")
  }

  @Test func regularWidthShowsEverything() {
    #expect(Header.visibleItems(compact: false) == [.roleBadge, .updateLabel])
  }

  @Test func compactDropsRoleBadgeThenUpdateLabel() {
    #expect(Header.visibleItems(compact: true).isEmpty)
    // The order: the badge is dropped first, so it's the first item in the full list.
    #expect(Header.visibleItems(compact: false).first == .roleBadge)
  }

  @Test func accessibilityLabelReadsLikeSpeech() {
    #expect(Header.accessibilityLabel(model: Self.model()) == "The Lamp Keepers, WREN, Lead")
    #expect(Header.accessibilityLabel(model: Self.model(title: nil, role: nil)) == "WREN")
    #expect(Header.accessibilityLabel(model: Self.model(displayName: "Wren")) == "The Lamp Keepers, Wren, Lead")
    #expect(!Header.accessibilityLabel(model: Self.model()).contains("›"))
  }

  @Test func hintIsBundlePathAndCanonicalCharacterWhenRenamed() {
    let path = "characters/WREN.dossier"
    #expect(Header.accessibilityHint(model: Self.model()) == nil)
    #expect(Header.accessibilityHint(model: Self.model(bundlePath: path)) == path)
    #expect(Header.accessibilityHint(model: Self.model(bundlePath: path, displayName: "Wren")) == "WREN, \(path)")
    #expect(Header.helpText(model: Self.model(bundlePath: path)) == path)
  }

  @Test func updateLabelFallsBack() {
    let idle = Self.model().update
    #expect(Header.updateLabel(idle) == "Updating…")
  }
}
