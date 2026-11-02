import Foundation

/// Access to the resources `DossierCore` bundles from the pinned dossier-format
/// revision (`Resources/tiers.json`, `Resources/review.json`, `Resources/fields.json`).
public enum DossierCoreResources {
  /// The bundle holding `tiers.json`, `review.json`, `fields.json` and `PINNED.sha256` (flat at its root), copied verbatim from the pinned revision.
  public static var bundle: Bundle { Bundle.module }
}
