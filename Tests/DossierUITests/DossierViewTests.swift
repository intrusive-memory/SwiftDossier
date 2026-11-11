import DossierCore
import Foundation
import SwiftUI
import Testing

@testable import DossierUI

@Suite("DossierView")
@MainActor
struct DossierViewTests {
  /// Records every key `onField` receives.
  @MainActor
  final class FieldLog {
    var keys: [String] = []
    func record(_ key: String) { keys.append(key) }
  }

  private static let bundleURL = URL(fileURLWithPath: "/nonexistent/characters/THE TINKER.dossier")

  @Test("onField receives the key a page posts (DH-12)")
  func onFieldReceivesPostedKey() {
    let log = FieldLog()
    DossierView<DossierHeader<EmptyView>>.handleMessage(
      name: "dossier", body: "expressions.happy", onField: log.record)
    #expect(log.keys == ["expressions.happy"])
  }

  @Test("onField ignores a body that isn't a string, and other handlers' messages (DH-12)")
  func onFieldIgnoresNonStringBody() {
    let log = FieldLog()
    typealias Viewer = DossierView<DossierHeader<EmptyView>>
    Viewer.handleMessage(name: "dossier", body: 42, onField: log.record)
    Viewer.handleMessage(name: "dossier", body: ["key": "expressions.happy"], onField: log.record)
    Viewer.handleMessage(name: "dossier", body: NSNull(), onField: log.record)
    Viewer.handleMessage(name: "other", body: "expressions.happy", onField: log.record)
    #expect(log.keys.isEmpty)
  }

  @Test("With no onField, a message does nothing")
  func noHandlerDoesNothing() {
    DossierView<DossierHeader<EmptyView>>.handleMessage(name: "dossier", body: "logline", onField: nil)
  }

  @Test("The default initializers draw the standard header (DH-8)")
  func defaultDrawsStandardHeader() {
    let plain = DossierView(bundleURL: Self.bundleURL, cast: nil)
    #expect(plain.drawsStandardHeader)
    let withAccessory = DossierView(
      bundleURL: Self.bundleURL, cast: nil, project: DossierProjectContext(title: "The Lamp Keepers")
    ) {
      Text("More")
    }
    #expect(withAccessory.drawsStandardHeader)
  }

  @Test("The custom-header initializer draws no DossierHeader (DH-9)")
  func customHeaderDrawsNoStandardHeader() {
    let view = DossierView(bundleURL: Self.bundleURL, cast: nil) { model in
      Text(model.character)
    }
    #expect(!view.drawsStandardHeader)
    #expect(type(of: view) == DossierView<Text>.self)
  }

  @Test("The header model comes from the bundle the view model opened (DH-11)")
  func headerModelFromOpenedBundle() throws {
    let project = try UIProject()
    defer { try? FileManager.default.removeItem(at: project.root) }
    try project.storePreview()
    let model = DossierViewModel(bundleURL: project.bundleURL, watching: ManualWatching())
    let header = DossierView<Text>.headerModel(
      model, project: DossierProjectContext(title: "The Lamp Keepers"),
      rebuild: DossierRebuildAction(perform: {}))
    #expect(model.bundle != nil)
    #expect(header.character == UIProject.character)
    #expect(header.role == "Lead")
    #expect(header.project.title == "The Lamp Keepers")
    #expect(!header.update.isUpdating)
  }

  @Test("A bundle that can't be opened gives the stem and no role (DH-11)")
  func headerModelWhenBundleCannotOpen() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DossierViewTests-\(UUID().uuidString)", isDirectory: true)
    let bundleURL = root.appendingPathComponent("THE GHOST.dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DossierViewModel(bundleURL: bundleURL, watching: ManualWatching())
    let header = DossierView<Text>.headerModel(
      model, project: DossierProjectContext(), rebuild: DossierRebuildAction(perform: {}))
    #expect(model.bundle == nil)
    #expect(header.character == "THE GHOST")
    #expect(header.role == nil)
  }
}
