import DossierCore
import Foundation
import SwiftReparto

/// What ``DossierBundle/refresh(cast:beforeCastWrite:)`` did, and why it left the rest.
public struct RefreshReport: Sendable {
  /// A file that stays unclassified, and why.
  public struct UnclassifiedFile: Sendable, Equatable {
    /// Its bundle path.
    public let path: String
    /// Why it wasn't adopted.
    public let reason: UnclassifiedReason
  }

  /// Why a file stays unclassified (§5.6).
  public enum UnclassifiedReason: Sendable, Equatable, CustomStringConvertible {
    /// §5.6 has no rule for this path.
    case noRule
    /// A sample needs a selected `vox`, and there is none.
    case noSelectedVox
    /// The selected `vox`'s `provenance.models` gives no size, and the file name has none it holds.
    case noModelSize
    /// The name gives no variant.
    case noVariant
    /// A sample needs `voice/samples.yaml`, and there is none.
    case noSamplesFile
    /// `voice/samples.yaml` doesn't read as YAML, or fails its schema.
    case samplesUnreadable(String)
    /// `voice/samples.yaml` has no entry for this variant and model.
    case noSamplesEntry(variant: String, model: String)

    /// A description, for people.
    public var description: String {
      switch self {
      case .noRule: return "no rule adopts a file at this path"
      case .noSelectedVox: return "a sample needs a selected vox, and there is none"
      case .noModelSize:
        return "the selected vox's provenance.models gives no size, and the file name has none it holds"
      case .noVariant: return "the file name gives no variant"
      case .noSamplesFile: return "a sample needs voice/samples.yaml, and there is none"
      case .samplesUnreadable(let detail): return "voice/samples.yaml can't be used: \(detail)"
      case .noSamplesEntry(let variant, let model):
        return "voice/samples.yaml has no entry for variant \(variant), model \(model)"
      }
    }
  }

  /// What came of treating the bundle as an orphan (§3).
  public enum OrphanOutcome: Sendable, Equatable {
    /// A member of exactly this name had no `manifest:`, and now points here.
    case pointerSet(member: String, manifest: String)
    /// A member already points here.
    case alreadyPointedAt(member: String)
    /// No member has this name.
    case noMember
    /// Members have a name close to this one. §3 never adopts on a near match.
    case nearMatch([String])
    /// The member of this name points somewhere else.
    case memberPointsElsewhere(member: String, pointer: String)
    /// More than one member has this name.
    case memberAmbiguous
    /// The directory's name and the manifest's `character` disagree, so the bundle has no one name.
    case nameMismatch(directory: String, character: String)
    /// The bundle isn't under the directory holding `CAST.md`.
    case outsideCastDirectory
  }

  /// The listed files whose changed bytes this call accepted, by path, in byte order: their entries
  /// now hold the new hash and size, which clears `E-FILE-HASH`. A file that's only new isn't one.
  public let accepted: [String]
  /// The accepted files whose name no longer matches their hash, in byte order: a name of §4's
  /// `<kind>[-<variant>]-<sha8>.png` form whose `<sha8>` isn't the new hash's first 8. Each keeps
  /// its name, and nothing renames it.
  public let nameMismatches: [String]
  /// The listed files with no asset and no file on disk, in byte order: their entries are gone,
  /// which clears `E-FILE-MISSING`.
  public let dropped: [String]
  /// The assets adopted, each `candidate` (§5.6).
  public let adopted: [Asset]
  /// The files left unclassified, with why, in byte order of the path. `voice/samples.yaml`
  /// isn't one (§4), and neither is a hidden file (§5.2).
  public let unclassified: [UnclassifiedFile]
  /// What came of orphan adoption. `nil` when no `CAST.md` was given.
  public let orphan: OrphanOutcome?
  /// SD-12's report, when `CAST.md` was to be written.
  public let castReport: CastWriteReport?
}

extension DossierBundle {
  /// Brings the manifest up to the disk (SD-11). The files on disk are the source of truth and the
  /// manifest is an index of them, so `E-FILE-HASH` means the manifest is behind the disk. This
  /// accepts files changed since they were listed, drops the entries of listed files that are gone
  /// and have no asset, adopts files another tool put in the bundle by §5.6's rules and, given a
  /// `CAST.md`, sets the pointer of the member this bundle is an orphan of (§3). A near match is
  /// never adopted. Nothing is written when there's nothing to accept, drop or adopt.
  ///
  /// This is the one way to accept a changed file: no other write changes the entry of a file it
  /// didn't write (SD-5). An accepted file keeps its name, and the report says when that name no
  /// longer matches its hash. What was derived from an accepted file then reads as stale (§7). A
  /// file that's both changed and adopted is in both lists of the report.
  ///
  /// §4: a name's `<sha8>` records the bytes when the file was added and the manifest's hash is the
  /// authority, so the name stays and is reported. §5.6: a missing file with no asset is dropped and
  /// reported. An asset's missing file is refused and reported. §5.6 leaves how to resolve that open,
  /// and here it refuses the whole call (``DossierWriteError/assetFilesMissing(_:)``), even with
  /// nothing else to write and with nothing changed. For the moment `remove` is the way out.
  ///
  /// An adopted `vox` is `candidate`, so a sample beside it stays unclassified until it's
  /// selected and this runs again.
  ///
  /// An adopted file's `provenance.provider` is `import` (§5.6), and its bytes are never changed.
  ///
  /// SPEC-GAP: §5.6, §6: `vox` gets no `models`: the file holds them and this package doesn't read
  /// vox-format, so a `select` alone leaves samples unadoptable, which the report says. `add` with
  /// `provenance` is how a `vox` gets its `models`.
  ///
  /// - Parameters:
  ///   - castURL: The `CAST.md`, for orphan adoption. `nil` leaves it out.
  ///   - beforeCastWrite: Given SD-12's report before anything is written, when `CAST.md` is to
  ///     be written. Throwing stops the call with nothing changed.
  /// - Returns: What was accepted, dropped and adopted, and why anything else wasn't.
  /// - Throws: ``DossierWriteError``, ``DossierCore/DossierError``, or what `beforeCastWrite` throws.
  @discardableResult
  public mutating func refresh(
    cast castURL: URL? = nil, beforeCastWrite: ((CastWriteReport) throws -> Void)? = nil
  ) throws -> RefreshReport {
    let writer = ManifestWriter(bundle: url)
    let current = try writer.currentManifest()
    let inventory = BundleInventory(bundle: url)
    let stranded = current.assets.map(\.path).filter { inventory.file(at: $0) == nil }
    guard stranded.isEmpty else { throw DossierWriteError.assetFilesMissing(stranded) }
    // Every asset has its file by here, so what's missing has no asset.
    let dropped = current.files.map(\.path).filter { inventory.file(at: $0) == nil }
      .sorted { $0.precedesInByteOrder($1) }

    let plan = AdoptionPlan(bundle: url, manifest: current)
    let accepted = BundleScan.changedFiles(in: current, bundle: url)
    let hasManifestWrite = !plan.adoptions.isEmpty || !accepted.isEmpty || !dropped.isEmpty

    // First, so an unreadable CAST.md stops the call before the manifest changes.
    let castFile = try castURL.map { try CastFile(url: $0) }
    let orphan = castFile.map { orphanPlan(manifest: current, file: $0) }
    if let castFile, orphan?.document != nil { try beforeCastWrite?(castFile.report) }

    var manifest = current
    var adopted: [Asset] = []
    var member = member
    // Nothing to change holds no marker.
    let write = {
      if hasManifestWrite {
        manifest = try writer.update(accepting: accepted, removing: dropped) { manifest, scan in
          adopted = try plan.adoptions.map { try $0.asset(scan: scan) }
          manifest.assets = manifest.assets + adopted
        }
      }
      if let castFile, let orphan {
        if let document = orphan.document { try castFile.write(document) }
        if let name = orphan.memberName {
          member = (try? Cast.load(castFile.url))?.members.first { $0.character.hasSameBytes(as: name) } ?? member
        }
      }
    }
    if !hasManifestWrite && orphan?.document == nil {
      try write()
    } else {
      try UpdateHolding.holding(bundle: url, label: "refresh", write)
    }
    self = DossierBundle(url: url, manifest: manifest, member: member)
    let hashes = Dictionary(manifest.files.map { (BundleInventory.key($0.path), $0.sha256) }) { first, _ in first }
    let nameMismatches = accepted.filter { path in
      guard let sha8 = ContentName.sha8(ofPath: path), let sha256 = hashes[BundleInventory.key(path)] else { return false }
      return !sha256.utf8.starts(with: sha8.utf8)
    }
    return RefreshReport(
      accepted: accepted, nameMismatches: nameMismatches, dropped: dropped, adopted: adopted,
      unclassified: plan.unclassified, orphan: orphan?.outcome,
      castReport: orphan?.document == nil ? nil : castFile?.report)
  }

  private struct OrphanPlan {
    let outcome: RefreshReport.OrphanOutcome
    var document: CastDocument?
    var memberName: String?
  }

  /// §3: "whose name equals a member that has no `manifest:`". Names compare exactly, as NFC.
  private func orphanPlan(manifest: Manifest, file: CastFile) -> OrphanPlan {
    func normal(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }
    let directoryName = String(url.lastPathComponent.dropLast(".dossier".count))
    guard url.lastPathComponent.hasSuffix(".dossier"), normal(directoryName).hasSameBytes(as: normal(manifest.character))
    else {
      return OrphanPlan(outcome: .nameMismatch(directory: url.lastPathComponent, character: manifest.character))
    }
    guard let pointer = CastFile.pointer(toBundle: url, castDirectory: file.cast.directory) else {
      return OrphanPlan(outcome: .outsideCastDirectory)
    }
    if let member = file.cast.members.first(where: { $0.pointer?.points(at: pointer) ?? false }) {
      return OrphanPlan(outcome: .alreadyPointedAt(member: member.character), memberName: member.character)
    }

    let name = normal(manifest.character)
    let exact = file.cast.members.enumerated().filter { normal($0.element.character).hasSameBytes(as: name) }
    guard exact.count <= 1 else { return OrphanPlan(outcome: .memberAmbiguous) }
    guard let (index, member) = exact.first else {
      let canonical = try? CanonicalName.canonicalize(name)
      let near = file.cast.members.map(\.character).filter { character in
        normal(character).uppercased().hasSameBytes(as: name.uppercased())
          || (canonical != nil && (try? CanonicalName.canonicalize(character)) == canonical)
      }
      return OrphanPlan(outcome: near.isEmpty ? .noMember : .nearMatch(near))
    }
    if let existing = member.pointer {
      return OrphanPlan(outcome: .memberPointsElsewhere(member: member.character, pointer: existing.raw))
    }
    var document = file.document
    document.cast[index].manifest = pointer
    return OrphanPlan(
      outcome: .pointerSet(member: member.character, manifest: pointer), document: document,
      memberName: member.character)
  }
}

/// §5.6's rules, over what's on disk and not yet an asset.
private struct AdoptionPlan {
  /// One file to adopt. What it needs from the write's scan is resolved then.
  struct Adoption {
    let path: String
    let kind: AssetKind
    let createdAt: String
    var sample: Sample?

    struct Sample {
      let variant: String
      let model: String
      let entry: JSONObject
      let vox: String
    }

    func asset(scan: BundleScan) throws -> Asset {
      var provenance = JSONObject([("provider", .string("import"))])
      // §6: these are `voiceSample` keys, and §10 is where the file has them.
      for key in ["instruct", "source"] { provenance[key] = sample?.entry[key] }
      var asset = Asset(
        path: path, kind: kind, status: .candidate, createdAt: createdAt, provenance: Provenance(json: provenance))
      guard let sample else { return asset }
      guard let sha256 = scan.sha256(ofPath: sample.vox) else {
        throw DossierWriteError.assetFilesMissing([sample.vox])
      }
      asset.variant = sample.variant
      asset.model = sample.model
      asset.sampleText = sample.entry["text"]?.stringValue
      asset.language = sample.entry["language"]?.stringValue
      asset.derivedFrom = [DerivedInput(role: "vox", sha256: sha256, path: sample.vox)]
      return asset
    }
  }

  private(set) var adoptions: [Adoption] = []
  private(set) var unclassified: [RefreshReport.UnclassifiedFile] = []

  private static let samplesPath = "voice/samples.yaml"
  private static let samplePrefix = "voice/sample-"
  private static let sampleSuffix = ".m4a"

  init(bundle: URL, manifest: Manifest) {
    let listed = Set(manifest.assets.map { BundleInventory.key($0.path) })
    let voxPath = BundleInventory.key("voice/\(manifest.character).vox")
    let selectedVox = manifest.assets.first { $0.kind == .vox && $0.status == .selected }
    let inventory = BundleInventory(bundle: bundle)
    let samples = Self.readSamples(inventory.file(at: Self.samplesPath))

    for file in inventory.visible
    where !listed.contains(BundleInventory.key(file.path)) && !file.path.hasSameBytes(as: Self.samplesPath) {
      let path = file.path
      let isSample =
        path.hasPrefix(Self.samplePrefix) && path.hasSuffix(Self.sampleSuffix)
        && !path.dropFirst(Self.samplePrefix.count).contains("/")
      if BundleInventory.key(path) == voxPath {
        adoptions.append(Adoption(path: path, kind: .vox, createdAt: Self.createdAt(of: file)))
      } else if isSample {
        let name = String(path.dropFirst(Self.samplePrefix.count).dropLast(Self.sampleSuffix.count))
        switch Self.resolve(sample: name, vox: selectedVox, samples: samples) {
        case .success(let sample):
          adoptions.append(Adoption(path: path, kind: .voiceSample, createdAt: Self.createdAt(of: file), sample: sample))
        case .failure(let refusal):
          unclassified.append(.init(path: path, reason: refusal.reason))
        }
      } else {
        unclassified.append(.init(path: path, reason: .noRule))
      }
    }
  }

  private static func createdAt(of file: BundleInventory.File) -> String {
    let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey])
    return Timestamp.string(from: values?.contentModificationDate ?? Date())
  }

  private struct Refusal: Error {
    let reason: RefreshReport.UnclassifiedReason
  }

  private static func resolve(
    sample name: String, vox: Asset?, samples: Result<[JSONObject], Refusal>
  ) -> Result<Adoption.Sample, Refusal> {
    guard let vox else { return .failure(Refusal(reason: .noSelectedVox)) }
    guard let (variant, model) = variantAndModel(of: name, vox: vox) else {
      return .failure(Refusal(reason: .noModelSize))
    }
    guard !variant.isEmpty else { return .failure(Refusal(reason: .noVariant)) }
    return samples.flatMap { entries in
      guard let entry = entry(in: entries, variant: variant, model: model) else {
        return .failure(Refusal(reason: .noSamplesEntry(variant: variant, model: model)))
      }
      return .success(Adoption.Sample(variant: variant, model: model, entry: entry, vox: vox.path))
    }
  }

  /// §5.6: the name's last `-` part if it's a size the `vox` holds; otherwise the whole name is the
  /// variant and the model is the first size in `provenance.models`.
  private static func variantAndModel(of name: String, vox: Asset) -> (String, String)? {
    let normal = name.precomposedStringWithCanonicalMapping
    if let dash = normal.lastIndex(of: "-") {
      let suffix = String(normal[normal.index(after: dash)...])
      if ModelSize.isSize(suffix), vox.provenance.holds(size: suffix) {
        return (String(normal[..<dash]), suffix.lowercased())
      }
    }
    return vox.provenance.models.lazy.compactMap(ModelSize.first(in:)).first.map { (normal, $0) }
  }

  /// §5.6: an entry for that variant and model, and one with no model matches any.
  ///
  /// SPEC-GAP: §5.6: when one entry names the model and another names none, the one naming it is
  /// taken. Otherwise the first in the file.
  private static func entry(in entries: [JSONObject], variant: String, model: String) -> JSONObject? {
    let forVariant = entries.filter {
      $0["variant"]?.stringValue?.precomposedStringWithCanonicalMapping.hasSameBytes(as: variant) ?? false
    }
    return forVariant.first { $0["model"]?.stringValue?.lowercased() == model }
      ?? forVariant.first { $0["model"] == nil }
  }

  private static func readSamples(_ file: BundleInventory.File?) -> Result<[JSONObject], Refusal> {
    guard let file else { return .failure(Refusal(reason: .noSamplesFile)) }
    do {
      let text = try String(contentsOf: file.url, encoding: .utf8)
      let json = try SamplesFile.json(ofYAML: text)
      let violations = try SchemaEvaluator.bundledSchemas.get().validate(json, against: "samples.schema.json")
      if let first = violations.first {
        return .failure(Refusal(reason: .samplesUnreadable("\(first.path): \(first.message)")))
      }
      return .success(json.arrayValue?.compactMap(\.objectValue) ?? [])
    } catch {
      return .failure(Refusal(reason: .samplesUnreadable(String(describing: error))))
    }
  }
}

/// §4's `images/<kind>[-<variant>]-<sha8>.png`.
enum ContentName {
  /// The `<sha8>` of a path of that form, or `nil` for any other path: a plain name, a kind §8 doesn't
  /// have, or a last part that isn't 8 lowercase hex digits.
  static func sha8(ofPath path: String) -> String? {
    let prefix = "images/"
    let suffix = ".png"
    guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
    let name = path.dropFirst(prefix.count).dropLast(suffix.count)
    guard !name.contains("/") else { return nil }
    let parts = name.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count >= 2, let kind = parts.first, let last = parts.last else { return nil }
    if case .unknown = AssetKind(rawValue: String(kind)) { return nil }
    guard parts.dropFirst().dropLast().allSatisfy({ !$0.isEmpty }) else { return nil }
    let isHex = last.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    return last.utf8.count == 8 && isHex ? String(last) : nil
  }
}

/// A model size in a file name or a `provenance.models` entry (`1.7b`).
///
/// SPEC-GAP: §5.4, §5.6, §8.3: a size is only given by example, and §8.3's "contains" would call
/// `Base` a size `Qwen3-TTS-12Hz-1.7B-Base-bf16` holds. A size is digits, optionally a point and
/// digits, then `b`, in either case; in an entry, it's a whole part between `-`, `_` or spaces.
enum ModelSize {
  static func isSize(_ text: String) -> Bool {
    let parts = text.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
    guard let last = text.utf8.last, last == UInt8(ascii: "b") || last == UInt8(ascii: "B"), parts.count <= 2 else {
      return false
    }
    func digits<S: Sequence>(_ part: S) -> Bool where S.Element == UInt8 {
      var count = 0
      for byte in part {
        guard (0x30...0x39).contains(byte) else { return false }
        count += 1
      }
      return count > 0
    }
    return parts.enumerated().allSatisfy { index, part in
      digits(index == parts.count - 1 ? part.dropLast() : part)
    }
  }

  /// The first size in an entry of `provenance.models`, lowercased.
  static func first(in entry: String) -> String? {
    entry.split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace })
      .map(String.init).first(where: isSize)?.lowercased()
  }
}
