import DossierCore
import Foundation
import Testing

/// §5.7's rule, on synthetic bundles, so a tree with no update fixtures still tests it.
@Suite("Update status (§5.7)")
struct UpdateStatusTests {
  /// §5.7's worked example.
  private static let now = UpdateMarker.date(fromTimestamp: "2026-10-19T17:00:00Z")!

  private final class Directory {
    let url: URL
    init() throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateStatusTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ name: String, _ text: String) throws {
      try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }
    func marker(_ name: String = ".update-a.json", expiresAt: String) throws {
      try write(name, #"{"writer": "w", "startedAt": "2026-10-19T16:55:00Z", "expiresAt": "\#(expiresAt)"}"#)
    }
    func isUpdating(at now: Date = UpdateStatusTests.now) -> Bool {
      UpdateStatus.read(bundle: url, at: now).isUpdating
    }
  }

  @Test(
    "§5.7's worked example, and each limit",
    arguments: [
      ("2026-10-19T17:05:00Z", true),  // five minutes ahead
      ("2026-10-19T17:00:01Z", true),  // the first second that's after now
      ("2026-10-19T18:00:00Z", true),  // exactly at now + 3600
      ("2026-10-19T18:00:01Z", false),  // one second past
      ("2026-10-19T17:00:00Z", false),  // exactly at now
      ("2026-10-19T16:59:59Z", false),  // expired
      ("2026-10-19T12:00:00+05:00", false),  // the right instant, not a timestamp under §1
    ])
  func limits(_ expiresAt: String, _ active: Bool) throws {
    let directory = try Directory()
    try directory.marker(expiresAt: expiresAt)
    #expect(directory.isUpdating() == active)
  }

  @Test("A `now` with a fraction of a second compares as it is")
  func fractionalNow() throws {
    let now = Self.now.addingTimeInterval(0.5)
    let directory = try Directory()
    try directory.marker(expiresAt: "2026-10-19T17:00:00Z")
    #expect(!directory.isUpdating(at: now))
    try directory.marker(expiresAt: "2026-10-19T18:00:00Z")
    #expect(directory.isUpdating(at: now))
    try directory.marker(expiresAt: "2026-10-19T18:00:01Z")
    #expect(!directory.isUpdating(at: now), "3600.5 seconds ahead")
  }

  @Test(
    "A timestamp that isn't §1's doesn't count",
    arguments: [
      "2026-10-19T17:05:00z", "2026-10-19t17:05:00Z", "2026-10-19 17:05:00Z", "2026-10-19T17:05:00.000Z",
      "2026-10-19T17:05Z", "2026-10-19T17:05:00", "2026-10-19T17:05:00+00:00", " 2026-10-19T17:05:00Z",
      "2026-10-19T17:05:00Z ", "٢٠٢٦-10-19T17:05:00Z", "", "soon",
      "2026-13-19T17:05:00Z", "2026-00-19T17:05:00Z", "2026-10-32T17:05:00Z", "2026-10-00T17:05:00Z",
      "2026-02-29T17:05:00Z", "2026-10-19T24:00:00Z", "2026-10-19T17:60:00Z", "2026-10-19T17:05:60Z",
    ])
  func notATimestamp(_ text: String) throws {
    #expect(UpdateMarker.date(fromTimestamp: text) == nil)
    let directory = try Directory()
    try directory.marker(expiresAt: text)
    #expect(!directory.isUpdating())
  }

  @Test("§1's timestamps read as the instants they name")
  func timestamps() throws {
    let dates = [
      "1970-01-01T00:00:00Z": 0.0, "2026-10-19T17:04:00Z": 1_792_429_440, "2000-02-29T23:59:59Z": 951_868_799,
      "1969-12-31T23:59:59Z": -1, "2024-03-01T00:00:00Z": 1_709_251_200,
    ]
    for (text, seconds) in dates {
      #expect(UpdateMarker.date(fromTimestamp: text)?.timeIntervalSince1970 == seconds, "\(text)")
    }
    #expect(UpdateMarker.date(fromTimestamp: "1900-02-29T00:00:00Z") == nil)
  }

  @Test(
    "Content of the wrong shape doesn't count",
    arguments: [
      "", "{ not json", "[]", "null", "\"2026-10-19T17:05:00Z\"", "{}", #"{"writer": "w"}"#,
      #"{"expiresAt": null}"#, #"{"expiresAt": 1792429500}"#, #"{"expiresAt": ["2026-10-19T17:05:00Z"]}"#,
      #"{"EXPIRESAT": "2026-10-19T17:05:00Z"}"#, #"[{"expiresAt": "2026-10-19T17:05:00Z"}]"#,
    ])
  func wrongShape(_ content: String) throws {
    let directory = try Directory()
    try directory.write(".update-a.json", content)
    #expect(!directory.isUpdating())
  }

  @Test("A reader checks only expiresAt: other keys can be missing, wrong or unknown")
  func onlyExpiresAt() throws {
    let directory = try Directory()
    try directory.write(".update-a.json", #"{"expiresAt": "2026-10-19T17:05:00Z"}"#)
    #expect(directory.isUpdating())
    try directory.write(
      ".update-a.json", #"{"expiresAt": "2026-10-19T17:05:00Z", "writer": 7, "startedAt": "then", "other": {}}"#)
    #expect(directory.isUpdating())
  }

  @Test("Content that isn't UTF-8 is unreadable")
  func notUTF8() throws {
    let directory = try Directory()
    try Data([0xFF, 0xFE, 0x00]).write(to: directory.url.appendingPathComponent(".update-a.json"))
    #expect(!directory.isUpdating())
  }

  @Test(
    "A name that doesn't match isn't a marker",
    arguments: [
      "update-a.json", ".update-.json", ".update-a.json.tmp", ".update-a_b.json", ".update-a.b.json", ".update-a b.json",
      ".update-é.json", ".UPDATE-a.json", ".update-a.JSON", ".update-a.json~", ".update-a", ".updatea.json", "..update-a.json",
      "x.update-a.json",
    ])
  func wrongName(_ name: String) throws {
    let directory = try Directory()
    try directory.marker(name, expiresAt: "2026-10-19T17:05:00Z")
    #expect(!directory.isUpdating())
  }

  @Test("A right name in letters, digits and hyphens is a marker", arguments: [".update-a.json", ".update---.json", ".update-A9-z.json"])
  func rightName(_ name: String) throws {
    let directory = try Directory()
    try directory.marker(name, expiresAt: "2026-10-19T17:05:00Z")
    #expect(directory.isUpdating())
  }

  @Test("Only the root directory is checked")
  func rootOnly() throws {
    let directory = try Directory()
    let nested = directory.url.appendingPathComponent("images")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(#"{"expiresAt": "2026-10-19T17:05:00Z"}"#.utf8).write(to: nested.appendingPathComponent(".update-a.json"))
    #expect(!directory.isUpdating())
  }

  @Test("A directory, a symlink or a FIFO at a marker's name isn't a marker, and nothing hangs")
  func notAFile() throws {
    let directory = try Directory()
    let manager = FileManager.default
    try manager.createDirectory(at: directory.url.appendingPathComponent(".update-dir.json"), withIntermediateDirectories: true)
    let outside = directory.url.appendingPathComponent("outside.json")
    try Data(#"{"expiresAt": "2026-10-19T17:05:00Z"}"#.utf8).write(to: outside)
    try manager.createSymbolicLink(at: directory.url.appendingPathComponent(".update-link.json"), withDestinationURL: outside)
    #expect(mkfifo(directory.url.appendingPathComponent(".update-fifo.json").path, 0o600) == 0)
    #expect(!directory.isUpdating())
  }

  @Test("One active marker among others is enough, and each active one is reported")
  func anyActive() throws {
    let directory = try Directory()
    try directory.marker(".update-old.json", expiresAt: "2026-10-19T16:00:00Z")
    try directory.write(".update-bad.json", "{")
    #expect(!directory.isUpdating())
    try directory.write(
      ".update-b.json", #"{"writer": "w", "label": "rendering", "expiresAt": "2026-10-19T17:05:00Z"}"#)
    try directory.write(".update-a.json", #"{"writer": 7, "expiresAt": "2026-10-19T18:00:00Z"}"#)
    let status = UpdateStatus.read(bundle: directory.url, at: Self.now)
    #expect(status.isUpdating)
    #expect(status.activeMarkers.map(\.id) == ["a", "b"])
    #expect(status.activeMarkers[0].writer == nil)
    #expect(status.activeMarkers[1].writer == "w")
    #expect(status.activeMarkers[1].label == "rendering")
    #expect(status.activeMarkers[1].expiresAt == UpdateMarker.date(fromTimestamp: "2026-10-19T17:05:00Z"))
  }

  @Test("The clock is the argument: a marker stops counting with no change on disk")
  func clockIsInjected() throws {
    let directory = try Directory()
    try directory.marker(expiresAt: "2026-10-19T17:05:00Z")
    #expect(!directory.isUpdating(at: Self.now.addingTimeInterval(-3600)), "too far ahead then")
    #expect(directory.isUpdating(at: Self.now))
    #expect(!directory.isUpdating(at: Self.now.addingTimeInterval(300)), "expired by then")
  }

  @Test("A bundle's status reads the disk each time, and changes nothing")
  func bundleStatus() throws {
    let parent = try Directory()
    let url = parent.url.appendingPathComponent("THE TINKER.dossier")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Manifest(character: "THE TINKER", updatedAt: "2026-01-01T00:00:00Z").encoded()
      .write(to: url.appendingPathComponent("manifest.json"))
    let bundle = try DossierBundle.open(at: url)
    #expect(!bundle.updateStatus(at: Self.now).isUpdating)
    let marker = Data(#"{"expiresAt": "2026-10-19T17:05:00Z"}"#.utf8)
    try marker.write(to: url.appendingPathComponent(".update-a.json"))
    let before = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    #expect(bundle.updateStatus(at: Self.now).isUpdating)
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() == before)
    #expect(try Data(contentsOf: url.appendingPathComponent(".update-a.json")) == marker)
  }

  @Test("A directory that's missing has no markers")
  func missingDirectory() throws {
    let directory = try Directory()
    #expect(!UpdateStatus.read(bundle: directory.url.appendingPathComponent("gone"), at: Self.now).isUpdating)
  }
}
