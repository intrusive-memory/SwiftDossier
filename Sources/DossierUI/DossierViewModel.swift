import Dossier
import DossierCore
import Foundation
import Observation

/// The steps a viewer must not take on the main actor: building a preview and rebuilding it
/// (PV-15). ``DossierViewModel`` calls them off the main actor. A test can pass its own, to hold a
/// build open.
public protocol PreviewBuilding: Sendable {
  /// §11.1's *Showing a bundle*, step 4, after a miss: builds the preview and stores it.
  func build(_ bundle: DossierBundle) async throws -> PreviewResult

  /// §11.1's *Rebuild*, with the project's `CAST.md`.
  func rebuild(_ bundle: DossierBundle, cast: URL?) async throws -> RebuildResult
}

/// The library's own steps: ``DossierCore/DossierBundle/showPreview()`` and
/// ``DossierCore/DossierBundle/rebuild(cast:)``.
public struct DossierPreviewBuilder: PreviewBuilding {
  public init() {}

  /// ``DossierCore/DossierBundle/showPreview()``. If another writer stored the page since the
  /// miss, that's a hit, and nothing is built.
  @concurrent
  public func build(_ bundle: DossierBundle) async throws -> PreviewResult {
    try bundle.showPreview()
  }

  /// ``DossierCore/DossierBundle/rebuild(cast:)``.
  @concurrent
  public func rebuild(_ bundle: DossierBundle, cast: URL?) async throws -> RebuildResult {
    var bundle = bundle
    return try await bundle.rebuild(cast: cast)
  }
}

/// What a viewer of one bundle shows, following §11.1's *Showing a bundle* (PV-18).
///
/// It shows the bundle when it's made and again whenever ``bundleURL``, ``cast`` or
/// ``refreshToken`` changes. Reading the update markers, the key and the store happens on the main
/// actor, as they read only metadata and `manifest.json`. Building and rebuilding don't (PV-15).
@MainActor
@Observable
public final class DossierViewModel {
  /// What the viewer shows.
  public enum State: Sendable {
    /// The bundle is being updated (§5.7): the preview in the store, whatever its key, if there is
    /// one. No key is computed and nothing is built until no marker is active.
    case updating(storedPage: URL?)
    /// A build is running after a miss. A hit never shows this.
    case loading
    /// The preview: its stored file, or on a store failure its HTML from memory (PV-23).
    case page(PreviewResult)
    /// A rebuild is running. The page showing when it started, if there was one, stays visible.
    case rebuilding(PreviewResult?)
    /// Nothing can be shown.
    case failed(FailureReason)
  }

  /// Why nothing can be shown, in plain words.
  public enum FailureReason: Sendable, Equatable {
    /// The bundle has no `CHARACTER.md`, or it can't be read.
    case noCharacterDescription
    /// `CHARACTER.md` isn't UTF-8.
    case characterDescriptionNotUTF8
    /// There's no `.dossier` bundle at the URL.
    case notABundle
    /// Anything else, as the error describes itself.
    case other(String)

    /// One line for a person.
    public var message: String {
      switch self {
      case .noCharacterDescription: return "This character has no CHARACTER.md, so there is nothing to show."
      case .characterDescriptionNotUTF8: return "CHARACTER.md isn't UTF-8 text, so it can't be shown."
      case .notABundle: return "This isn't a character bundle."
      case .other(let detail): return detail
      }
    }

    init(_ error: any Error) {
      switch error {
      case let error as CharacterDescriptionError:
        switch error {
        case .unreadable: self = .noCharacterDescription
        case .notUTF8: self = .characterDescriptionNotUTF8
        default: self = .other(error.localizedDescription)
        }
      case let error as DossierError:
        switch error {
        case .manifestMissing, .manifestNotJSON, .manifestNotObject, .unknownVersion, .notABundle:
          self = .notABundle
        default:
          self = .other(error.localizedDescription)
        }
      default:
        self = .other(error.localizedDescription)
      }
    }
  }

  // MARK: Inputs

  /// The `.dossier` directory. Changing it cancels any build or rebuild in flight (PV-21).
  public var bundleURL: URL {
    didSet { if bundleURL != oldValue { inputsChanged() } }
  }

  /// The project's `CAST.md`, or `nil` (PV-3). Changing it cancels any build or rebuild in flight
  /// (PV-21).
  public var cast: URL? {
    didSet { if cast != oldValue { inputsChanged() } }
  }

  /// Any value. Changing it shows the bundle again, which computes the key and either hits or
  /// builds (PV-20). While a rebuild runs it does nothing: the rebuild shows the result.
  public var refreshToken: AnyHashable? {
    didSet { if refreshToken != oldValue { recheck() } }
  }

  // MARK: Output

  /// What the viewer shows.
  public private(set) var state: State {
    didSet { onStateChange?(state) }
  }

  /// Why the last rebuild's refresh refused, in plain words, or `nil` (PV-19). The page was
  /// built from the manifest as it was.
  public private(set) var refreshNote: String?

  /// Why the page showing couldn't be saved, in plain words, or `nil` (PV-23). The page is shown
  /// from memory.
  public private(set) var storeNote: String?

  /// Whether a rebuild is running.
  public var isRebuilding: Bool {
    if case .rebuilding = state { return true }
    return false
  }

  // MARK: Internals

  @ObservationIgnored private let builder: any PreviewBuilding
  /// Bumped by every show, rebuild and input change. A result from an older one is discarded.
  @ObservationIgnored private var generation = 0
  /// The build or rebuild in flight, or the wait for a marker to expire.
  @ObservationIgnored private(set) var inFlight: Task<Void, Never>?
  /// Called with every new state. For tests.
  @ObservationIgnored var onStateChange: ((State) -> Void)?

  /// A viewer of the bundle at `bundleURL`, which it shows at once: on a hit, `state` is already
  /// `.page`.
  ///
  /// - Parameters:
  ///   - bundleURL: The `.dossier` directory.
  ///   - cast: The project's `CAST.md`, or `nil`.
  ///   - refreshToken: Any value; see ``refreshToken``.
  ///   - builder: Builds and rebuilds off the main actor. Default: the library's.
  public init(
    bundleURL: URL, cast: URL? = nil, refreshToken: AnyHashable? = nil,
    builder: any PreviewBuilding = DossierPreviewBuilder()
  ) {
    self.bundleURL = bundleURL
    self.cast = cast
    self.refreshToken = refreshToken
    self.builder = builder
    let step = Self.firstStep(bundleURL: bundleURL, cast: cast)
    state = step.state
    take(step)
  }

  /// Rebuilds the preview: refreshes the manifest, then builds and stores the page even if it's
  /// stored already (PV-12, PV-19). The page showing stays visible meanwhile. A refresh refusal
  /// becomes ``refreshNote``. Does nothing while a rebuild runs.
  public func rebuild() {
    if isRebuilding { return }
    var showing: PreviewResult?
    if case .page(let result) = state { showing = result }
    cancelInFlight()
    refreshNote = nil

    let bundle: DossierBundle
    do {
      bundle = try DossierBundle.openForPreview(at: bundleURL, cast: cast)
    } catch {
      state = .failed(FailureReason(error))
      return
    }
    state = .rebuilding(showing)
    let generation = self.generation
    let builder = self.builder
    let cast = self.cast
    inFlight = Task { [weak self] in
      let outcome = await Self.rebuild(bundle, cast: cast, with: builder)
      guard let self, generation == self.generation else { return }
      self.inFlight = nil
      switch outcome {
      case .success(let result):
        self.refreshNote = result.refreshError.map(Self.refreshNote(for:))
        self.show(result.preview)
      case .failure(let error):
        self.state = .failed(FailureReason(error))
      }
    }
  }

  /// Hides ``refreshNote``.
  public func dismissRefreshNote() { refreshNote = nil }

  /// Hides ``storeNote``.
  public func dismissStoreNote() { storeNote = nil }

  /// Shows the bundle again, unless a rebuild is running (PV-20).
  func recheck() {
    if isRebuilding { return }
    showBundle()
  }

  // MARK: - Showing

  /// What §11.1's steps 1 to 3 give, before anything is built.
  private enum Step {
    case updating(storedPage: URL?, until: Date?)
    case shown(State)
    case build(DossierBundle)

    var state: State {
      switch self {
      case .updating(let page, _): return .updating(storedPage: page)
      case .shown(let state): return state
      case .build: return .loading
      }
    }
  }

  /// §11.1's *Showing a bundle*, steps 1 to 3. Only the markers, `manifest.json`, `CAST.md` and
  /// the store's metadata are read.
  private static func firstStep(bundleURL: URL, cast: URL?) -> Step {
    let status = UpdateStatus.read(bundle: bundleURL, at: Date())
    if status.isUpdating {
      return .updating(
        storedPage: PreviewStore(bundle: bundleURL).anyStoredPage(),
        until: status.activeMarkers.map(\.expiresAt).min())
    }
    do {
      let bundle = try DossierBundle.openForPreview(at: bundleURL, cast: cast)
      if let hit = try bundle.storedPreview() { return .shown(.page(hit)) }
      return .build(bundle)
    } catch {
      return .shown(.failed(FailureReason(error)))
    }
  }

  private func inputsChanged() {
    refreshNote = nil
    storeNote = nil
    showBundle()
  }

  private func showBundle() {
    cancelInFlight()
    let step = Self.firstStep(bundleURL: bundleURL, cast: cast)
    state = step.state
    take(step)
  }

  /// Starts what `step` leaves to do: a build, or a wait for the markers to expire. A marker
  /// can expire with nothing on disk changing (§12), so nothing else would show the bundle then.
  private func take(_ step: Step) {
    let generation = self.generation
    switch step {
    case .shown(let state):
      if case .page(let result) = state { storeNote = result.storeError.map(Self.storeNote(for:)) }
    case .updating(_, let until):
      guard let until else { return }
      inFlight = Task { [weak self] in
        // A moment past `expiresAt`, as the marker counts until then.
        let wait = max(0, until.timeIntervalSinceNow) + 0.5
        do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        guard let self, generation == self.generation else { return }
        self.inFlight = nil
        self.showBundle()
      }
    case .build(let bundle):
      let builder = self.builder
      inFlight = Task { [weak self] in
        let outcome = await Self.build(bundle, with: builder)
        guard let self, generation == self.generation else { return }
        self.inFlight = nil
        switch outcome {
        case .success(let result): self.show(result)
        case .failure(let error): self.state = .failed(FailureReason(error))
        }
      }
    }
  }

  private func show(_ result: PreviewResult) {
    storeNote = result.storeError.map(Self.storeNote(for:))
    state = .page(result)
  }

  /// Cancels what's in flight and makes any result it still delivers stale (PV-21).
  private func cancelInFlight() {
    generation += 1
    inFlight?.cancel()
    inFlight = nil
  }

  // MARK: - Off the main actor (PV-15)

  @concurrent
  private nonisolated static func build(
    _ bundle: DossierBundle, with builder: any PreviewBuilding
  ) async -> Result<PreviewResult, any Error> {
    do { return .success(try await builder.build(bundle)) } catch { return .failure(error) }
  }

  @concurrent
  private nonisolated static func rebuild(
    _ bundle: DossierBundle, cast: URL?, with builder: any PreviewBuilding
  ) async -> Result<RebuildResult, any Error> {
    do { return .success(try await builder.rebuild(bundle, cast: cast)) } catch { return .failure(error) }
  }

  // MARK: - Notes

  private static func refreshNote(for error: any Error) -> String {
    "The manifest couldn't be brought up to date, so this page shows the bundle as the manifest "
      + "last recorded it. \(error.localizedDescription)"
  }

  private static func storeNote(for error: any Error) -> String {
    "This preview couldn't be saved in the bundle, so it's shown from memory. \(error.localizedDescription)"
  }
}
