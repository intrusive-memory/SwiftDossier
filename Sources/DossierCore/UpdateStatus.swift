import Foundation

/// §5.7's answer: whether a bundle is being updated at a given time.
public struct UpdateStatus: Sendable, Equatable {
  /// A marker that counts at that time. A reader checks only `expiresAt` (§5.7), so `writer`
  /// and `label` are there when they're strings, and nothing depends on them.
  public struct ActiveMarker: Sendable, Equatable {
    /// The marker's `<id>`.
    public let id: String
    /// When it stops counting, unless it's renewed.
    public let expiresAt: Date
    /// The tool making the update.
    public let writer: String?
    /// One line for a person: what the update is doing.
    public let label: String?
  }

  /// The active markers, in byte order of the id.
  public let activeMarkers: [ActiveMarker]

  /// §5.7's question: at least one marker in the bundle's root directory is active.
  public var isUpdating: Bool { !activeMarkers.isEmpty }

  /// Reads the markers in a bundle's root directory. Nothing is written, `manifest.json` isn't
  /// read, and a directory that can't be listed has no markers, so a host can ask this of a
  /// bundle it can't open at the moment (§12).
  ///
  /// - Parameters:
  ///   - bundle: The bundle directory.
  ///   - now: The time to answer for.
  public static func read(bundle: URL, at now: Date) -> UpdateStatus {
    let active = UpdateMarker.files(inBundle: bundle).compactMap { file -> ActiveMarker? in
      guard let data = try? Data(contentsOf: file.url),
        let object = UpdateMarker.object(in: data),
        let expiresAt = UpdateMarker.expiresAt(of: object),
        UpdateMarker.isActive(expiresAt: expiresAt, at: now)
      else { return nil }
      return ActiveMarker(
        id: file.id, expiresAt: expiresAt, writer: object["writer"]?.stringValue, label: object["label"]?.stringValue)
    }
    return UpdateStatus(activeMarkers: active)
  }
}

extension DossierBundle {
  /// Is this bundle being updated at time `now`? (§5.7.) The disk is read on every call, as a
  /// marker can expire with no change on disk (§12).
  ///
  /// - Parameter now: The time to answer for. Default: the system clock.
  public func updateStatus(at now: Date = Date()) -> UpdateStatus {
    UpdateStatus.read(bundle: url, at: now)
  }
}

/// §5.7's rules for what a marker is, shared by the reader here and the writer in `Dossier`.
///
/// `schemas/update-marker.schema.json` is what a writer writes (`UpdateMarkerStore` checks it). A
/// reader has no use for it: §5.7 has a reader check only `expiresAt`, so that's what this does.
package enum UpdateMarker {
  /// §5.7's limit on how far ahead an active `expiresAt` can be.
  package static let maximumLifetime: TimeInterval = 3600

  private static let prefix = Array(".update-".utf8)
  private static let suffix = Array(".json".utf8)

  /// One or more ASCII letters, digits or hyphens.
  package static func isValidID(_ id: String) -> Bool {
    !id.utf8.isEmpty
      && id.utf8.allSatisfy { byte in
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D
      }
  }

  /// The `<id>` of `.update-<id>.json`, or `nil` for a name that isn't a marker's.
  package static func id(fromName name: String) -> String? {
    let bytes = Array(name.utf8)
    guard bytes.count > prefix.count + suffix.count, bytes.starts(with: prefix), bytes.suffix(suffix.count) == suffix[...]
    else { return nil }
    let id = String(decoding: bytes[prefix.count..<(bytes.count - suffix.count)], as: UTF8.self)
    return isValidID(id) ? id : nil
  }

  /// The name of the marker with this id.
  package static func name(forID id: String) -> String { ".update-\(id).json" }

  /// The markers in a bundle's root directory, by byte order of the id. Subdirectories aren't
  /// looked in.
  ///
  /// SPEC-GAP: §5.7: "a marker is a file". As in §5.2, a symlink isn't one and isn't followed, so
  /// no read leaves the bundle. Neither is a FIFO, and reading one would hang.
  package static func files(inBundle bundle: URL) -> [(id: String, url: URL)] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let entries = try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: keys)
    else { return [] }
    return
      entries
      .compactMap { entry -> (id: String, url: URL)? in
        guard let id = id(fromName: entry.lastPathComponent),
          let values = try? entry.resourceValues(forKeys: Set(keys)),
          values.isRegularFile == true, values.isSymbolicLink != true
        else { return nil }
        return (id, entry)
      }
      .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
  }

  /// The content, when it's a JSON object.
  package static func object(in data: Data) -> JSONObject? {
    (try? JSONValue.parse(data))?.objectValue
  }

  /// `expiresAt`, when it's a valid timestamp (§1).
  package static func expiresAt(of object: JSONObject) -> Date? {
    object["expiresAt"]?.stringValue.flatMap(date(fromTimestamp:))
  }

  /// `now < expiresAt <= now + 3600 seconds`.
  package static func isActive(expiresAt: Date, at now: Date) -> Bool {
    now < expiresAt && expiresAt <= now.addingTimeInterval(maximumLifetime)
  }

  /// §1's timestamp, exactly: `YYYY-MM-DDTHH:MM:SSZ` in ASCII digits, naming a real UTC time.
  ///
  /// SPEC-GAP: §1, §5.7: RFC 3339 allows a leap second, `23:59:60Z`, which the schema's pattern
  /// would pass too. A `Date` can't hold one and no writer has a reason to write one, so here it's
  /// not valid, and the marker doesn't count.
  package static func date(fromTimestamp text: String) -> Date? {
    let bytes = Array(text.utf8)
    guard bytes.count == 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
      bytes[13] == 0x3A, bytes[16] == 0x3A, bytes[19] == 0x5A
    else { return nil }
    func number(_ range: Range<Int>) -> Int? {
      var value = 0
      for byte in bytes[range] {
        guard (0x30...0x39).contains(byte) else { return nil }
        value = value * 10 + Int(byte - 0x30)
      }
      return value
    }
    guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
      let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
      (1...12).contains(month), hour < 24, minute < 60, second < 60
    else { return nil }
    let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let lengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...lengths[month - 1]).contains(day) else { return nil }

    // Days from 1970-01-01 in the proleptic Gregorian calendar: years as starting in March.
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    let days = era * 146_097 + dayOfEra - 719_468
    return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hour * 3600 + minute * 60 + second))
  }
}
