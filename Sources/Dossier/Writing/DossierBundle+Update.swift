import DossierCore
import Foundation
import Synchronization

/// A marker this writer made: what an update spanning separate calls needs to hold on to (§5.7).
public struct UpdateMarkerHandle: Sendable, Equatable {
  /// The marker's `<id>`, which ``DossierBundle/renewUpdate(id:lifetime:now:)`` and
  /// ``DossierBundle/endUpdate(id:)`` take.
  public let id: String
  /// When it stops counting, unless it's renewed.
  public let expiresAt: Date
}

extension DossierBundle {
  /// How far ahead ``beginUpdate(label:writer:lifetime:now:)`` sets `expiresAt` unless told otherwise.
  public static let defaultUpdateLifetime: TimeInterval = 1800

  /// Holds an update marker for the length of a block (§5.7, SD-14).
  ///
  /// The marker appears before the block and goes after it, whether it returned or threw, so every
  /// manifest replacement in the block comes first. It's renewed in the background, however long the
  /// block runs. Mutations in the block, and a nested `withUpdate`, hold no marker of their own, so
  /// the sequence shows as one update. "In the block" means this task and the tasks it starts;
  /// `Task.detached` and another thread aren't, and hold their own.
  ///
  /// A marker is a signal, not a lock: another writer's doesn't stop this one, and a failure to write
  /// this one doesn't stop the block. A marker of another writer's that has expired is removed.
  ///
  /// - Parameters:
  ///   - label: One line for a person: what the update is doing.
  ///   - body: The work, given this bundle to change.
  /// - Returns: What `body` returns.
  @discardableResult
  public mutating func withUpdate<Result>(
    label: String? = nil, _ body: (inout DossierBundle) throws -> Result
  ) rethrows -> Result {
    try UpdateHolding.holding(bundle: url, label: label) { try body(&self) }
  }

  /// `withUpdate(label:_:)` for a block that suspends, such as a render.
  ///
  /// - Parameters:
  ///   - label: One line for a person: what the update is doing.
  ///   - isolation: The caller's actor, on which `body` runs.
  ///   - body: The work, given this bundle to change.
  /// - Returns: What `body` returns.
  @discardableResult
  public mutating func withUpdate<Result>(
    label: String? = nil, isolation: isolated (any Actor)? = #isolation,
    _ body: (inout DossierBundle) async throws -> Result
  ) async rethrows -> Result {
    try await UpdateHolding.holding(bundle: url, label: label, isolation: isolation) { try await body(&self) }
  }

  /// Writes a marker for an update spanning separate calls, or processes. Nothing renews it but
  /// ``renewUpdate(id:lifetime:now:)``, so it stops counting at `expiresAt` if the writer goes away.
  /// A block is better where there is one: `withUpdate(label:_:)`.
  ///
  /// - Parameters:
  ///   - label: One line for a person: what the update is doing.
  ///   - writer: The name of the tool making the update. Default: this library's.
  ///   - lifetime: Seconds ahead for `expiresAt`: above 0, at most 3600.
  ///   - now: The time it starts.
  /// - Returns: The marker, whose id the other calls take.
  /// - Throws: ``DossierWriteError``. An explicit marker is the point of this call, so unlike a
  ///   block's, a failure to write it is reported.
  @discardableResult
  public func beginUpdate(
    label: String? = nil, writer: String? = nil,
    lifetime: TimeInterval = DossierBundle.defaultUpdateLifetime, now: Date = Date()
  ) throws -> UpdateMarkerHandle {
    try UpdateMarkerStore.check(lifetime: lifetime)
    UpdateMarkerStore.removeExpired(in: url, at: now)
    let id = UUID().uuidString.lowercased()
    let expiresAt = now.addingTimeInterval(lifetime)
    let object = UpdateMarkerStore.object(
      writer: writer ?? UpdateMarkerStore.writerName, startedAt: now, expiresAt: expiresAt, label: label)
    try UpdateMarkerStore.write(object, id: id, in: url)
    return UpdateMarkerHandle(id: id, expiresAt: UpdateMarkerStore.whole(expiresAt))
  }

  /// Replaces a marker with a later `expiresAt`, keeping everything else in it (§5.7).
  ///
  /// - Parameters:
  ///   - id: The marker's id.
  ///   - lifetime: Seconds ahead for `expiresAt`: above 0, at most 3600.
  ///   - now: The time it's renewed.
  /// - Throws: ``DossierWriteError``. A marker that's gone isn't made again: after a sweep of
  ///   expired markers, for one, the update has to say so with a new ``beginUpdate(label:writer:lifetime:now:)``.
  @discardableResult
  public func renewUpdate(
    id: String, lifetime: TimeInterval = DossierBundle.defaultUpdateLifetime, now: Date = Date()
  ) throws -> UpdateMarkerHandle {
    try UpdateMarkerStore.check(lifetime: lifetime)
    let file = try UpdateMarkerStore.file(id: id, in: url)
    guard let data = try? Data(contentsOf: file), var object = UpdateMarker.object(in: data) else {
      throw DossierWriteError.updateMarkerUnreadable(id)
    }
    let expiresAt = now.addingTimeInterval(lifetime)
    object["expiresAt"] = .string(Timestamp.string(from: expiresAt))
    try UpdateMarkerStore.write(object, id: id, in: url)
    return UpdateMarkerHandle(id: id, expiresAt: UpdateMarkerStore.whole(expiresAt))
  }

  /// Removes the marker this update holds, after its last manifest replacement (§5.7). The id is
  /// what says it's this writer's: another writer's marker is theirs to end until it has expired.
  ///
  /// - Parameter id: The marker's id.
  /// - Throws: ``DossierWriteError``.
  public func endUpdate(id: String) throws {
    let file = try UpdateMarkerStore.file(id: id, in: url)
    guard unlink(file.path) == 0 else {
      throw DossierWriteError.updateMarkerFailed(String(cString: strerror(errno)))
    }
  }
}

/// Writing what §5.7 calls a marker.
///
/// Every marker written validates against `schemas/update-marker.schema.json`, as every manifest
/// does against its own (SD-3).
enum UpdateMarkerStore {
  /// The `writer` of a marker from the library.
  static let writerName = ManifestWriter.generatorName

  static func check(lifetime: TimeInterval) throws {
    guard lifetime > 0, lifetime <= UpdateMarker.maximumLifetime else {
      throw DossierWriteError.updateLifetimeNotAllowed(lifetime)
    }
  }

  /// The instant a timestamp written for `date` holds: §1 has whole seconds, rounded down, so
  /// `expiresAt` is never further ahead than it was asked to be.
  static func whole(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
  }

  /// §5.7's content. `label` is "one line", and the schema has no empty one.
  static func object(writer: String, startedAt: Date, expiresAt: Date, label: String?) -> JSONObject {
    func line(_ text: String?) -> String? {
      let joined = text?.split(whereSeparator: \.isNewline).joined(separator: " ")
      return joined?.isEmpty == false ? joined : nil
    }
    var object = JSONObject()
    object["writer"] = .string(line(writer) ?? writerName)
    object["startedAt"] = .string(Timestamp.string(from: startedAt))
    object["expiresAt"] = .string(Timestamp.string(from: expiresAt))
    if let label = line(label) { object["label"] = .string(label) }
    return object
  }

  /// A temporary name that isn't a marker's, whatever the id, so no reader sees a partial file.
  static func temporaryName(forID id: String) -> String {
    "\(UpdateMarker.name(forID: id)).\(UUID().uuidString).tmp"
  }

  /// Writes a temporary file and renames it into place (§5.7). It isn't synced: a marker a crash
  /// has emptied is unreadable, so not active, which is what a crash should leave.
  static func write(_ object: JSONObject, id: String, in bundle: URL) throws {
    try checkSchema(object)
    let temporary = bundle.appendingPathComponent(temporaryName(forID: id))
    let destination = bundle.appendingPathComponent(UpdateMarker.name(forID: id))
    defer { unlink(temporary.path) }
    do {
      try JSONValue.object(object).prettyEncoded().write(to: temporary)
    } catch {
      throw DossierWriteError.updateMarkerFailed(error.localizedDescription)
    }
    guard rename(temporary.path, destination.path) == 0 else {
      throw DossierWriteError.updateMarkerFailed(String(cString: strerror(errno)))
    }
  }

  /// A marker this package writes has to pass §5.7's schema, whoever chose its contents.
  private static func checkSchema(_ object: JSONObject) throws {
    let violations: [SchemaViolation]
    do {
      violations = try SchemaEvaluator.bundledSchemas.get()
        .validate(.object(object), against: "update-marker.schema.json")
    } catch {
      throw DossierWriteError.updateMarkerFailed(error.localizedDescription)
    }
    guard violations.isEmpty else {
      throw DossierWriteError.updateMarkerFailed(
        violations.map { "\($0.path.isEmpty ? "/" : $0.path): \($0.message)" }.joined(separator: "; "))
    }
  }

  /// The marker file with this id. The id is checked first, so it can't name a path elsewhere.
  static func file(id: String, in bundle: URL) throws -> URL {
    guard UpdateMarker.isValidID(id) else { throw DossierWriteError.updateIDNotAllowed(id) }
    guard let file = UpdateMarker.files(inBundle: bundle).first(where: { $0.id.utf8.elementsEqual(id.utf8) }) else {
      throw DossierWriteError.updateMarkerNotFound(id)
    }
    return file.url
  }

  /// §5.7: a writer MAY remove another writer's marker only when it has expired. So nothing else
  /// that isn't active goes: not a marker too far ahead, and not one that can't be read.
  ///
  /// SPEC-GAP: §5.7: a writer that was late renewing can lose its marker here, as a read and an
  /// unlink aren't one step. Renewal writes it again, so a held marker comes back by the next one.
  static func removeExpired(in bundle: URL, at now: Date) {
    for file in UpdateMarker.files(inBundle: bundle) {
      guard let data = try? Data(contentsOf: file.url), let object = UpdateMarker.object(in: data),
        let expiresAt = UpdateMarker.expiresAt(of: object), expiresAt <= now
      else { continue }
      unlink(file.url.path)
    }
  }
}

/// What a held marker takes from its surroundings. A test sets its own, in the task-local.
struct UpdateEnvironment: Sendable {
  /// What a hold does, in order, for a test to watch.
  enum Event: Sendable, Equatable {
    case wrote(id: String)
    case writeFailed(id: String)
    case willRenew(id: String)
    case renewed(id: String)
    case willEnd(id: String)
    case willRemove(id: String)
    case removed(id: String)
  }

  var now: @Sendable () -> Date = { Date() }
  /// Seconds ahead for `expiresAt`. A crashed writer's marker counts for this long at most, and a
  /// reader whose clock is behind this one's reads a marker at §5.7's limit as too far ahead.
  var lifetime: TimeInterval = 900
  /// Seconds between renewals: a third of the lifetime, so one that fails has a second chance.
  var renewalInterval: TimeInterval = 300
  var makeID: @Sendable () -> String = { UUID().uuidString.lowercased() }
  /// Starts calling `tick` every `interval` seconds, and returns how to stop.
  var startRenewal: @Sendable (_ interval: TimeInterval, _ tick: @escaping @Sendable () -> Void) -> @Sendable () -> Void = {
    interval, tick in
    // Its own serial queue, never `.global()`: a global queue's work waits for a free core, so a
    // render on every core at a higher QoS would stop renewals, and the marker would expire
    // mid-update. A serial queue gets a thread regardless. A renewal is rare and brief, and being
    // late is the one thing it can't be, hence the QoS.
    let queue = DispatchQueue(label: "SwiftDossier.update-renewal", qos: .userInitiated)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    // The wall clock, so a renewal that a sleeping machine missed happens on waking.
    timer.schedule(wallDeadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
    timer.setEventHandler(handler: tick)
    timer.resume()
    return { timer.cancel() }
  }
  var observe: @Sendable (Event) -> Void = { _ in }
}

/// One marker, held from `init` to ``end()``.
final class UpdateHold: Sendable {
  private struct State {
    var hasEnded = false
    var stopRenewal: (@Sendable () -> Void)?
  }

  private let bundle: URL
  private let id: String
  private let writer = UpdateMarkerStore.writerName
  private let startedAt: Date
  private let label: String?
  private let environment: UpdateEnvironment
  /// Held across a renewal's write, which is what makes ``end()`` deterministic: once `hasEnded`
  /// is set, a renewal has either finished or won't write, so none can bring the marker back.
  private let state = Mutex(State())

  init(bundle: URL, label: String?, environment: UpdateEnvironment) {
    self.bundle = bundle
    self.label = label
    self.environment = environment
    id = environment.makeID()
    startedAt = environment.now()

    UpdateMarkerStore.removeExpired(in: bundle, at: startedAt)
    write(now: startedAt, success: .wrote(id: id))
    let stop = environment.startRenewal(environment.renewalInterval) { [weak self] in self?.renew() }
    state.withLock { $0.stopRenewal = stop }
  }

  /// Whether the marker is still held. A task can outlive the block that started it.
  var isLive: Bool { state.withLock { !$0.hasEnded } }

  /// A failure is left for the next renewal: a marker never blocks a write.
  private func write(now: Date, success: UpdateEnvironment.Event) {
    let object = UpdateMarkerStore.object(
      writer: writer, startedAt: startedAt, expiresAt: now.addingTimeInterval(environment.lifetime), label: label)
    do {
      try UpdateMarkerStore.write(object, id: id, in: bundle)
      environment.observe(success)
    } catch {
      environment.observe(.writeFailed(id: id))
    }
  }

  private func renew() {
    state.withLock { state in
      guard !state.hasEnded else { return }
      environment.observe(.willRenew(id: id))
      write(now: environment.now(), success: .renewed(id: id))
    }
  }

  /// Stops renewal, then removes the marker. When this returns the marker is gone for good.
  func end() {
    environment.observe(.willEnd(id: id))
    let stop = state.withLock { state in
      state.hasEnded = true
      return state.stopRenewal
    }
    stop?()
    environment.observe(.willRemove(id: id))
    // `unlink`, as what's at the name is only sure to be the marker if it was written, and
    // a directory there, say, isn't this writer's to remove.
    unlink(bundle.appendingPathComponent(UpdateMarker.name(forID: id)).path)
    environment.observe(.removed(id: id))
  }
}

/// Whether this task's caller already holds a marker for a bundle, by the bundle's real path.
enum UpdateHolding {
  @TaskLocal static var environment = UpdateEnvironment()
  @TaskLocal static var holds: [String: UpdateHold] = [:]

  private static func key(_ bundle: URL) -> String {
    bundle.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
  }

  /// Runs `body` holding a marker for `bundle`, unless the caller already does.
  static func holding<Result>(bundle: URL, label: String?, _ body: () throws -> Result) rethrows -> Result {
    let key = key(bundle)
    if holds[key]?.isLive == true { return try body() }
    let hold = UpdateHold(bundle: bundle, label: label, environment: environment)
    defer { hold.end() }
    var nested = holds
    nested[key] = hold
    return try $holds.withValue(nested, operation: body)
  }

  /// Runs `body` holding a marker for `bundle`, unless the caller already does.
  static func holding<Result>(
    bundle: URL, label: String?, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> Result
  ) async rethrows -> Result {
    let key = key(bundle)
    if holds[key]?.isLive == true { return try await body() }
    let hold = UpdateHold(bundle: bundle, label: label, environment: environment)
    defer { hold.end() }
    var nested = holds
    nested[key] = hold
    return try await $holds.withValue(nested, operation: body, isolation: isolation)
  }
}
