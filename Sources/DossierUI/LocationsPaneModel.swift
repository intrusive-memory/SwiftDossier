import Dossier
import DossierCore
import Foundation
import Observation

/// What a locations pane shows: a project's LOCATIONS page, following §16.6's *Showing the page*
/// (LV-2).
///
/// ``show()`` reads `PROJECT.md`, the locations index, the update markers, the key and the store
/// on the main actor, as they read only metadata, the index and the entries' `manifest.json`.
/// Building the page, which can take seconds on a large project, never runs on the main actor;
/// ``isBuilding`` is `true` while it runs (requirements § Risks → Page size).
///
/// The pane shows the page again when ``refreshToken`` changes (LV-11). Nothing polls.
@MainActor
@Observable
public final class LocationsPaneModel {
  // MARK: Inputs

  /// The project directory: the one holding `PROJECT.md`.
  public let projectDirectory: URL

  /// The location bundle selected in the host, or `nil`.
  public var selectedBundleURL: URL?

  /// Any value. Changing it shows the page again, which computes the key and either hits or
  /// builds (LV-11). A change to `LOCATIONS.md` or an entry's `manifest.json` changes the key.
  public var refreshToken: AnyHashable? {
    didSet { if refreshToken != oldValue { pending = Task { [weak self] in await self?.show() } } }
  }

  // MARK: Output

  /// The page to show from disk: the stored page for the current key, or, while a bundle an entry
  /// points at is being updated, any stored page. `nil` when the page is shown from ``pageHTML``
  /// or there is nothing to show.
  public private(set) var pageFile: URL?

  /// The page built this time and not stored (§16.6). The view shows it from memory, with
  /// ``storeNote``. `nil` whenever ``pageFile`` is set.
  public private(set) var pageHTML: String?

  /// Whether a build or rebuild is running off the main actor. The page showing when it started,
  /// if there was one, stays.
  public private(set) var isBuilding = false

  /// Why the page showing couldn't be saved, in plain words, or `nil`. The page is shown from
  /// memory.
  public private(set) var storeNote: String?

  /// Why nothing can be shown, in plain words, or `nil`.
  public private(set) var failure: String?

  /// The last result of showing or rebuilding the page, or `nil` when there is none: while a
  /// bundle is being updated, or after a failure.
  public private(set) var result: LocationsPageResult?

  // MARK: Internals

  /// Bumped by every show and rebuild. A result from an older one is discarded.
  @ObservationIgnored private var generation = 0
  /// The show a ``refreshToken`` change started, or `nil`. For tests.
  @ObservationIgnored private(set) var pending: Task<Void, Never>?

  /// A pane for the project at `projectDirectory`. Nothing is read until ``show()``, which the host
  /// calls when the pane appears.
  ///
  /// - Parameters:
  ///   - projectDirectory: The directory holding `PROJECT.md`.
  ///   - selectedBundleURL: The location bundle selected in the host, or `nil`.
  ///   - refreshToken: Any value; see ``refreshToken``.
  public init(projectDirectory: URL, selectedBundleURL: URL? = nil, refreshToken: AnyHashable? = nil) {
    self.projectDirectory = projectDirectory
    self.selectedBundleURL = selectedBundleURL
    // The backing storage, not the property: the property's `didSet` would start a show, and a pane
    // shows nothing until ``show()``.
    _refreshToken = refreshToken
  }

  // MARK: Showing the page (§16.6)

  /// §16.6's *Showing the page*. While a bundle an entry points at is being updated, shows the
  /// store's page, whatever its key, and builds nothing (step 1). Otherwise shows the stored page
  /// for the current key, or builds it off the main actor, stores it and shows it (steps 2 to 4).
  public func show() async {
    generation += 1
    let generation = self.generation
    guard let (index, title) = openIndex() else { return }

    if index.isUpdatingABundle() {
      isBuilding = false
      result = nil
      pageHTML = nil
      storeNote = nil
      failure = nil
      pageFile = LocationsPageStore(index: index).anyStoredPage()
      return
    }

    // A hit reads only metadata, so it's taken here, and the pane never shows progress for one.
    do {
      if let hit = try index.storedLocationsPage(title: title) {
        take(hit)
        return
      }
    } catch {
      fail(error)
      return
    }

    isBuilding = true
    let outcome = await Self.run { try index.showLocationsPage(title: title) }
    guard generation == self.generation else { return }
    isBuilding = false
    switch outcome {
    case .success(let result): take(result)
    case .failure(let error): fail(error)
    }
  }

  /// §16.6's *Rebuild* (LV-3): builds the page off the main actor and stores it, even when the
  /// stored page for the current key exists.
  public func rebuild() async {
    generation += 1
    let generation = self.generation
    guard let (index, title) = openIndex() else { return }
    isBuilding = true
    let outcome = await Self.run { try index.rebuildLocationsPage(title: title) }
    guard generation == self.generation else { return }
    isBuilding = false
    switch outcome {
    case .success(let result): take(result)
    case .failure(let error): fail(error)
    }
  }

  /// The project's locations index and title, or `nil` with ``failure`` set.
  private func openIndex() -> (LocationsIndex, String?)? {
    let project = DossierProject(directory: projectDirectory)
    switch project.discoverLocations() {
    case .index(let index):
      return (index, project.title)
    case .none:
      fail(message: "This project has no locations index.")
    case .indexMissing(let path):
      fail(message: "The locations index \(path) isn't there.")
    case .projectUnreadable(let error), .indexUnreadable(_, let error):
      fail(message: error.localizedDescription)
    }
    return nil
  }

  private func take(_ result: LocationsPageResult) {
    isBuilding = false
    self.result = result
    failure = nil
    if result.storeError != nil, let html = result.html {
      pageFile = nil
      pageHTML = html
      storeNote = result.storeError.map(Self.storeNote(for:))
    } else {
      pageFile = result.pageURL
      pageHTML = nil
      storeNote = nil
    }
  }

  private func fail(_ error: any Error) { fail(message: error.localizedDescription) }

  private func fail(message: String) {
    isBuilding = false
    result = nil
    pageFile = nil
    pageHTML = nil
    storeNote = nil
    failure = message
  }

  private static func storeNote(for error: any Error) -> String {
    "This page couldn't be saved in the project, so it's shown from memory. \(error.localizedDescription)"
  }

  // MARK: - Off the main actor

  @concurrent
  private nonisolated static func run(
    _ step: @escaping @Sendable () throws -> LocationsPageResult
  ) async -> Result<LocationsPageResult, any Error> {
    do { return .success(try step()) } catch { return .failure(error) }
  }
}
