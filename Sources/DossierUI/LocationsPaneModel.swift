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

  /// The location bundle selected in the host, or `nil` for the whole project (LV-6, LV-7).
  ///
  /// Setting it to another bundle an entry points at, or to `nil`, while a page is showing moves
  /// ``section`` and recomputes ``findings``; the page isn't built or looked up again (LV-6). Any
  /// other change shows the page again, as ``show()`` does.
  public var selectedBundleURL: URL? {
    didSet { if selectedBundleURL != oldValue { selectionChanged() } }
  }

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

  /// What a ``PreviewWebView`` shows: ``pageFile`` as a stored page with read access to the store
  /// directory `<index directory>/.locations-page/` only, or ``pageHTML`` from memory. `nil` when
  /// there is nothing to show.
  public var previewContent: PreviewContent? {
    if let pageFile {
      let readAccess = storeDirectory ?? pageFile.deletingLastPathComponent()
      return .storedPage(page: pageFile, readAccess: readAccess)
    }
    return pageHTML.map(PreviewContent.html)
  }

  /// The store directory of the index the page showing came from, `<index directory>/.locations-page/`.
  private var storeDirectory: URL?

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

  /// The `id` of the selected location's section on the page (§16.7), to scroll to, or `nil` for
  /// the top of the page: in project mode, and when nothing is shown (LV-6).
  public private(set) var section: String?

  /// Whether the selected bundle is one no entry of the index points at, or is in a project with
  /// no locations index (LV-7). No page is built or shown for it.
  public private(set) var isOrphan = false

  /// The validator's findings for what is selected (LV-4): in project mode, the project's findings
  /// about its locations index and the bundles its entries point at; in bundle mode, the bundle's
  /// own findings and the project's findings inside the bundle (an orphan's `W-ORPHAN`). When the
  /// index or `PROJECT.md` can't be read, its `E-CAST` finding, in place of the page.
  public private(set) var findings: [Finding] = []

  // MARK: Internals

  /// The index the page showing was shown from, for a selection change that keeps the page.
  @ObservationIgnored private var shown: Shown?
  /// Bumped by every findings update. Findings from an older one are discarded.
  @ObservationIgnored private var findingsGeneration = 0
  /// How many times the page was built or rebuilt off the main actor. For tests.
  @ObservationIgnored private(set) var buildCount = 0
  /// How many times the store was looked up for the current key. For tests.
  @ObservationIgnored private(set) var lookupCount = 0

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
    // The backing storage, not the properties: their `didSet` would start a show, and a pane shows
    // nothing until ``show()``.
    _selectedBundleURL = selectedBundleURL
    _refreshToken = refreshToken
  }

  // MARK: Showing the page (§16.6)

  /// §16.6's *Showing the page*. While a bundle an entry points at is being updated, shows the
  /// store's page, whatever its key, and builds nothing (step 1). Otherwise shows the stored page
  /// for the current key, or builds it off the main actor, stores it and shows it (steps 2 to 4).
  ///
  /// A selected bundle no entry points at is an orphan (LV-7): nothing is looked up or built. When
  /// `PROJECT.md` or the index can't be read, no page is shown and ``findings`` holds its `E-CAST`
  /// (LV-4).
  public func show() async {
    generation += 1
    let generation = self.generation
    shown = nil
    let project = DossierProject(directory: projectDirectory)
    let selected = selectedBundleURL.map(Self.key(of:))

    let index: LocationsIndex
    switch project.discoverLocations() {
    case .index(let found):
      index = found
    case .none:
      if let selected { return await showOrphan(selected) }
      fail(message: "This project has no locations index.")
      return await updateFindings(.none)
    case .indexMissing(let path):
      if let selected { return await showOrphan(selected) }
      fail(message: "The locations index \(path) isn't there.")
      return await updateFindings(.paths([path]))
    case .projectUnreadable:
      clearPage()
      return await updateFindings(.cast([DossierProject.projectFileName]))
    case .indexUnreadable(let url, _):
      clearPage()
      return await updateFindings(.cast([relativePath(of: url)]))
    }

    storeDirectory = LocationsPageStore(index: index).directory
    let sections = Self.sections(of: index)
    if let selected, sections[selected] == nil {
      return await showOrphan(selected)
    }
    isOrphan = false
    section = selected.flatMap { sections[$0] }
    let scope = LocationsScope(index: index, model: self)
    let current = Shown(sections: sections, scope: scope)

    if index.isUpdatingABundle() {
      isBuilding = false
      result = nil
      pageHTML = nil
      storeNote = nil
      failure = nil
      pageFile = LocationsPageStore(index: index).anyStoredPage()
      shown = current
      return await updateFindings(findingsRequest(scope: scope))
    }

    // A hit reads only metadata, so it's taken here, and the pane never shows progress for one.
    do {
      lookupCount += 1
      if let hit = try index.storedLocationsPage(title: project.title) {
        take(hit)
        shown = current
        return await updateFindings(findingsRequest(scope: scope))
      }
    } catch {
      fail(error)
      return await updateFindings(findingsRequest(scope: scope))
    }

    isBuilding = true
    buildCount += 1
    let title = project.title
    let outcome = await Self.run { try index.showLocationsPage(title: title) }
    guard generation == self.generation else { return }
    isBuilding = false
    switch outcome {
    case .success(let result):
      take(result)
      shown = current
    case .failure(let error):
      fail(error)
    }
    await updateFindings(findingsRequest(scope: scope))
  }

  /// §16.6's *Rebuild* (LV-3): builds the page off the main actor and stores it, even when the
  /// stored page for the current key exists.
  public func rebuild() async {
    generation += 1
    let generation = self.generation
    guard let (index, title) = openIndex() else { return }
    storeDirectory = LocationsPageStore(index: index).directory
    isBuilding = true
    buildCount += 1
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

  // MARK: Selection (LV-6, LV-7)

  /// A new ``selectedBundleURL``. With a page showing and the new selection on it (another entry's
  /// bundle, or none), only ``section`` and ``findings`` change: nothing is looked up or built
  /// (LV-6). Otherwise the page is shown again.
  private func selectionChanged() {
    let selected = selectedBundleURL.map(Self.key(of:))
    if let shown, pageFile != nil || pageHTML != nil,
      selected.map({ shown.sections[$0] != nil }) ?? true
    {
      section = selected.flatMap { shown.sections[$0] }
      let request = findingsRequest(scope: shown.scope)
      pending = Task { [weak self] in await self?.updateFindings(request) }
    } else {
      pending = Task { [weak self] in await self?.show() }
    }
  }

  /// LV-7: a bundle no entry points at. No page; its findings only.
  private func showOrphan(_ selected: String) async {
    clearPage()
    isOrphan = true
    await updateFindings(.bundle(path: selected, relative: relativePath(of: URL(fileURLWithPath: selected))))
  }

  /// No page, no failure, and nothing selected on a page.
  private func clearPage() {
    isBuilding = false
    result = nil
    pageFile = nil
    pageHTML = nil
    storeNote = nil
    failure = nil
    section = nil
    isOrphan = false
  }

  /// Each entry's bundle, by its standardized path, to its section's `id` (§16.7). An entry with no
  /// `manifest:`, or whose bundle doesn't open, points at nothing selectable.
  private static func sections(of index: LocationsIndex) -> [String: String] {
    var sections: [String: String] = [:]
    for entry in index.entries {
      guard let bundle = try? index.openBundle(for: entry) else { continue }
      sections[key(of: bundle.url)] = LocationsIndex.sectionID(forLocation: entry.location)
    }
    return sections
  }

  /// A directory's standardized path, with no trailing `/`, to compare bundle URLs by.
  private static func key(of url: URL) -> String { url.standardizedFileURL.path }

  /// A path relative to the project directory, as the validator writes it, or the full path when
  /// it's outside.
  fileprivate func relativePath(of url: URL) -> String {
    let base = Self.key(of: projectDirectory)
    let path = Self.key(of: url)
    guard path.hasPrefix(base + "/") else { return path }
    return String(path.dropFirst(base.count + 1))
  }

  // MARK: Findings (LV-4)

  /// What the findings are for the selection: the project's locations, or one bundle.
  private func findingsRequest(scope: LocationsScope) -> FindingsRequest {
    guard let selectedBundleURL else { return .project(scope) }
    return .bundle(path: Self.key(of: selectedBundleURL), relative: relativePath(of: selectedBundleURL))
  }

  /// Validates off the main actor and sets ``findings``, unless a later update has started.
  private func updateFindings(_ request: FindingsRequest) async {
    findingsGeneration += 1
    let generation = findingsGeneration
    let directory = projectDirectory
    let found = await Self.findings(for: request, in: directory)
    guard generation == findingsGeneration else { return }
    findings = found
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
    clearPage()
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

  @concurrent
  private nonisolated static func findings(for request: FindingsRequest, in directory: URL) async -> [Finding] {
    let template = try? DossierTemplate.current
    func project() -> [Finding] {
      (try? DossierBundle.validate(project: directory, template: template))?.findings ?? []
    }
    switch request {
    case .none:
      return []
    case .paths(let paths):
      return project().filter { $0.path.map(paths.contains) ?? false }
    case .cast(let paths):
      return project().filter { $0.code == .cast && ($0.path.map(paths.contains) ?? false) }
    case .project(let scope):
      return project().filter(scope.contains)
    case .bundle(let path, let relative):
      let url = URL(fileURLWithPath: path, isDirectory: true)
      let own: [Finding]
      if let bundle = try? DossierBundle.open(at: url) {
        own = (try? bundle.validate(template: template))?.findings ?? []
      } else {
        own = (try? DossierBundle.validate(at: url, template: template))?.findings ?? []
      }
      // The project's findings inside the bundle, less those the bundle's own already give.
      let given = Set(own.map { Seen(code: $0.code, path: $0.path) })
      let inside = project().filter { finding in
        guard let path = finding.path, path == relative || path.hasPrefix(relative + "/") else { return false }
        let local = path == relative ? nil : String(path.dropFirst(relative.count + 1))
        return !given.contains(Seen(code: finding.code, path: local))
      }
      return own + inside
    }
  }
}

/// What ``LocationsPaneModel/findings`` is computed from.
private enum FindingsRequest: Sendable {
  /// Nothing to report.
  case none
  /// The project's findings with these paths.
  case paths(Set<String>)
  /// The project's `E-CAST` findings with these paths (LV-4).
  case cast(Set<String>)
  /// The project's findings about its locations (project mode).
  case project(LocationsScope)
  /// A bundle's own findings and the project's inside it (bundle mode). `path` is the bundle's
  /// standardized path; `relative` is it relative to the project directory.
  case bundle(path: String, relative: String)
}

/// A finding's identity, for leaving out the project's copy of a bundle's own finding.
private struct Seen: Hashable {
  let code: Finding.Code
  let path: String?
}

/// The page showing and what selecting on it needs.
private struct Shown {
  /// Each entry's bundle, by standardized path, to its section's `id`.
  let sections: [String: String]
  let scope: LocationsScope
}

/// Which of a project's findings are about its locations (§16.2): `PROJECT.md`, the index, the
/// entries' pointers and bundles, and orphans where locations are listed. Paths are relative to the
/// project directory, as the validator writes them. A finding with no path is about locations only
/// when it's an entry's invalid `location` (`E-NAME`); the others can't be told apart from a
/// character bundle's.
private struct LocationsScope: Sendable {
  let files: Set<String>
  let bundles: [String]
  let orphanDirectories: Set<String>

  @MainActor
  init(index: LocationsIndex, model: LocationsPaneModel) {
    let indexDirectory = model.relativePath(of: index.directory)
    func joined(_ path: String) -> String { indexDirectory.isEmpty ? path : indexDirectory + "/" + path }
    var files: Set<String> = [DossierProject.projectFileName, model.relativePath(of: index.url)]
    var bundles: [String] = []
    var orphanDirectories: Set<String> = [joined("locations")]
    for entry in index.entries {
      guard let pointer = entry.pointer, let manifest = index.manifestURL(of: entry) else { continue }
      files.insert(joined(pointer.raw))
      let bundle = manifest.deletingLastPathComponent()
      bundles.append(model.relativePath(of: bundle))
      orphanDirectories.insert(model.relativePath(of: bundle.deletingLastPathComponent()))
    }
    self.files = files
    self.bundles = bundles
    self.orphanDirectories = orphanDirectories
  }

  func contains(_ finding: Finding) -> Bool {
    guard let path = finding.path else { return finding.code == .name }
    if files.contains(path) { return true }
    if bundles.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
    if finding.code == .orphan {
      let parent = path.split(separator: "/").dropLast().joined(separator: "/")
      return orphanDirectories.contains(parent)
    }
    return false
  }
}
