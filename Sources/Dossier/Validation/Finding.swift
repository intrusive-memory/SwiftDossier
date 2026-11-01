import DossierCore

/// One thing a validator has to say about a bundle or a cast (§14).
public struct Finding: Sendable, Equatable {
  /// How much a finding matters.
  public enum Level: String, Sendable, Equatable {
    /// A reader may reject the bundle.
    case error
    /// A reader opens the bundle.
    case warning
  }

  /// §14's stable codes.
  public enum Code: String, Sendable, Equatable, CaseIterable {
    /// Unknown `manifestVersion`.
    case version = "E-VERSION"
    /// Name invalid (§2).
    case name = "E-NAME"
    /// Bundle name, manifest `character`, `CAST.md` member and `CHARACTER.md` disagree (§3).
    case nameMismatch = "E-NAME-MISMATCH"
    /// `CAST.md` can't be read.
    case cast = "E-CAST"
    /// A directory a member points at has no `manifest.json`, or it isn't a JSON object.
    case manifest = "E-MANIFEST"
    /// A version 2 manifest in a directory without `.dossier`.
    case notBundle = "E-NOT-BUNDLE"
    /// A path in the manifest breaks §5.2's rules.
    case path = "E-PATH"
    /// A `files` entry has no file.
    case fileMissing = "E-FILE-MISSING"
    /// A file's hash or size doesn't match its entry.
    case fileHash = "E-FILE-HASH"
    /// A zero-byte file.
    case zeroByte = "E-ZERO-BYTE"
    /// `manifestChecksum` doesn't match.
    case checksum = "E-CHECKSUM"
    /// An asset with no `files` entry.
    case assetNoFile = "E-ASSET-NO-FILE"
    /// Two assets with the same `path`.
    case assetDuplicate = "E-ASSET-DUPLICATE"
    /// More than one `selected` for a `kind` + `variant` (`voiceSample`: + `model`).
    case multiSelected = "E-MULTI-SELECTED"
    /// A retired kind in a version 2 manifest.
    case kindRetired = "E-KIND-RETIRED"
    /// The manifest fails its schema.
    case schema = "E-SCHEMA"
    /// A file with no asset entry.
    case unclassified = "W-UNCLASSIFIED"
    /// A derived asset's inputs changed.
    case stale = "W-STALE"
    /// Wrong aspect ratio for the kind (§8.1).
    case shape = "W-SHAPE"
    /// An `expression` or `view` variant outside the standard set.
    case variant = "W-VARIANT"
    /// A `.json` sidecar in `images/`.
    case sidecar = "W-SIDECAR"
    /// No `CAST.md` member points at the bundle.
    case orphan = "W-ORPHAN"
    /// The member's `manifest:` doesn't point at this bundle (§3).
    case pointer = "W-POINTER"
    /// A member with a `manifest:` has no `role`.
    case role = "W-ROLE"
    /// `voices.voxalta` doesn't name the selected `vox`.
    case voiceElsewhere = "W-VOICE-ELSEWHERE"
    /// `voicePrompt` differs from the vox's.
    case voicePrompt = "W-VOICE-PROMPT"
    /// An undefined or unused footnote.
    case footnote = "W-FOOTNOTE"
    /// The page is over 10,000,000 bytes.
    case pageSize = "W-PAGE-SIZE"
    /// The page references something outside itself (§11).
    case pageExternal = "W-PAGE-EXTERNAL"
    /// A required tier row is missing.
    case incomplete = "W-INCOMPLETE"
    /// A version 1 manifest.
    case v1 = "W-V1"

    /// The level §14 gives this code.
    public var level: Level { rawValue.hasPrefix("E-") ? .error : .warning }
  }

  /// The stable code.
  public let code: Code
  /// A description of the finding, for people.
  public let message: String
  /// What the finding is about, or `nil` when it's about no one file. Relative to the
  /// directory validated: the bundle, or for a cast the directory holding `CAST.md`.
  public let path: String?

  /// The level §14 gives the code.
  public var level: Level { code.level }
}

/// What a validator found (§14): the findings, and completeness against each tier.
public struct ValidationReport: Sendable, Equatable {
  /// A bundle measured against its member's tier.
  public struct BundleCompleteness: Sendable, Equatable {
    /// The bundle, relative to the directory validated. Empty when the bundle is that directory.
    public let bundlePath: String
    /// Every row with its state.
    public let report: CompletenessReport
  }

  /// Every finding, in a stable order.
  public let findings: [Finding]
  /// One entry per bundle whose completeness is defined, which takes a `CAST.md` member
  /// with a `role` and a readable version 2 manifest (§8.3, Appendix A).
  public let completeness: [BundleCompleteness]

  /// 0 clean, 1 warnings only, 2 errors.
  public var exitStatus: Int32 {
    if findings.contains(where: { $0.level == .error }) { return 2 }
    return findings.isEmpty ? 0 : 1
  }
}
