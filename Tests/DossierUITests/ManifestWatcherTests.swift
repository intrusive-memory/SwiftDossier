import Darwin
import Foundation
import Synchronization
import Testing

@testable import DossierUI

/// PV-20. The decision is pure, so these take snapshots of real files and compare them. Nothing
/// here waits on the file system or on time.
@Suite("ManifestWatcher")
struct ManifestWatcherTests {
  /// Replaces `manifest.json` by writing a sibling and renaming it over, as a writer does.
  private static func replaceManifest(in bundle: URL, adding key: String) throws {
    let manifest = bundle.appendingPathComponent("manifest.json")
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    object[key] = UUID().uuidString
    let temporary = bundle.appendingPathComponent(".manifest-\(UUID().uuidString).tmp")
    try JSONSerialization.data(withJSONObject: object).write(to: temporary)
    #expect(rename(temporary.path, manifest.path) == 0)
  }

  @Test("An atomic replace of manifest.json reports a manifest change")
  func replaceReports() throws {
    let project = try UIProject()
    let before = BundleSnapshot(bundleURL: project.bundleURL)
    #expect(BundleSnapshot.change(from: before, to: before) == nil)

    try Self.replaceManifest(in: project.bundleURL, adding: "x-one")
    #expect(BundleSnapshot.change(from: before, to: BundleSnapshot(bundleURL: project.bundleURL)) == .manifest)
  }

  @Test("Two replaces in a row each report")
  func twoReplacesReport() throws {
    let project = try UIProject()
    let first = BundleSnapshot(bundleURL: project.bundleURL)
    try Self.replaceManifest(in: project.bundleURL, adding: "x-one")
    let second = BundleSnapshot(bundleURL: project.bundleURL)
    try Self.replaceManifest(in: project.bundleURL, adding: "x-two")
    let third = BundleSnapshot(bundleURL: project.bundleURL)

    #expect(BundleSnapshot.change(from: first, to: second) == .manifest)
    #expect(BundleSnapshot.change(from: second, to: third) == .manifest)
  }

  @Test("A replace with the same bytes still reports, as it's a new file")
  func sameBytesReport() throws {
    let project = try UIProject()
    let manifest = project.bundleURL.appendingPathComponent("manifest.json")
    let bytes = try Data(contentsOf: manifest)
    let before = BundleSnapshot(bundleURL: project.bundleURL)
    let temporary = project.bundleURL.appendingPathComponent(".manifest.tmp")
    try bytes.write(to: temporary)
    #expect(rename(temporary.path, manifest.path) == 0)
    #expect(BundleSnapshot.change(from: before, to: BundleSnapshot(bundleURL: project.bundleURL)) == .manifest)
  }

  @Test("Writing in .preview/, or making it, reports nothing")
  func previewWritesReportNothing() throws {
    let project = try UIProject()
    let before = BundleSnapshot(bundleURL: project.bundleURL)

    try FileManager.default.createDirectory(at: project.storeURL, withIntermediateDirectories: true)
    #expect(BundleSnapshot.change(from: before, to: BundleSnapshot(bundleURL: project.bundleURL)) == nil)

    try project.storePreview()
    try Data("more".utf8).write(to: project.storeURL.appendingPathComponent("other.html"))
    #expect(BundleSnapshot.change(from: before, to: BundleSnapshot(bundleURL: project.bundleURL)) == nil)
  }

  @Test("A marker appearing, and disappearing, reports")
  func markersReport() throws {
    let project = try UIProject()
    let before = BundleSnapshot(bundleURL: project.bundleURL)
    let marker = project.bundleURL.appendingPathComponent(".update-tester.json")
    try Data("{}".utf8).write(to: marker)
    let during = BundleSnapshot(bundleURL: project.bundleURL)
    #expect(BundleSnapshot.change(from: before, to: during) == .markers)

    try FileManager.default.removeItem(at: marker)
    #expect(BundleSnapshot.change(from: during, to: BundleSnapshot(bundleURL: project.bundleURL)) == .markers)
  }

  @Test("A watcher reports a change once, and a cancelled one never reports")
  func cancelStopsReports() throws {
    let project = try UIProject()
    let reports = Mutex(0)
    // No event source: nothing reaches the watcher but handleEvent().
    let watcher = try #require(
      ManifestWatcher(bundleURL: project.bundleURL, activating: false) { _ in reports.withLock { $0 += 1 } })
    #expect(!watcher.isCancelled)
    watcher.handleEvent()
    #expect(reports.withLock { $0 } == 0)

    try Self.replaceManifest(in: project.bundleURL, adding: "x-one")
    watcher.handleEvent()
    #expect(reports.withLock { $0 } == 1)
    watcher.handleEvent()  // nothing new since
    #expect(reports.withLock { $0 } == 1)

    watcher.cancel()
    #expect(watcher.isCancelled)
    try Self.replaceManifest(in: project.bundleURL, adding: "x-two")
    watcher.handleEvent()
    #expect(reports.withLock { $0 } == 1)
  }

  @Test("The real event source can be made and cancelled")
  func liveSourceConstructs() throws {
    let project = try UIProject()
    let watcher = try #require(ManifestWatcher(bundleURL: project.bundleURL) { _ in })
    watcher.cancel()
    #expect(watcher.isCancelled)
    let missing = project.root.appendingPathComponent("nowhere.dossier")
    #expect(ManifestWatcher(bundleURL: missing) { _ in } == nil)
  }
}
