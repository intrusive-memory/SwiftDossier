import Foundation
import SwiftReparto

/// A bundle measured against one tier (§8.3).
public struct CompletenessReport: Sendable, Equatable {
  /// What a tier asks of a row.
  public enum Level: String, Sendable, Equatable {
    /// The row must be satisfied for the bundle to be complete.
    case required
    /// The row is worth having.
    case recommended
    /// The row doesn't apply.
    case none
  }

  /// One row of `tiers.json`, with its state.
  public struct Row: Sendable, Equatable {
    /// The row's ID.
    public let id: String
    /// The row's display text.
    public let label: String
    /// What the tier asks of it.
    public let level: Level
    /// Whether the bundle satisfies it.
    public let isSatisfied: Bool
  }

  /// The tier measured against.
  public let tier: CastRole
  /// Every row of `tiers.json`, in its order.
  public let rows: [Row]

  /// The IDs of the unsatisfied required rows, in byte order.
  public var missingRequired: [String] {
    rows.filter { $0.level == .required && !$0.isSatisfied }.map(\.id)
      .sorted { $0.precedesInByteOrder($1) }
  }

  /// Whether every required row is satisfied.
  public var isComplete: Bool { missingRequired.isEmpty }
}

/// `tiers.json`, the table §8.3 tells implementations to read rather than restate.
struct TierTable: Decodable, Sendable {
  struct Row: Decodable, Sendable {
    let id: String
    let type: String
    let label: String
    let kind: String?
    let variants: [String]?
    let levels: [String: String]
  }
  let rows: [Row]

  static let bundled: Result<TierTable, DossierError> = {
    guard let url = DossierCoreResources.bundle.url(forResource: "tiers", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let table = try? JSONDecoder().decode(TierTable.self, from: data)
    else { return .failure(.resourceUnreadable("tiers.json")) }
    return .success(table)
  }()
}

extension AssetKind {
  /// The variants `tiers.json` lists for this kind, the standard set `W-VARIANT` measures
  /// against (§8.1). `nil` when it lists none.
  ///
  /// - Throws: ``DossierError/resourceUnreadable(_:)`` when the table can't be read.
  package func standardVariants() throws -> [String]? {
    try TierTable.bundled.get().rows.first { row in
      row.variants != nil && row.kind.map(AssetKind.init(rawValue:)) == self
    }?.variants
  }
}

extension DossierBundle {
  /// Completeness against the member's tier. `nil` when there's no member or it has no
  /// `role`, where completeness isn't defined (§8.3), and on version 1 (Appendix A).
  public func completeness() throws -> CompletenessReport? {
    guard let role = member?.fields.role else { return nil }
    return try completeness(tier: role)
  }

  /// Completeness against a tier, from `tiers.json` (§8.3). `nil` on a version 1 manifest,
  /// to which completeness doesn't apply (Appendix A).
  ///
  /// With no ``member``, the `voicePrompt` row is unsatisfied: no member has one.
  ///
  /// - Throws: ``DossierError/unknownCheckRow(_:)`` for a check row with no implementation,
  ///   and ``DossierError/resourceUnreadable(_:)`` when the table can't be read.
  public func completeness(tier: CastRole) throws -> CompletenessReport? {
    guard manifest.manifestVersion == 2 else { return nil }
    let table = try TierTable.bundled.get()
    let rows = try table.rows.map { row -> CompletenessReport.Row in
      guard let text = row.levels[tier.rawValue], let level = CompletenessReport.Level(rawValue: text)
      else { throw DossierError.resourceUnreadable("tiers.json row \(row.id), tier \(tier.rawValue)") }
      let satisfied: Bool
      switch row.type {
      case "asset": satisfied = isSatisfied(assetRow: row)
      case "check": satisfied = try isSatisfied(checkID: row.id)
      default: throw DossierError.resourceUnreadable("tiers.json row type \(row.type)")
      }
      return .init(id: row.id, label: row.label, level: level, isSatisfied: satisfied)
    }
    return CompletenessReport(tier: tier, rows: rows)
  }

  private func isSatisfied(assetRow row: TierTable.Row) -> Bool {
    let selected = manifest.assets.filter {
      $0.status == .selected && $0.kind == AssetKind(rawValue: row.kind ?? "")
    }
    guard let variants = row.variants else { return !selected.isEmpty }
    return variants.allSatisfy { variant in
      selected.contains { $0.variant?.hasSameBytes(as: variant) ?? false }
    }
  }

  /// §8.3's check rows, by ID.
  private func isSatisfied(checkID id: String) throws -> Bool {
    switch id {
    case "description.full": return hasSelectedDescription(sections: CharacterDocument.fullSections)
    case "description.short": return hasSelectedDescription(sections: CharacterDocument.shortSections)
    case "voicePrompt": return !(member?.fields.voicePrompt ?? "").isEmpty
    case "vox.1.7b": return selectedVoxHolds("1.7b")
    case "vox.0.6b": return selectedVoxHolds("0.6b")
    case "sample.neutral.1.7b": return hasNeutralSample(model: "1.7b")
    case "sample.neutral.0.6b": return hasNeutralSample(model: "0.6b")
    case "sample.range":
      return selectedSamples.filter { !($0.variant?.hasSameBytes(as: "neutral") ?? false) }.count >= 3
    case "pronunciation": return description?.hasNonEmptySection("Pronunciation") ?? false
    case "training.withLora":
      let hasLora = manifest.assets.contains { $0.kind == .lora && $0.status == .selected }
      return !hasLora || manifest.assets.contains { $0.kind == .training }
    default:
      throw DossierError.unknownCheckRow(id)
    }
  }

  private func hasSelectedDescription(sections: [String]) -> Bool {
    guard selectedAsset(kind: .description) != nil, let description else { return false }
    return sections.allSatisfy(description.hasSection)
  }

  private func selectedVoxHolds(_ size: String) -> Bool {
    guard let vox = selectedAsset(kind: .vox) else { return false }
    return vox.provenance.holds(size: size)
  }

  private var selectedSamples: [Asset] {
    manifest.assets.filter { $0.kind == .voiceSample && $0.status == .selected }
  }

  private func hasNeutralSample(model: String) -> Bool {
    selectedSamples.contains {
      ($0.variant?.hasSameBytes(as: "neutral") ?? false) && ($0.model?.hasSameBytes(as: model) ?? false)
    }
  }
}
