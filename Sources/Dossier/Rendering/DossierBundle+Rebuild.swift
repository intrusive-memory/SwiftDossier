import DossierCore
import Foundation

/// What ``DossierCore/DossierBundle/rebuild(cast:template:)`` did.
public struct RebuildResult: Sendable {
  /// The page built and stored. A rebuild always builds, so ``PreviewResult/hit`` is `false` and
  /// ``PreviewResult/html`` and ``PreviewResult/banner`` are there. A failure to store is in
  /// ``PreviewResult/storeError`` (PV-23).
  public let preview: PreviewResult
  /// Why the refresh refused, such as ``DossierWriteError/assetFilesMissing(_:)``, or `nil` when it
  /// succeeded. When it's set, the page was built from the manifest as it was (PV-13).
  public let refreshError: (any Error)?
}

extension DossierBundle {
  /// §11.1's *Rebuild*: brings the manifest up to the disk, then builds and stores the preview
  /// from what the bundle holds now, even when `.preview/<key>.html` is already there (PV-12).
  ///
  /// An update marker (§5.7) is held from the start of the refresh to the end. The steps:
  ///
  /// 1. ``refresh(cast:beforeCastWrite:)`` with `cast`. If it refuses, for example because an
  ///    asset's file is missing, the rebuild goes on with the manifest as it was and the refusal
  ///    is in ``RebuildResult/refreshError`` (PV-13).
  /// 2. The bundle is opened again from `manifest.json`, with its member of the `CAST.md` at
  ///    `cast` as ``openForPreview(at:cast:)`` finds it. With no `cast`, the member is the one
  ///    this bundle has.
  /// 3. The key is computed, and the page is built and stored with ``PreviewStore/store(_:)``.
  ///
  /// Afterwards this bundle is the one the page was built from.
  ///
  /// It is `nonisolated` and does file I/O and image work. Callers run it off the main actor
  /// (PV-15); from the main actor, `await` it rather than blocking on it.
  ///
  /// - Parameters:
  ///   - cast: The project's `CAST.md`, for the refresh's orphan adoption and for the member.
  ///   - template: The template the page is built with.
  /// - Throws: ``DossierCore/CharacterDescriptionError`` when `CHARACTER.md` is missing or isn't
  ///   UTF-8, since then there is nothing to show; what reading `manifest.json` for the key
  ///   throws; template and resource errors. A refresh refusal or a store failure doesn't throw.
  public nonisolated mutating func rebuild(cast: URL?, template: PageTemplate) async throws -> RebuildResult {
    try await rebuild(cast: cast, template: template, duringUpdate: nil)
  }

  /// ``rebuild(cast:template:)`` with ``DossierTemplate/current``.
  public nonisolated mutating func rebuild(cast: URL?) async throws -> RebuildResult {
    try await rebuild(cast: cast, template: try DossierTemplate.current)
  }

  /// ``rebuild(cast:template:)``, calling `duringUpdate` after the refresh and before the build
  /// and store, with the marker held. For tests.
  nonisolated mutating func rebuild(
    cast: URL?, template: PageTemplate, duringUpdate: ((DossierBundle) -> Void)? = nil
  ) async throws -> RebuildResult {
    try await withUpdate(label: "rebuild preview") { bundle in
      var refreshError: (any Error)?
      do {
        try bundle.refresh(cast: cast)
      } catch {
        refreshError = error
      }

      let member = cast == nil ? bundle.member : Self.member(pointingAt: bundle.url, in: cast)
      if let reopened = try? DossierBundle.open(at: bundle.url, member: member) {
        bundle = reopened
      }
      duringUpdate?(bundle)

      let parts = try bundle.previewParts(template: template)
      let preview = try bundle.buildAndStorePreview(parts, in: PreviewStore(bundle: bundle.url))
      return RebuildResult(preview: preview, refreshError: refreshError)
    }
  }
}
