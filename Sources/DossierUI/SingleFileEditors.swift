import SwiftUI

/// A character file's editor over the host's text (SFV-9). It reads and writes no file: every
/// change is made through the model (see ``SingleFileEditorModel``) and then set on `text`.
///
/// The writable fields are the front-matter keys `fields.json` takes plus `role`; every other key is
/// listed read-only. There is one editor for each §9.2 section.
public struct CharacterEditor: View {
  /// The label and SF Symbol for hosts (SFV-3).
  public static let identity = SingleFileViewIdentity.characterEditor
  public var identity: SingleFileViewIdentity { Self.identity }

  @Binding private var text: String
  @State private var model: SingleFileEditorModel
  private let context: SingleFileContext

  public init(text: Binding<String>, context: SingleFileContext = SingleFileContext()) {
    _text = text
    _model = State(initialValue: .character(text: text.wrappedValue))
    self.context = context
  }

  public var body: some View {
    SingleFileEditorForm(model: model, text: $text, idPrefix: "character", context: context)
  }
}

/// A location file's editor over the host's text (SFV-10). Writable keys are `location` and
/// `theme`; the sections are the file's own plus Blocking and Views.
public struct LocationEditor: View {
  /// The label and SF Symbol for hosts (SFV-3).
  public static let identity = SingleFileViewIdentity.locationEditor
  public var identity: SingleFileViewIdentity { Self.identity }

  @Binding private var text: String
  @State private var model: SingleFileEditorModel
  private let context: SingleFileContext

  public init(text: Binding<String>, context: SingleFileContext = SingleFileContext()) {
    _text = text
    _model = State(initialValue: .location(text: text.wrappedValue))
    self.context = context
  }

  public var body: some View {
    SingleFileEditorForm(model: model, text: $text, idPrefix: "location", context: context)
  }
}

/// The form both editors draw. All logic is in the model.
private struct SingleFileEditorForm: View {
  let model: SingleFileEditorModel
  @Binding var text: String
  let idPrefix: String
  let context: SingleFileContext

  var body: some View {
    Form {
      if let problem = model.problem {
        Text(problem).foregroundStyle(.red)
          .accessibilityIdentifier("\(idPrefix).editor.problem")
      } else {
        Section("Front matter") {
          ForEach(model.fields) { row in
            FieldRow(row: row, error: model.fieldErrors[row.key]) { value in
              model.setField(row.key, to: value) { text = $0 }
            }
          }
        }
        Section("Sections") {
          ForEach(model.sections) { row in
            SectionRow(row: row, error: model.sectionErrors[row.name]) { value in
              model.setSection(row.name, to: value) { text = $0 }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("\(idPrefix).editor")
    // The host edited the text elsewhere (its plain-text mode): rebuild from it.
    .onChange(of: text) { _, new in model.reload(text: new) }
    .onAppear { model.reload(text: text) }
  }
}

private struct FieldRow: View {
  let row: EditorFieldRow
  let error: String?
  let commit: (String) -> Bool
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if row.isWritable {
        TextField(row.isList ? "\(row.label) (comma-separated)" : row.label, text: $draft)
          .focused($focused)
          .onSubmit { _ = commit(draft) }
          .onChange(of: focused) { _, now in if !now { _ = commit(draft) } }
          .accessibilityIdentifier("field.\(row.key)")
      } else {
        // Read-only rows carry the same identifier as writable ones, so the key's value is
        // reachable (the `character` key is always read-only). It goes on the value's own text:
        // macOS reports an empty value for a SwiftUI element built over the whole row.
        LabeledContent {
          Text(row.value).accessibilityIdentifier("field.\(row.key)")
        } label: {
          Text(row.label)
        }
        if let reason = row.readOnlyReason {
          Text(reason).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .onAppear { draft = row.value }
    .onChange(of: row.value) { _, new in draft = new }
  }
}

private struct SectionRow: View {
  let row: EditorSectionRow
  let error: String?
  let commit: (String) -> Bool
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.exists ? row.name : "\(row.name) (not in the file yet)").font(.headline)
      // Suggests the section's text when it's emptied, if the host set a provider (#36).
      SuggestiveTextEditor(
        text: $draft, field: row.name, identifier: "section.\(row.name)",
        onAccept: { _ = commit($0) }, onFocusLost: { _ = commit(draft) }
      )
      .frame(minHeight: 60)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .onAppear { draft = row.content }
    .onChange(of: row.content) { _, new in draft = new }
  }
}
