import Foundation

/// Access to the resources `Dossier` bundles from the pinned dossier-format
/// revision (`Resources/schemas/*.json`, `Resources/template/`, `Resources/data/tokens.json`).
public enum DossierResources {
  /// The bundle holding `schemas/`, `template/`, `data/tokens.json` and `PINNED.sha256` (at its root), copied verbatim from the pinned revision.
  public static var bundle: Bundle { Bundle.module }
}
