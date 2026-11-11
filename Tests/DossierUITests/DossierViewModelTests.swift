import Dossier
import DossierCore
import Foundation
import Testing

@testable import DossierUI

/// Acceptance item 15: the viewer's state machine, without UI automation.
@Suite("DossierViewModel")
@MainActor
struct DossierViewModelTests {
  @Test("A miss goes loading, then page, with one build")
  func missLoadsThenShows() async throws {
    let project = try UIProject()
    let builder = RecordingBuilder()
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: builder, watching: ManualWatching())
    let log = StateLog(model)

    await model.inFlight?.value
    let page = try #require(model.state.page)
    #expect(!page.hit)
    #expect(page.pageURL != nil)
    #expect(page.key == (try DossierBundle.openForPreview(at: project.bundleURL, cast: nil).previewKey()))
    #expect(log.names == ["loading", "page"])
    #expect(builder.calls == [.build(project.bundleURL)])
    #expect(model.storeNote == nil)
  }

  @Test("A hit goes straight to page: no loading, no build")
  func hitShowsAtOnce() async throws {
    let project = try UIProject()
    let stored = try project.storePreview()
    let builder = RecordingBuilder()
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: builder, watching: ManualWatching())
    let log = StateLog(model)

    #expect(model.inFlight == nil)
    let page = try #require(model.state.page)
    #expect(page.hit)
    #expect(page.pageURL == stored.pageURL)
    #expect(log.names == ["page"])
    #expect(builder.calls.isEmpty)
  }

  @Test("No CHARACTER.md gives failed, in plain words")
  func noDescriptionFails() async throws {
    let project = try UIProject(description: nil)
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: RecordingBuilder(), watching: ManualWatching())
    let log = StateLog(model)

    await model.inFlight?.value
    #expect(model.state.failure == .noCharacterDescription)
    #expect(model.state.failure?.message.contains("CHARACTER.md") == true)
    #expect(log.names == ["loading", "failed"])
  }

  @Test("A CHARACTER.md that isn't UTF-8, and a directory that isn't a bundle, give failed")
  func otherFailures() async throws {
    let project = try UIProject()
    try Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE, 0x0A]).write(to: project.descriptionURL)
    let notUTF8 = DossierViewModel(bundleURL: project.bundleURL, builder: RecordingBuilder(), watching: ManualWatching())
    await notUTF8.inFlight?.value
    #expect(notUTF8.state.failure == .characterDescriptionNotUTF8)

    let empty = project.root.appendingPathComponent("characters/NOBODY.dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let builder = RecordingBuilder()
    let notABundle = DossierViewModel(bundleURL: empty, builder: builder, watching: ManualWatching())
    #expect(notABundle.state.failure == .notABundle)
    #expect(notABundle.inFlight == nil)
    #expect(builder.calls.isEmpty)
  }

  @Test("When bundleURL changes mid-build, the build is cancelled and its late result discarded (PV-21)")
  func staleResultDiscarded() async throws {
    let first = try UIProject()
    let second = try UIProject()
    let builder = RecordingBuilder(holding: [.build(first.bundleURL)])
    let model = DossierViewModel(bundleURL: first.bundleURL, builder: builder, watching: ManualWatching())
    let log = StateLog(model)
    await builder.waitUntilStarted(.build(first.bundleURL))
    let held = try #require(model.inFlight)

    model.bundleURL = second.bundleURL
    #expect(held.isCancelled)
    await model.inFlight?.value
    let shown = try #require(model.state.page)
    let secondKey = try DossierBundle.openForPreview(at: second.bundleURL, cast: nil).previewKey()
    #expect(shown.key == secondKey)
    let namesBefore = log.names

    builder.release(.build(first.bundleURL))
    await held.value
    #expect(model.state.page?.key == secondKey)
    #expect(model.state.page?.pageURL == shown.pageURL)
    #expect(log.names == namesBefore)
    #expect(log.names == ["loading", "loading", "page"])
    #expect(builder.calls == [.build(first.bundleURL), .build(second.bundleURL)])
  }

  @Test("Changing cast cancels the build in flight, and shows the bundle again (PV-21)")
  func castChangeCancels() async throws {
    let project = try UIProject()
    let builder = RecordingBuilder(holding: [.build(project.bundleURL)])
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: builder, watching: ManualWatching())
    await builder.waitUntilStarted(.build(project.bundleURL))
    let held = try #require(model.inFlight)

    model.cast = project.root.appendingPathComponent("CAST.md")
    #expect(held.isCancelled)
    #expect(model.inFlight != nil)
    #expect(StateLog.name(model.state) == "loading")

    builder.release(.build(project.bundleURL))
    await held.value
    await model.inFlight?.value
    #expect(model.state.page != nil)
  }

  @Test("An active marker gives updating, with no key and no build, until it clears")
  func markerGivesUpdating() async throws {
    let project = try UIProject()
    let marker = try project.open().beginUpdate(label: "test update")
    // No key can be computed without manifest.json, so a failure here would mean one was.
    let manifest = project.bundleURL.appendingPathComponent("manifest.json")
    let manifestBytes = try Data(contentsOf: manifest)
    try FileManager.default.removeItem(at: manifest)
    let builder = RecordingBuilder()
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: builder, watching: ManualWatching())

    guard case .updating(let storedPage) = model.state else {
      Issue.record("expected updating, got \(StateLog.name(model.state))")
      return
    }
    #expect(storedPage == nil)
    #expect(builder.calls.isEmpty)

    try manifestBytes.write(to: manifest)
    model.refreshToken = 1
    #expect(StateLog.name(model.state) == "updating")
    #expect(builder.calls.isEmpty)

    try project.open().endUpdate(id: marker.id)
    model.refreshToken = 2
    await model.inFlight?.value
    #expect(model.state.page != nil)
    #expect(builder.calls == [.build(project.bundleURL)])
  }

  @Test("While a marker is active, the stored preview shows; once it clears, it's a hit")
  func markerShowsStoredPreview() async throws {
    let project = try UIProject()
    let stored = try project.storePreview()
    let marker = try project.open().beginUpdate(label: "test update")
    let builder = RecordingBuilder()
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: builder, watching: ManualWatching())

    guard case .updating(let storedPage) = model.state else {
      Issue.record("expected updating, got \(StateLog.name(model.state))")
      return
    }
    #expect(storedPage == stored.pageURL)

    try project.open().endUpdate(id: marker.id)
    model.refreshToken = "cleared"
    #expect(model.state.page?.hit == true)
    #expect(builder.calls.isEmpty)
  }

  @Test("rebuild() keeps the page visible while rebuilding, then shows the new page")
  func rebuildKeepsPage() async throws {
    let project = try UIProject()
    let builder = RecordingBuilder(holding: [.rebuild(project.bundleURL)])
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: builder, watching: ManualWatching())
    let log = StateLog(model)
    await model.inFlight?.value
    let before = try #require(model.state.page)

    model.rebuild()
    guard case .rebuilding(let showing) = model.state else {
      Issue.record("expected rebuilding, got \(StateLog.name(model.state))")
      return
    }
    #expect(showing?.pageURL == before.pageURL)
    #expect(model.isRebuilding)
    model.refreshToken = "ignored while rebuilding"
    #expect(model.isRebuilding)

    await builder.waitUntilStarted(.rebuild(project.bundleURL))
    builder.release(.rebuild(project.bundleURL))
    await model.inFlight?.value
    let after = try #require(model.state.page)
    #expect(!after.hit)
    #expect(after.html != nil)
    #expect(model.refreshNote == nil)
    #expect(log.names == ["loading", "page", "rebuilding", "page"])
    #expect(builder.calls == [.build(project.bundleURL), .rebuild(project.bundleURL)])
  }

  @Test("A rebuild whose refresh refuses shows the page and a dismissible refreshNote (PV-19)")
  func rebuildRefreshNote() async throws {
    let project = try UIProject()
    let portrait = try project.addPortrait()
    try FileManager.default.removeItem(at: project.bundleURL.appendingPathComponent(portrait.path))
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: RecordingBuilder(), watching: ManualWatching())
    await model.inFlight?.value

    model.rebuild()
    await model.inFlight?.value
    #expect(model.state.page != nil)
    #expect(model.refreshNote != nil)
    model.dismissRefreshNote()
    #expect(model.refreshNote == nil)
  }

  @Test("A page that can't be stored shows from memory with a dismissible storeNote (PV-23)")
  func storeNote() async throws {
    let project = try UIProject()
    try FileManager.default.createDirectory(at: project.storeURL, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.storeURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.storeURL.path) }
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: RecordingBuilder(), watching: ManualWatching())
    await model.inFlight?.value

    let page = try #require(model.state.page)
    #expect(page.pageURL == nil)
    #expect(page.html != nil)
    #expect(model.storeNote != nil)
    model.dismissStoreNote()
    #expect(model.storeNote == nil)
  }

  @Test("A manifest change while on page leads to a new key and page (PV-20)")
  func manifestChangeShowsNewKey() async throws {
    let project = try UIProject()
    try project.storePreview()
    let builder = RecordingBuilder()
    let watching = ManualWatching()
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: builder, watching: watching)
    let firstKey = try #require(model.state.page).key
    #expect(watching.started == [project.bundleURL])

    let pages = AsyncStream.makeStream(of: PreviewResult.self)
    model.onStateChange = { state in
      if let page = state.page { pages.continuation.yield(page) }
    }
    try project.addPortrait()  // replaces manifest.json
    watching.fire(project.bundleURL)  // what the event source would do

    var iterator = pages.stream.makeAsyncIterator()
    let page = try #require(await iterator.next())
    #expect(page.key != firstKey)
    #expect(page.key == (try DossierBundle.openForPreview(at: project.bundleURL, cast: nil).previewKey()))
    #expect(!page.hit)
    #expect(builder.calls == [.build(project.bundleURL)])
  }

  @Test("After bundleURL changes, the old source's events are ignored and its watcher cancelled")
  func oldSourceIgnored() async throws {
    let first = try UIProject()
    let second = try UIProject()
    try first.storePreview()
    try second.storePreview()
    let builder = RecordingBuilder()
    let watching = ManualWatching()
    let model = DossierViewModel(bundleURL: first.bundleURL, builder: builder, watching: watching)
    let oldToken = model.watchGeneration

    model.bundleURL = second.bundleURL
    #expect(model.watchGeneration == oldToken + 1)
    #expect(watching.cancelled == [first.bundleURL])
    #expect(watching.started == [first.bundleURL, second.bundleURL])

    let log = StateLog(model)
    model.sourceChanged(token: oldToken)
    #expect(log.names == ["page"])  // nothing shown again

    model.sourceChanged(token: model.watchGeneration)
    #expect(log.names == ["page", "page"])
    #expect(builder.calls.isEmpty)
  }

  @Test("An event during a rebuild doesn't cancel it")
  func eventDuringRebuild() async throws {
    let project = try UIProject()
    let builder = RecordingBuilder(holding: [.rebuild(project.bundleURL)])
    let model = DossierViewModel(bundleURL: project.bundleURL, builder: builder, watching: ManualWatching())
    await model.inFlight?.value
    model.rebuild()
    let held = try #require(model.inFlight)

    model.sourceChanged(token: model.watchGeneration)
    #expect(model.isRebuilding)
    #expect(!held.isCancelled)
    builder.release(.rebuild(project.bundleURL))
    await model.inFlight?.value
    #expect(model.state.page != nil)
  }
}
