import Foundation

/// Access to the resources `Dossier` bundles from the pinned dossier-format
/// revision (`Resources/schemas/*.json`).
public enum DossierResources {
  /// The bundle holding `schemas/` and `PINNED.sha256` (flat at its root), copied verbatim from the pinned revision.
  public static var bundle: Bundle { Bundle.module }
}
