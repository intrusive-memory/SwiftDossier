import Foundation

/// The field list, `data/fields.json` (DF-47, §11): the page's tabs and, per tab, every field in
/// order. Renderers and native editors lay out from this and add, drop or reorder nothing.
///
/// Everything here is read from the bundled file. No tab, field or kind is named in Swift (SD-2),
/// and a value `fields.json` leaves out stays absent: this type applies no defaults beyond
/// ``Field/labelVisible``. `template/README.md` says how a renderer reads the rest.
public struct DossierTabs: Sendable, Equatable {
  /// One tab of the page.
  public struct Tab: Sendable, Equatable {
    /// The tab's key, which is its anchor and element id on the page.
    public let key: String
    /// The tab's label.
    public let label: String
    /// The tab's fields, in order.
    public let fields: [Field]
  }

  /// One field of a tab, or of the page outside the tabs.
  public struct Field: Sendable, Equatable {
    /// The field's key, which is its anchor and element id on the page.
    public let key: String
    /// The field's label.
    public let label: String
    /// One of ``DossierTabs/kinds``.
    public let kind: String
    /// What to show with no value. `nil` means the element stays on the page with no content.
    public let emptyText: String?
    /// Where the value comes from. Its `from` is a key of `sources` in `fields.json`.
    public let source: JSONObject
    /// The Profile layout group this field belongs to, if any.
    public let group: String?
    /// An entry of `type` in `data/tokens.json`, if the field names one.
    public let textStyle: String?
    /// An entry of `type` in `data/tokens.json`, if the field names one.
    public let labelStyle: String?
    /// Whether the label is shown. When false it's kept for assistive technology only.
    public let labelVisible: Bool
    /// The two strings to put around the value, if any.
    public let wrap: [String]?
    /// The field's caption, if any.
    public let caption: JSONObject?
    /// The overlay on an image, if any.
    public let overlay: JSONObject?
    /// What each row of an audio field shows, if it has rows.
    public let row: JSONObject?
    /// The field's role, if any (`template/README.md` rule 11).
    public let role: String?
    /// The items of a field whose source is `items`, in order. Otherwise empty.
    public let items: [Item]
  }

  /// One item of a field, each with its own key, label, source and empty text.
  public struct Item: Sendable, Equatable {
    /// The item's key, which is its anchor and element id on the page.
    public let key: String
    /// The item's label.
    public let label: String
    /// What to show with no value. `nil` means the element stays on the page with no content.
    public let emptyText: String?
    /// Where the value comes from.
    public let source: JSONObject
    /// The item's note, if any.
    public let note: String?
  }

  /// The format version the list belongs to.
  public let formatVersion: Int
  /// The values a field's ``Field/kind`` can have.
  public let kinds: [String]
  /// The fields that come before the tabs, on every tab and in print.
  public let pageBefore: [Field]
  /// The tabs, in order.
  public let tabs: [Tab]
  /// The fields that follow the tabs, on every tab and in print.
  public let pageAfter: [Field]

  /// Every key, tabs' and items' included, in document order.
  public var keys: [String] {
    func walk(_ fields: [Field]) -> [String] {
      fields.flatMap { [$0.key] + $0.items.map(\.key) }
    }
    return walk(pageBefore) + tabs.flatMap { [$0.key] + walk($0.fields) } + walk(pageAfter)
  }

  /// The list from the bundled `fields.json`.
  ///
  /// - Throws: ``DossierError/resourceUnreadable(_:)`` when the file is missing or doesn't have
  ///   this shape.
  public static func bundled() throws -> DossierTabs { try loaded.get() }

  private static let loaded: Result<DossierTabs, DossierError> = {
    do {
      guard let url = DossierCoreResources.bundle.url(forResource: "fields", withExtension: "json"),
        let data = try? Data(contentsOf: url)
      else { throw DossierError.resourceUnreadable("fields.json") }
      return .success(try DossierTabs(parsing: data))
    } catch let error as DossierError {
      return .failure(error)
    } catch {
      return .failure(.resourceUnreadable("fields.json: \(error.localizedDescription)"))
    }
  }()

  init(parsing data: Data) throws {
    let root = try Reader(try JSONValue.parse(data), at: "fields.json")
    guard let version = try root.value("formatVersion").intValue else { throw root.malformed("formatVersion") }
    formatVersion = Int(version)
    kinds = try root.strings("kinds")
    let page = try Reader(try root.value("page"), at: "page")
    pageBefore = try page.array("before").map(Field.init)
    pageAfter = try page.array("after").map(Field.init)
    tabs = try root.array("tabs").map(Tab.init)
  }
}

extension DossierTabs.Tab {
  fileprivate init(_ reader: Reader) throws {
    key = try reader.string("key")
    label = try reader.string("label")
    fields = try reader.array("fields").map(DossierTabs.Field.init)
  }
}

extension DossierTabs.Field {
  fileprivate init(_ reader: Reader) throws {
    key = try reader.string("key")
    label = try reader.string("label")
    kind = try reader.string("kind")
    emptyText = try reader.nullableString("emptyText")
    source = try reader.object("source")
    group = try reader.optionalString("group")
    textStyle = try reader.optionalString("textStyle")
    labelStyle = try reader.optionalString("labelStyle")
    labelVisible = try reader.optionalBool("labelVisible") ?? true
    wrap = reader.has("wrap") ? try reader.strings("wrap") : nil
    caption = reader.has("caption") ? try reader.object("caption") : nil
    overlay = reader.has("overlay") ? try reader.object("overlay") : nil
    row = reader.has("row") ? try reader.object("row") : nil
    role = try reader.optionalString("role")
    items = reader.has("items") ? try reader.array("items").map(DossierTabs.Item.init) : []
  }
}

extension DossierTabs.Item {
  fileprivate init(_ reader: Reader) throws {
    key = try reader.string("key")
    label = try reader.string("label")
    emptyText = try reader.nullableString("emptyText")
    source = try reader.object("source")
    note = try reader.optionalString("note")
  }
}

/// One object of `fields.json`, with failures that say where.
private struct Reader {
  let object: JSONObject
  let location: String

  init(_ value: JSONValue, at location: String) throws {
    guard let object = value.objectValue else {
      throw DossierError.resourceUnreadable("fields.json: \(location) isn't an object")
    }
    self.object = object
    self.location = object["key"]?.stringValue ?? location
  }

  func malformed(_ key: String) -> DossierError {
    .resourceUnreadable("fields.json: \(location).\(key) is missing or has the wrong type")
  }

  func has(_ key: String) -> Bool { object[key] != nil }

  func value(_ key: String) throws -> JSONValue {
    guard let value = object[key] else { throw malformed(key) }
    return value
  }

  func string(_ key: String) throws -> String {
    guard let text = try value(key).stringValue else { throw malformed(key) }
    return text
  }

  /// A key that must be present, whose value may be null.
  func nullableString(_ key: String) throws -> String? {
    let found = try value(key)
    if found == .null { return nil }
    guard let text = found.stringValue else { throw malformed(key) }
    return text
  }

  func optionalString(_ key: String) throws -> String? {
    has(key) ? try string(key) : nil
  }

  func optionalBool(_ key: String) throws -> Bool? {
    guard has(key) else { return nil }
    guard let flag = try value(key).boolValue else { throw malformed(key) }
    return flag
  }

  func object(_ key: String) throws -> JSONObject {
    guard let found = try value(key).objectValue else { throw malformed(key) }
    return found
  }

  func strings(_ key: String) throws -> [String] {
    guard let items = try value(key).arrayValue else { throw malformed(key) }
    return try items.map {
      guard let text = $0.stringValue else { throw malformed(key) }
      return text
    }
  }

  func array(_ key: String) throws -> [Reader] {
    guard let items = try value(key).arrayValue else { throw malformed(key) }
    return try items.map { try Reader($0, at: "\(location).\(key)") }
  }
}
