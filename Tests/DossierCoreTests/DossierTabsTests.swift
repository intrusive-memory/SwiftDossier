import Foundation
import Testing

@testable import DossierCore

@Suite("DossierTabs (data/fields.json)")
struct DossierTabsTests {
  /// The bundled file, read without `DossierTabs`.
  private func raw() throws -> [String: Any] {
    let url = try #require(DossierCoreResources.bundle.url(forResource: "fields", withExtension: "json"))
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  private func field(_ key: String) throws -> DossierTabs.Field {
    let list = try DossierTabs.bundled()
    let all = list.pageBefore + list.tabs.flatMap(\.fields) + list.pageAfter
    return try #require(all.first { $0.key == key })
  }

  @Test("DF-47: seven tabs, in its order")
  func tabs() throws {
    let tabs = try DossierTabs.bundled().tabs
    #expect(tabs.map(\.label) == ["Profile", "Portrait", "Face", "Views", "Expressions", "Voice", "Samples"])
    #expect(tabs.map(\.key) == ["profile", "portrait", "face", "views", "expressions", "voice", "samples"])
  }

  @Test("60 keys, items included, unique, and in the file's document order")
  func keys() throws {
    let keys = try DossierTabs.bundled().keys
    #expect(keys.count == 60)
    #expect(Set(keys).count == keys.count)

    // The walk tools/check_template.py makes, over the raw JSON.
    func walk(_ fields: Any?) -> [String] {
      ((fields as? [[String: Any]]) ?? []).flatMap { field -> [String] in
        [field["key"] as? String ?? ""]
          + ((field["items"] as? [[String: Any]]) ?? []).map { $0["key"] as? String ?? "" }
      }
    }
    let file = try raw()
    let page = try #require(file["page"] as? [String: Any])
    let tabs = try #require(file["tabs"] as? [[String: Any]])
    let expected =
      walk(page["before"])
      + tabs.flatMap { [$0["key"] as? String ?? ""] + walk($0["fields"]) }
      + walk(page["after"])
    #expect(keys == expected)
  }

  @Test("Every field's label, kind, empty text and source are the file's")
  func fieldValues() throws {
    let file = try raw()
    let page = try #require(file["page"] as? [String: Any])
    let tabs = try #require(file["tabs"] as? [[String: Any]])
    let rawFields =
      ((page["before"] as? [[String: Any]]) ?? [])
      + tabs.flatMap { ($0["fields"] as? [[String: Any]]) ?? [] }
      + ((page["after"] as? [[String: Any]]) ?? [])
    #expect(rawFields.count == 44)

    let kinds = try DossierTabs.bundled().kinds
    #expect(kinds == file["kinds"] as? [String])
    for entry in rawFields {
      let found = try field(try #require(entry["key"] as? String))
      #expect(found.label == entry["label"] as? String)
      #expect(found.kind == entry["kind"] as? String)
      #expect(kinds.contains(found.kind))
      #expect(found.emptyText == entry["emptyText"] as? String)
      #expect(found.source["from"]?.stringValue == (entry["source"] as? [String: Any])?["from"] as? String)
      #expect(found.labelVisible == (entry["labelVisible"] as? Bool ?? true))
    }
  }

  @Test("The optional keys arrive: null text, wrap, caption, overlay, row, role, items, note")
  func optionalKeys() throws {
    #expect(try field("page.face").emptyText == nil)
    #expect(try field("page.face").labelVisible == false)
    #expect(try field("profile.age").group != nil)
    #expect(try field("profile.sampleLine").wrap == ["\u{201C}", "\u{201D}"])
    #expect(try field("portrait.image").caption != nil)
    #expect(try field("face.portrait").overlay != nil)
    #expect(try field("samples.lines").row?["audio"]?.stringValue == "path")
    #expect(try field("page.integrity").role == "banner")
    #expect(try field("profile.name").items.isEmpty)
    let views = try field("views.set").items
    #expect(views.count == 4)
    #expect(views[1].note == "The portrait")
    #expect(views[0].note == nil)
    #expect(views[0].source["variant"]?.stringValue == "front")
    #expect(try field("expressions.set").items.count == 5)
  }

  @Test("A key fields.json adds fails here, so a new pin can't lose it silently")
  func noUnreadKeys() throws {
    let readField: Set<String> = [
      "key", "label", "kind", "emptyText", "source", "group", "textStyle", "labelStyle", "labelVisible",
      "wrap", "caption", "overlay", "row", "role", "items",
    ]
    let readItem: Set<String> = ["key", "label", "emptyText", "source", "note"]
    let file = try raw()
    let page = try #require(file["page"] as? [String: Any])
    let tabs = try #require(file["tabs"] as? [[String: Any]])
    let fields =
      ((page["before"] as? [[String: Any]]) ?? [])
      + tabs.flatMap { ($0["fields"] as? [[String: Any]]) ?? [] }
      + ((page["after"] as? [[String: Any]]) ?? [])
    for entry in fields {
      #expect(Set(entry.keys).subtracting(readField).isEmpty, "\(entry["key"] ?? "?")")
      for item in (entry["items"] as? [[String: Any]]) ?? [] {
        #expect(Set(item.keys).subtracting(readItem).isEmpty, "\(item["key"] ?? "?")")
      }
    }
    #expect(Set(file.keys) == ["$comment", "formatVersion", "kinds", "sources", "values", "page", "tabs"])
    #expect(tabs.allSatisfy { Set($0.keys) == ["key", "label", "fields"] })
  }

  @Test("A malformed list says where")
  func malformed() {
    let text = #"{"formatVersion":2,"kinds":[],"page":{"before":[{"key":"a.b"}],"after":[]},"tabs":[]}"#
    #expect(throws: DossierError.self) { try DossierTabs(parsing: Data(text.utf8)) }
    do {
      _ = try DossierTabs(parsing: Data(text.utf8))
    } catch {
      #expect(error as? DossierError == .resourceUnreadable("fields.json: a.b.label is missing or has the wrong type"))
    }
  }
}
