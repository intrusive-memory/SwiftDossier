import Darwin
import Dispatch
import Foundation
import Synchronization

/// What changed in a bundle's root, as far as a viewer cares (PV-20).
public struct ManifestChange: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// `manifest.json` was replaced, changed, made or removed.
  public static let manifest = ManifestChange(rawValue: 1)
  /// An `.update-*.json` marker appeared or disappeared.
  public static let markers = ManifestChange(rawValue: 2)
}

/// What a bundle's root held at one moment, as far as a viewer cares: `manifest.json`'s identity,
/// size and times, and the names of the `.update-*.json` markers. Nothing inside a subdirectory
/// is looked at, so the viewer's own `.preview/` store can't show up as a change.
///
/// The decision is pure and synchronous: take a snapshot, take another later, and
/// ``change(from:to:)`` says what differs.
public struct BundleSnapshot: Equatable, Sendable {
  private var manifest: [Int64]?
  private var markers: [String]

  /// The bundle root as it is now.
  public init(bundleURL: URL) {
    var info = stat()
    if lstat(bundleURL.appendingPathComponent("manifest.json").path, &info) == 0 {
      manifest = [
        Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mtimespec.tv_sec),
        Int64(info.st_mtimespec.tv_nsec)
      ]
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: bundleURL.path)) ?? []
    markers = names.filter { $0.hasPrefix(".update-") && $0.hasSuffix(".json") }.sorted()
  }

  /// What differs between `before` and `after`, or `nil` when nothing a viewer shows does.
  public static func change(from before: BundleSnapshot, to after: BundleSnapshot) -> ManifestChange? {
    var change: ManifestChange = []
    if before.manifest != after.manifest { change.insert(.manifest) }
    if before.markers != after.markers { change.insert(.markers) }
    return change.isEmpty ? nil : change
  }
}

/// Something that reports changes to a bundle, and can be stopped.
public protocol ManifestWatching: AnyObject, Sendable {
  /// Stops reporting. Nothing is reported once this returns.
  func cancel()
}

/// Starts a ``ManifestWatching`` for a bundle. ``DossierViewModel`` takes one, so a test can send
/// it events directly.
public protocol ManifestWatchStarting: Sendable {
  /// Reports to `onChange` whenever something a viewer shows changes in `bundleURL`.
  func watch(bundleURL: URL, onChange: @escaping @Sendable () -> Void) -> (any ManifestWatching)?
}

/// The real source: ``ManifestWatcher``.
public struct DirectoryWatchStarter: ManifestWatchStarting {
  public init() {}

  public func watch(bundleURL: URL, onChange: @escaping @Sendable () -> Void) -> (any ManifestWatching)? {
    ManifestWatcher(bundleURL: bundleURL) { _ in onChange() }
  }
}

/// A file-system event source on a bundle directory, with no polling (PV-20).
///
/// Writers replace `manifest.json` by atomic rename, which a watch on the file would lose. So this
/// watches the bundle directory, which reports entries made, renamed and removed in it and keeps
/// reporting after the file is replaced. An event says only that something in the directory
/// changed (making `.preview/` is one), so each is judged by ``BundleSnapshot``: only a
/// difference is reported. Changing `manifest.json` in place, without a rename, isn't seen.
///
/// The shell is thin on purpose: the event source calls ``handleEvent()``, which takes a snapshot,
/// asks ``BundleSnapshot/change(from:to:)`` and reports.
public final class ManifestWatcher: ManifestWatching {
  private struct State {
    var last: BundleSnapshot
    var cancelled = false
  }

  private final class Guarded: Sendable {
    let state: Mutex<State>
    init(_ state: State) { self.state = Mutex(state) }
  }

  private let bundleURL: URL
  private let guarded: Guarded
  private let onChange: @Sendable (ManifestChange) -> Void
  private let source: (any DispatchSourceFileSystemObject)?

  /// Starts watching `bundleURL`.
  ///
  /// - Parameters:
  ///   - bundleURL: The `.dossier` directory.
  ///   - onChange: Called, on a private queue, once per observed change. Never called after
  ///     ``cancel()`` returns.
  /// - Returns: `nil` when the directory can't be opened.
  public convenience init?(bundleURL: URL, onChange: @escaping @Sendable (ManifestChange) -> Void) {
    self.init(bundleURL: bundleURL, activating: true, onChange: onChange)
  }

  /// `activating: false` builds the watcher without an event source: nothing reaches it but
  /// ``handleEvent()``. For tests.
  init?(bundleURL: URL, activating: Bool, onChange: @escaping @Sendable (ManifestChange) -> Void) {
    var descriptor: Int32 = -1
    if activating {
      descriptor = open(bundleURL.path, O_EVTONLY)
      guard descriptor >= 0 else { return nil }
    }
    self.bundleURL = bundleURL
    self.onChange = onChange
    guarded = Guarded(State(last: BundleSnapshot(bundleURL: bundleURL)))
    if activating {
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
        queue: DispatchQueue(label: "DossierUI.ManifestWatcher"))
      let fd = descriptor
      source.setCancelHandler { close(fd) }
      self.source = source
      source.setEventHandler { [weak self] in self?.handleEvent() }
      source.resume()
    } else {
      source = nil
    }
  }

  /// Whether ``cancel()`` has been called.
  var isCancelled: Bool { guarded.state.withLock { $0.cancelled } }

  /// What the event source calls: reports a change since the last event, unless cancelled.
  func handleEvent() {
    let bundleURL = self.bundleURL
    // Snapshot, compare and store under one lock, so a late event can't report a step backwards.
    let change = guarded.state.withLock { state -> ManifestChange? in
      guard !state.cancelled else { return nil }
      let now = BundleSnapshot(bundleURL: bundleURL)
      guard let change = BundleSnapshot.change(from: state.last, to: now) else { return nil }
      state.last = now
      return change
    }
    if let change { onChange(change) }
  }

  public func cancel() {
    guarded.state.withLock { $0.cancelled = true }
    source?.cancel()
  }

  deinit { cancel() }
}
