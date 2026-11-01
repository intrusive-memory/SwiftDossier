import DossierCore
import Foundation
import Synchronization
import Testing

@testable import Dossier

/// A clock and renewals that move only when a test says.
private final class Harness: Sendable {
  private struct State {
    var now: Date
    var events: [UpdateEnvironment.Event] = []
    var intervals: [TimeInterval] = []
    var ticks: [@Sendable () -> Void] = []
    var stops = 0
    var hook: (@Sendable (UpdateEnvironment.Event) -> Void)?
  }

  private let state: Mutex<State>
  let id: String?

  init(now: Date = Date(timeIntervalSince1970: 1_792_429_200), id: String? = nil) {
    state = Mutex(State(now: now))
    self.id = id
  }

  var now: Date { state.withLock { $0.now } }
  var events: [UpdateEnvironment.Event] { state.withLock { $0.events } }
  var intervals: [TimeInterval] { state.withLock { $0.intervals } }
  var stops: Int { state.withLock { $0.stops } }
  /// The ids of the markers written, in order, once each.
  var writtenIDs: [String] {
    events.compactMap { if case .wrote(let id) = $0 { return id } else { return nil } }
  }

  func advance(by seconds: TimeInterval) { state.withLock { $0.now.addTimeInterval(seconds) } }
  func onEvent(_ hook: @escaping @Sendable (UpdateEnvironment.Event) -> Void) { state.withLock { $0.hook = hook } }

  /// A renewal comes due, on this thread. A stopped one is still called, as a timer's last firing
  /// can be: what's tested is that it writes nothing.
  func fireRenewal() {
    for tick in state.withLock({ $0.ticks }) { tick() }
  }

  var environment: UpdateEnvironment {
    var environment = UpdateEnvironment()
    environment.now = { [self] in now }
    environment.lifetime = 900
    environment.renewalInterval = 300
    if let id { environment.makeID = { id } }
    environment.startRenewal = { [self] interval, tick in
      state.withLock {
        $0.intervals.append(interval)
        $0.ticks.append(tick)
      }
      return { [self] in state.withLock { $0.stops += 1 } }
    }
    environment.observe = { [self] event in
      let hook = state.withLock { state in
        state.events.append(event)
        return state.hook
      }
      hook?(event)
    }
    return environment
  }

  func run<Result>(_ body: () throws -> Result) rethrows -> Result {
    try UpdateHolding.$environment.withValue(environment, operation: body)
  }
}

private struct Boom: Error {}

/// `bundle` is touched only by the test that made it, the rest is constant.
private final class TemporaryBundle: @unchecked Sendable {
  let root: URL
  let url: URL
  var bundle: DossierBundle

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("UpdateMarkerTests-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    url = root.appendingPathComponent("THE TINKER.dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Manifest(character: "THE TINKER", updatedAt: "2026-01-01T00:00:00Z").encoded()
      .write(to: url.appendingPathComponent("manifest.json"))
    bundle = try DossierBundle.open(at: url)
  }
  deinit { try? FileManager.default.removeItem(at: root) }

  /// Hidden names in the root, the temporary ones included.
  var hiddenNames: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasPrefix(".") }.sorted()
  }
  var manifestBytes: Data { (try? Data(contentsOf: url.appendingPathComponent("manifest.json"))) ?? Data() }

  func marker(_ id: String) throws -> JSONObject {
    let data = try Data(contentsOf: url.appendingPathComponent(UpdateMarker.name(forID: id)))
    return try #require(UpdateMarker.object(in: data))
  }

  func put(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: url.appendingPathComponent(name))
  }

  /// A file to add. Under `source/` it keeps its name and needn't be an image.
  func source(_ name: String = "ref.txt", _ text: String = "reference\n") throws -> URL {
    let file = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: file)
    return file
  }
}

private func timestamp(_ date: Date) -> String { Timestamp.string(from: date) }

@Suite("withUpdate (§5.7, SD-14)")
struct WithUpdateTests {
  @Test("The marker is §5.7's, under a name that matches, for the length of the block")
  func marker() throws {
    let harness = Harness(id: "the-id")
    let temp = try TemporaryBundle()
    let start = harness.now
    try harness.run {
      try temp.bundle.withUpdate(label: "rendering") { bundle in
        #expect(temp.hiddenNames == [".update-the-id.json"], "the temporary name is gone")
        let object = try temp.marker("the-id")
        // SPEC-PIN: §5.7's table, by hand; the schema isn't in the pinned tag. See UpdateMarkerStore.
        #expect(Set(object.keys) == ["writer", "startedAt", "expiresAt", "label"])
        #expect(object["writer"]?.stringValue == "SwiftDossier")
        #expect(object["startedAt"]?.stringValue == timestamp(start))
        #expect(object["expiresAt"]?.stringValue == timestamp(start.addingTimeInterval(900)))
        #expect(object["label"]?.stringValue == "rendering")
        #expect(bundle.updateStatus(at: start).isUpdating)
        #expect(bundle.updateStatus(at: start).activeMarkers.map(\.label) == ["rendering"])
      }
    }
    #expect(temp.hiddenNames.isEmpty)
    #expect(!temp.bundle.updateStatus(at: start).isUpdating)
    #expect(harness.events.first == .wrote(id: "the-id"))
    #expect(harness.events.last == .removed(id: "the-id"))
  }

  @Test("A temporary name never matches the pattern, and a label is one line or none")
  func names() throws {
    for id in ["a", "the-id", "A9"] {
      #expect(UpdateMarker.id(fromName: UpdateMarkerStore.temporaryName(forID: id)) == nil)
      #expect(UpdateMarker.id(fromName: UpdateMarker.name(forID: id)) == id)
    }
    let date = Date(timeIntervalSince1970: 0)
    let split = UpdateMarkerStore.object(writer: "w", startedAt: date, expiresAt: date, label: "one\ntwo\r\nthree")
    #expect(split["label"]?.stringValue == "one two three")
    let empty = UpdateMarkerStore.object(writer: "w", startedAt: date, expiresAt: date, label: "\n")
    #expect(empty["label"] == nil, "the schema has minLength 1")
  }

  @Test("It's renewed in the background: a later expiresAt, the same startedAt, at the interval given")
  func renewal() throws {
    let harness = Harness(id: "the-id")
    let temp = try TemporaryBundle()
    let start = harness.now
    harness.run {
      temp.bundle.withUpdate { bundle in
        // Past what the first write promised, and still active because of the renewal.
        harness.advance(by: 899)
        harness.fireRenewal()
        harness.advance(by: 899)
        #expect(bundle.updateStatus(at: harness.now).isUpdating)
        #expect((try? temp.marker("the-id"))?["startedAt"]?.stringValue == timestamp(start))
        #expect((try? temp.marker("the-id"))?["expiresAt"]?.stringValue == timestamp(start.addingTimeInterval(1799)))
        #expect(temp.hiddenNames == [".update-the-id.json"])
      }
    }
    #expect(harness.intervals == [300])
    #expect(harness.stops == 1)
    #expect(temp.hiddenNames.isEmpty)
  }

  @Test("With no renewal it stops counting by itself")
  func expires() throws {
    let harness = Harness()
    let temp = try TemporaryBundle()
    harness.run {
      temp.bundle.withUpdate { bundle in
        #expect(bundle.updateStatus(at: harness.now.addingTimeInterval(899)).isUpdating)
        #expect(!bundle.updateStatus(at: harness.now.addingTimeInterval(900)).isUpdating)
      }
    }
  }

  @Test("The real timer renews, at an injected interval, with no sleep in the test")
  func liveTimer() throws {
    let temp = try TemporaryBundle()
    let renewed = DispatchSemaphore(value: 0)
    var environment = UpdateEnvironment()
    environment.renewalInterval = 0.001
    environment.observe = { if case .renewed = $0 { renewed.signal() } }
    let waited = UpdateHolding.$environment.withValue(environment) {
      temp.bundle.withUpdate { _ in renewed.wait(timeout: .now() + 60) }
    }
    #expect(waited == .success)
    #expect(temp.hiddenNames.isEmpty)
  }

  @Test("§5.7: expiresAt is no more than 3600 seconds ahead, as a default and as asked")
  func limit() throws {
    #expect(UpdateEnvironment().lifetime <= 3600)
    #expect(UpdateEnvironment().renewalInterval < UpdateEnvironment().lifetime)
    #expect(DossierBundle.defaultUpdateLifetime <= 3600)
    let temp = try TemporaryBundle()
    let now = Date(timeIntervalSince1970: 1_792_429_200)
    for bad in [3600.5, 3601, 0, -1, .infinity, .nan] {
      #expect(throws: DossierWriteError.self) { try temp.bundle.beginUpdate(lifetime: bad, now: now) }
    }
    #expect(temp.hiddenNames.isEmpty)
    let handle = try temp.bundle.beginUpdate(lifetime: 3600, now: now)
    #expect(handle.expiresAt == now.addingTimeInterval(3600))
    #expect(temp.bundle.updateStatus(at: now).isUpdating, "exactly at the limit counts")

    let later = now.addingTimeInterval(0.5)
    let renewed = try temp.bundle.renewUpdate(id: handle.id, lifetime: 3600, now: later)
    #expect(renewed.expiresAt <= later.addingTimeInterval(3600), "rounded down, never up")
    #expect(temp.bundle.updateStatus(at: later).isUpdating)
    #expect(throws: DossierWriteError.self) { try temp.bundle.renewUpdate(id: handle.id, lifetime: 3601, now: now) }
  }

  @Test("Nested calls show one update, whatever they're labelled")
  func nested() throws {
    let harness = Harness()
    let temp = try TemporaryBundle()
    let result = try harness.run {
      try temp.bundle.withUpdate(label: "outer") { outer -> Int in
        let names = temp.hiddenNames
        return try outer.withUpdate(label: "inner") { inner -> Int in
          #expect(temp.hiddenNames == names)
          #expect(inner.updateStatus(at: harness.now).activeMarkers.map(\.label) == ["outer"])
          try inner.withUpdate { deeper in
            #expect(temp.hiddenNames == names)
            try deeper.setPrompt(.identity, "one")
          }
          #expect(temp.hiddenNames == names, "an inner end doesn't remove the outer marker")
          return 7
        }
      }
    }
    #expect(result == 7)
    #expect(harness.writtenIDs.count == 1)
    #expect(temp.hiddenNames.isEmpty)
    #expect(temp.bundle.manifest.prompts?.identity == "one", "the block's changes reach the value")
  }

  @Test("Mutations in a block hold nothing of their own, and the marker outlasts the last replacement")
  func sequenceIsOneUpdate() throws {
    let harness = Harness()
    let temp = try TemporaryBundle()
    let file = try temp.source()
    let atRemoval = Mutex<Data?>(nil)
    harness.onEvent { event in
      if case .willRemove = event { atRemoval.withLock { $0 = temp.manifestBytes } }
    }
    try harness.run {
      try temp.bundle.withUpdate { bundle in
        try bundle.add(file, kind: .sourcePhoto)
        try bundle.setPrompt(.identity, "one")
        try bundle.select(path: "source/ref.txt")
        try bundle.setPrompt(.identity, "two")
      }
    }
    #expect(harness.writtenIDs.count == 1)
    #expect(atRemoval.withLock { $0 } == temp.manifestBytes, "nothing replaced the manifest after removal began")
    #expect(temp.bundle.manifest.prompts?.identity == "two")
  }

  @Test("Two bundles hold two markers, and the same bundle through another spelling holds one")
  func perBundle() throws {
    let harness = Harness()
    let first = try TemporaryBundle()
    let second = try TemporaryBundle()
    let link = first.root.appendingPathComponent("link.dossier")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first.url)
    try harness.run {
      try first.bundle.withUpdate { _ in
        second.bundle.withUpdate { _ in
          #expect(first.hiddenNames.count == 1)
          #expect(second.hiddenNames.count == 1)
        }
        #expect(second.hiddenNames.isEmpty)
        var viaLink = try DossierBundle.open(at: link)
        try viaLink.setPrompt(.identity, "through the link")
        #expect(first.hiddenNames.count == 1)
      }
    }
    #expect(harness.writtenIDs.count == 2)
  }

  @Test("A block that throws: the error comes through, the marker goes, and renewal has stopped")
  func throwing() throws {
    let harness = Harness(id: "the-id")
    let temp = try TemporaryBundle()
    #expect(throws: Boom.self) {
      try harness.run {
        try temp.bundle.withUpdate { bundle in
          try bundle.setPrompt(.identity, "kept")
          throw Boom()
        }
      }
    }
    #expect(temp.hiddenNames.isEmpty)
    #expect(harness.stops == 1)
    harness.fireRenewal()
    #expect(temp.hiddenNames.isEmpty, "a late firing doesn't bring it back")
    #expect(!harness.events.contains(.renewed(id: "the-id")))
    #expect(temp.bundle.manifest.prompts?.identity == "kept", "what was written stands")
  }

  @Test("A throw from a nested block ends the one marker once, at the outside")
  func nestedThrow() throws {
    let harness = Harness()
    let temp = try TemporaryBundle()
    harness.run {
      temp.bundle.withUpdate { outer in
        let names = temp.hiddenNames
        #expect(throws: Boom.self) { try outer.withUpdate { _ in throw Boom() } }
        #expect(temp.hiddenNames == names, "the caught inner failure leaves the update held")
      }
    }
    #expect(temp.hiddenNames.isEmpty)
    #expect(harness.writtenIDs.count == 1)
  }

  @Test("A renewal under way when the block ends finishes first, and can't bring the marker back")
  func cancelledDeterministically() throws {
    let harness = Harness(id: "the-id")
    let temp = try TemporaryBundle()
    let renewing = DispatchSemaphore(value: 0)
    let ending = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    harness.onEvent { event in
      switch event {
      case .willRenew:
        renewing.signal()
        ending.wait()  // Held in the renewal, until `end()` has started.
      case .willEnd:
        ending.signal()
      default:
        break
      }
    }
    harness.run {
      temp.bundle.withUpdate { _ in
        DispatchQueue.global().async {
          harness.fireRenewal()
          finished.signal()
        }
        renewing.wait()
      }
    }
    #expect(temp.hiddenNames.isEmpty)
    finished.wait()
    #expect(temp.hiddenNames.isEmpty)
    #expect(harness.events.suffix(2) == [.willRemove(id: "the-id"), .removed(id: "the-id")])
    #expect(harness.events.firstIndex(of: .renewed(id: "the-id"))! < harness.events.firstIndex(of: .willRemove(id: "the-id"))!)
  }

  @Test("The async block: held across a suspension, nested through a child task, removed on a throw")
  func asynchronous() async throws {
    let harness = Harness(id: "the-id")
    let temp = try TemporaryBundle()
    let environment = harness.environment
    var bundle = temp.bundle
    try await UpdateHolding.$environment.withValue(environment) {
      let result = try await bundle.withUpdate(label: "async") { bundle -> Int in
        await Task.yield()
        #expect(temp.hiddenNames == [".update-the-id.json"])
        try await withThrowingTaskGroup(of: Void.self) { group in
          let url = temp.url
          group.addTask {
            var child = try DossierBundle.open(at: url)
            try child.setPrompt(.identity, "from a child task")
          }
          try await group.waitForAll()
        }
        try await bundle.withUpdate(label: "nested") { inner in
          await Task.yield()
          try inner.setPrompt(.subject, "woman")
        }
        return 7
      }
      #expect(result == 7)
      #expect(temp.hiddenNames.isEmpty)

      await #expect(throws: Boom.self) {
        try await bundle.withUpdate { _ in
          await Task.yield()
          throw Boom()
        }
      }
    }
    #expect(temp.hiddenNames.isEmpty)
    #expect(harness.writtenIDs.count == 2, "one for each outer block, the mutations and nesting none")
    #expect(bundle.manifest.prompts?.subject == "woman")
  }

  @Test("A task that outlives its block doesn't count on the marker that has gone")
  func outlivingTask() async throws {
    let harness = Harness()
    let temp = try TemporaryBundle()
    let release = AsyncStream<Void>.makeStream()
    let url = temp.url
    let task = UpdateHolding.$environment.withValue(harness.environment) {
      temp.bundle.withUpdate { _ -> Task<Void, any Error> in
        Task {
          for await _ in release.stream { break }
          var bundle = try DossierBundle.open(at: url)
          try bundle.setPrompt(.identity, "later")
        }
      }
    }
    #expect(harness.writtenIDs.count == 1)
    release.continuation.yield()
    try await task.value
    #expect(harness.writtenIDs.count == 2, "it held its own")
    #expect(temp.hiddenNames.isEmpty)
  }
}

@Suite("A single mutation holds a marker (SD-14)")
struct MutationHoldsMarkerTests {
  /// Runs a mutation with a marker of a fixed id watched: the manifest as the marker appeared and
  /// as it was about to go.
  private func watch(
    _ temp: TemporaryBundle, _ mutation: (inout DossierBundle) throws -> Void
  ) rethrows -> Harness {
    let harness = Harness()
    let before = Mutex<Data?>(nil)
    let atRemoval = Mutex<Data?>(nil)
    harness.onEvent { event in
      switch event {
      case .wrote: before.withLock { $0 = temp.manifestBytes }
      case .willRemove: atRemoval.withLock { $0 = temp.manifestBytes }
      default: break
      }
    }
    let original = temp.manifestBytes
    try harness.run { try mutation(&temp.bundle) }
    #expect(temp.hiddenNames.isEmpty)
    if !harness.writtenIDs.isEmpty {
      #expect(before.withLock { $0 } == original, "the marker came before the change")
      #expect(atRemoval.withLock { $0 } == temp.manifestBytes, "and went after the last replacement")
      #expect(temp.manifestBytes != original)
    }
    return harness
  }

  @Test("Every mutation holds one, around its manifest replacement")
  func each() throws {
    let temp = try TemporaryBundle()
    let file = try temp.source()
    let second = try temp.source("other.txt", "other\n")

    #expect(try watch(temp) { try $0.add(file, kind: .sourcePhoto) }.writtenIDs.count == 1)
    #expect(try watch(temp) { try $0.select(path: "source/ref.txt") }.writtenIDs.count == 1)
    #expect(try watch(temp) { try $0.reject(path: "source/ref.txt") }.writtenIDs.count == 1)
    #expect(try watch(temp) { try $0.setPrompt(.identity, "one") }.writtenIDs.count == 1)
    #expect(try watch(temp) { try $0.add(second, kind: .sourcePhoto) }.writtenIDs.count == 1)
    #expect(try watch(temp) { try $0.remove(path: "source/other.txt") }.writtenIDs.count == 1)
    #expect(try watch(temp) { try CharacterDescription(text: "# The Tinker\n").write(to: &$0) }.writtenIDs.count == 1)

    let voice = temp.url.appendingPathComponent("voice")
    try FileManager.default.createDirectory(at: voice, withIntermediateDirectories: true)
    try Data("vox\n".utf8).write(to: voice.appendingPathComponent("THE TINKER.vox"))
    #expect(try watch(temp) { try $0.refresh() }.writtenIDs.count == 1)
  }

  @Test("A call that changes nothing, or is refused first, shows no update")
  func noChangeNoMarker() throws {
    let temp = try TemporaryBundle()
    try temp.bundle.setPrompt(.identity, "one")
    #expect(watch(temp) { try! $0.setPrompt(.identity, "one") }.writtenIDs.isEmpty)
    #expect(watch(temp) { try! $0.refresh() }.writtenIDs.isEmpty)
    #expect(
      watch(temp) { bundle in
        #expect(throws: DossierWriteError.self) { try bundle.select(path: "source/none.txt") }
      }.writtenIDs.isEmpty)
    #expect(
      watch(temp) { bundle in
        #expect(throws: DossierWriteError.self) { try bundle.remove(path: "source/none.txt") }
      }.writtenIDs.isEmpty)
  }

  @Test("A mutation that fails after it began still removes its marker")
  func failedMutation() throws {
    let temp = try TemporaryBundle()
    // Past `add`'s checks: the rescan refuses a zero-byte file in the inventory.
    try temp.put("empty.txt", "")
    let file = try temp.source()
    let harness = Harness()
    #expect(throws: DossierWriteError.self) {
      try harness.run { try temp.bundle.add(file, kind: .sourcePhoto) }
    }
    #expect(harness.writtenIDs.count == 1)
    #expect(temp.hiddenNames.isEmpty)
  }

  @Test("create holds none: the bundle arrives whole")
  func create() throws {
    let harness = Harness()
    let temp = try TemporaryBundle()
    let created = try harness.run {
      try DossierBundle.create(character: "THE LAMPLIGHTER", role: "guest", in: temp.root)
    }
    #expect(harness.writtenIDs.isEmpty)
    #expect(!created.bundle.updateStatus().isUpdating)
  }
}

@Suite("A marker is a signal, not a lock (§5.7)")
struct UpdateMarkerSignalTests {
  private static let now = Date(timeIntervalSince1970: 1_792_429_200)

  private func expires(_ offset: TimeInterval) -> String {
    #"{"writer": "other", "startedAt": "2026-01-01T00:00:00Z", "expiresAt": "\#(timestamp(Self.now.addingTimeInterval(offset)))"}"#
  }

  @Test("Another writer's active marker blocks nothing, and is left alone")
  func otherActive() throws {
    let temp = try TemporaryBundle()
    let other = expires(600)
    try temp.put(".update-other.json", other)
    let harness = Harness(now: Self.now)
    try harness.run {
      try temp.bundle.setPrompt(.identity, "written")
      temp.bundle.withUpdate { bundle in
        #expect(bundle.updateStatus(at: Self.now).activeMarkers.count == 2)
      }
    }
    #expect(temp.bundle.manifest.prompts?.identity == "written")
    #expect(temp.hiddenNames == [".update-other.json"])
    #expect(try Data(contentsOf: temp.url.appendingPathComponent(".update-other.json")) == Data(other.utf8))
  }

  @Test("Only an expired marker of another writer's is removed")
  func expired() throws {
    let temp = try TemporaryBundle()
    try temp.put(".update-past.json", expires(-1))
    try temp.put(".update-at-now.json", expires(0))
    try temp.put(".update-live.json", expires(1))
    try temp.put(".update-limit.json", expires(3600))
    try temp.put(".update-far.json", expires(3601))
    try temp.put(".update-garbled.json", "{")
    try temp.put(".update-empty.json", "")
    try temp.put(".update-shape.json", "[]")
    try temp.put(".update-offset.json", #"{"expiresAt": "2026-01-01T00:00:00+05:00"}"#)
    try temp.put(".update-a_b.json", expires(-1))
    let harness = Harness(now: Self.now)
    harness.run { temp.bundle.withUpdate { _ in } }
    #expect(
      temp.hiddenNames == [
        ".update-a_b.json", ".update-empty.json", ".update-far.json", ".update-garbled.json", ".update-limit.json",
        ".update-live.json", ".update-offset.json", ".update-shape.json",
      ])
  }

  @Test("A marker that can't be written doesn't stop the block, or what's there")
  func writeFails() throws {
    let temp = try TemporaryBundle()
    // A directory at the marker's name: the rename fails, and the removal must not touch it.
    let occupied = temp.url.appendingPathComponent(".update-the-id.json")
    try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
    let harness = Harness(id: "the-id")
    try harness.run {
      try temp.bundle.setPrompt(.identity, "written anyway")
    }
    #expect(temp.bundle.manifest.prompts?.identity == "written anyway")
    #expect(harness.events.contains(.writeFailed(id: "the-id")))
    #expect(temp.hiddenNames == [".update-the-id.json"], "no temporary file left")
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: occupied.path, isDirectory: &isDirectory) && isDirectory.boolValue)
  }

  @Test("A renewal that fails is tried again, and one after the bundle's gone makes nothing")
  func renewalFails() throws {
    let harness = Harness(id: "the-id")
    let temp = try TemporaryBundle()
    let marker = temp.url.appendingPathComponent(".update-the-id.json")
    harness.run {
      temp.bundle.withUpdate { _ in
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        harness.fireRenewal()
        #expect(harness.events.contains(.writeFailed(id: "the-id")))
        try? FileManager.default.removeItem(at: marker)
        harness.fireRenewal()
        #expect(harness.events.contains(.renewed(id: "the-id")), "lost, and written again")
        try? FileManager.default.removeItem(at: temp.url)
        harness.fireRenewal()
        #expect(!FileManager.default.fileExists(atPath: temp.url.path))
      }
    }
  }

  @Test("§5.2: a marker is outside files and the checksum, and a validator doesn't report it")
  func hidden() throws {
    let clean = try TemporaryBundle()
    let marked = try TemporaryBundle()
    for temp in [clean, marked] { try temp.bundle.add(try temp.source(), kind: .sourcePhoto, options: AddOptions(createdAt: Self.now)) }

    try marked.put(".update-a.json", expires(600))
    try marked.put(".update-empty.json", "")
    try marked.put(".update-garbled.json", "{")
    try marked.put(".update-a.json.tmp", "partial")

    let frozen = Harness(now: Self.now)
    try frozen.run {
      try clean.bundle.setPrompt(.identity, "one")
      try marked.bundle.setPrompt(.identity, "one")
    }
    #expect(marked.bundle.manifest.files.map(\.path) == ["source/ref.txt"])
    #expect(marked.bundle.manifest.files == clean.bundle.manifest.files)
    #expect(marked.bundle.manifest.manifestChecksum == clean.bundle.manifest.manifestChecksum)

    #expect(try marked.bundle.validate().findings.map(\.code) == clean.bundle.validate().findings.map(\.code))
    let expected = try clean.bundle.validate().findings.map(\.code)
    try marked.bundle.withUpdate { bundle in
      let codes = try bundle.validate().findings.map(\.code)
      #expect(codes == expected)
    }
    #expect(try marked.bundle.refresh().adopted.isEmpty)
    #expect(try marked.bundle.refresh().unclassified.isEmpty)
  }
}

@Suite("An update spanning separate calls (SD-14)")
struct SpanningUpdateTests {
  private static let now = Date(timeIntervalSince1970: 1_792_429_200)

  @Test("begin, renew and end")
  func cycle() throws {
    let temp = try TemporaryBundle()
    let begun = try temp.bundle.beginUpdate(label: "long", writer: "a tool", lifetime: 600, now: Self.now)
    #expect(UpdateMarker.isValidID(begun.id))
    #expect(temp.hiddenNames == [UpdateMarker.name(forID: begun.id)])
    let first = try temp.marker(begun.id)
    #expect(first["writer"]?.stringValue == "a tool")
    #expect(first["expiresAt"]?.stringValue == timestamp(Self.now.addingTimeInterval(600)))

    let later = Self.now.addingTimeInterval(500)
    let renewed = try temp.bundle.renewUpdate(id: begun.id, lifetime: 900, now: later)
    #expect(renewed.expiresAt == later.addingTimeInterval(900))
    let second = try temp.marker(begun.id)
    #expect(second["expiresAt"]?.stringValue == timestamp(later.addingTimeInterval(900)))
    #expect(second["startedAt"] == first["startedAt"])
    #expect(second["label"]?.stringValue == "long")
    #expect(temp.bundle.updateStatus(at: later.addingTimeInterval(899)).isUpdating)
    #expect(temp.hiddenNames.count == 1)

    try temp.bundle.endUpdate(id: begun.id)
    #expect(temp.hiddenNames.isEmpty)
    #expect(throws: DossierWriteError.updateMarkerNotFound(begun.id)) { try temp.bundle.endUpdate(id: begun.id) }
    #expect(throws: DossierWriteError.updateMarkerNotFound(begun.id)) { try temp.bundle.renewUpdate(id: begun.id) }
  }

  @Test("Renewing keeps keys this writer doesn't know, and refuses what isn't an object")
  func renewContent() throws {
    let temp = try TemporaryBundle()
    try temp.put(".update-a.json", #"{"expiresAt": "2026-01-01T00:00:00Z", "fromElsewhere": {"x": 1}}"#)
    try temp.bundle.renewUpdate(id: "a", now: Self.now)
    #expect(try temp.marker("a")["fromElsewhere"]?.objectValue?["x"]?.intValue == 1)
    let garbled = Data("{".utf8)
    try garbled.write(to: temp.url.appendingPathComponent(".update-b.json"))
    #expect(throws: DossierWriteError.updateMarkerUnreadable("b")) { try temp.bundle.renewUpdate(id: "b", now: Self.now) }
    #expect(try Data(contentsOf: temp.url.appendingPathComponent(".update-b.json")) == garbled)
  }

  @Test("An id can't name anything but a marker in this bundle", arguments: ["", "../x", "a/b", "a_b", "a.json", "é"])
  func badID(_ id: String) throws {
    let temp = try TemporaryBundle()
    #expect(throws: DossierWriteError.updateIDNotAllowed(id)) { try temp.bundle.endUpdate(id: id) }
    #expect(throws: DossierWriteError.updateIDNotAllowed(id)) { try temp.bundle.renewUpdate(id: id, now: Self.now) }
  }

  @Test("begin removes an expired marker of another writer's, and reports a marker it can't write")
  func beginSweepsAndReports() throws {
    let temp = try TemporaryBundle()
    try temp.put(".update-past.json", #"{"expiresAt": "2020-01-01T00:00:00Z"}"#)
    let begun = try temp.bundle.beginUpdate(now: Self.now)
    #expect(temp.hiddenNames == [UpdateMarker.name(forID: begun.id)])
    try FileManager.default.removeItem(at: temp.url)
    #expect(throws: DossierWriteError.self) { try temp.bundle.beginUpdate(now: Self.now) }
  }
}
