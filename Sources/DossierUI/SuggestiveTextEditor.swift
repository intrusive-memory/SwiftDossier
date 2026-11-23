import Observation
import SwiftUI

// MARK: - The host's side

/// Suggests the text of an empty box. The host app implements it (for example by asking a
/// language model); `DossierUI` only shows what it returns.
public protocol SuggestionProvider: Sendable {
  /// The suggested text for `request.field`. Throw to show the error's
  /// `localizedDescription` under the box instead.
  func suggest(_ request: SuggestionRequest) async throws -> String
}

/// What a ``SuggestionProvider`` is asked.
public struct SuggestionRequest: Sendable, Equatable {
  /// The box's field: a section's name in ``CharacterEditor`` and ``LocationEditor``, or a key
  /// the host chose for its own ``SuggestiveTextEditor``.
  public var field: String
  /// Suggestions already shown for this box and passed over with **Another suggestion**, oldest
  /// first. Empty on the first ask.
  public var rejected: [String]

  public init(field: String, rejected: [String] = []) {
    self.field = field
    self.rejected = rejected
  }
}

extension EnvironmentValues {
  /// The provider the section boxes of ``CharacterEditor`` and ``LocationEditor`` ask, and any
  /// ``SuggestiveTextEditor`` given no provider of its own. `nil` (the default) leaves every
  /// box a plain text editor.
  @Entry public var suggestionProvider: (any SuggestionProvider)? = nil
}

extension View {
  /// Sets the ``SuggestionProvider`` the boxes inside this view ask when they're emptied.
  public func suggestionProvider(_ provider: (any SuggestionProvider)?) -> some View {
    environment(\.suggestionProvider, provider)
  }
}

// MARK: - The model

/// The state of one box's suggestion (DossierUI #36). The view is thin: it reports focus and
/// text changes here and shows ``state``.
///
/// A box asks only when it is empty and loses focus. The suggestion is never put into the text
/// by the model: ``accept()`` hands it back for the view to commit like typed text.
@MainActor
@Observable
final class SuggestionModel {
  enum State: Equatable {
    case idle
    case asking
    case suggested(String)
    case failed(String)
  }

  let field: String
  private(set) var state: State = .idle
  /// Suggestions shown and passed over with ``another()``, oldest first.
  private(set) var rejected: [String] = []
  /// The ask in flight, if any.
  private(set) var task: Task<Void, Never>?
  /// Counts asks, so an answer to a cancelled or superseded ask is dropped.
  private var generation = 0

  init(field: String) {
    self.field = field
  }

  /// The suggestion on show, if any.
  var suggestion: String? {
    if case .suggested(let text) = state { return text }
    return nil
  }

  /// The box lost focus with `text` in it: ask when it's empty.
  func focusLost(text: String, provider: (any SuggestionProvider)?) {
    guard let provider, Self.isEmpty(text), state != .asking, suggestion == nil else { return }
    ask(provider)
  }

  /// The box's text changed. Anything typed drops the suggestion and the ask in flight.
  func textChanged(to text: String) {
    guard !Self.isEmpty(text) else { return }
    reset()
  }

  /// Takes the suggestion on show, for the view to commit. `nil` when there's none.
  func accept() -> String? {
    guard let text = suggestion else { return nil }
    reset()
    return text
  }

  /// Passes over the suggestion on show and asks for another.
  func another(provider: (any SuggestionProvider)?) {
    guard let provider, let text = suggestion else { return }
    rejected.append(text)
    ask(provider)
  }

  /// Waits for the ask in flight, if any. For tests.
  func settle() async {
    await task?.value
  }

  private func ask(_ provider: any SuggestionProvider) {
    task?.cancel()
    generation += 1
    let current = generation
    let request = SuggestionRequest(field: field, rejected: rejected)
    state = .asking
    task = Task { [weak self] in
      let result: Result<String, any Error>
      do {
        result = .success(try await provider.suggest(request))
      } catch {
        result = .failure(error)
      }
      guard let self, current == self.generation, !Task.isCancelled else { return }
      switch result {
      case .success(let text):
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.state = trimmed.isEmpty ? .idle : .suggested(trimmed)
      case .failure(let error):
        self.state = error is CancellationError ? .idle : .failed(error.localizedDescription)
      }
      self.task = nil
    }
  }

  private func reset() {
    generation += 1
    task?.cancel()
    task = nil
    rejected = []
    state = .idle
  }

  private static func isEmpty(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

// MARK: - The view

/// A text editor that suggests its own text when it's emptied (DossierUI #36).
///
/// When the box is empty and loses focus, it asks its ``SuggestionProvider`` and shows the
/// answer as dimmed text inside the box. **Tab** or **Accept** puts it in (and calls
/// `onAccept`, so the host commits it as it would typed text); **Another suggestion** asks
/// again; typing anything drops it. Nothing goes into `text` until it's accepted. A failed ask
/// shows its message under the box.
///
/// With no provider (neither `provider` nor ``EnvironmentValues/suggestionProvider``) it is a
/// plain `TextEditor`.
///
/// Accessibility identifiers, from `identifier`: the editor itself, then `.suggestion`,
/// `.accept`, `.another`, `.progress` and `.message`.
public struct SuggestiveTextEditor: View {
  @Binding private var text: String
  private let provider: (any SuggestionProvider)?
  private let identifier: String
  private let onAccept: ((String) -> Void)?
  private let onFocusLost: (() -> Void)?
  @Environment(\.suggestionProvider) private var environmentProvider
  @State private var model: SuggestionModel
  @FocusState private var focused: Bool

  /// - Parameters:
  ///   - text: The box's text.
  ///   - field: What the box holds, passed to the provider as ``SuggestionRequest/field``.
  ///   - provider: The provider to ask; `nil` uses the environment's.
  ///   - identifier: The editor's accessibility identifier; the suggestion's controls add a
  ///     suffix to it. Defaults to `field`.
  ///   - onAccept: Called with the text after a suggestion is put into the box.
  ///   - onFocusLost: Called when the box loses focus, before it asks for a suggestion (a
  ///     host commits typed text here).
  public init(
    text: Binding<String>, field: String, provider: (any SuggestionProvider)? = nil,
    identifier: String? = nil, onAccept: ((String) -> Void)? = nil,
    onFocusLost: (() -> Void)? = nil
  ) {
    _text = text
    self.provider = provider
    self.identifier = identifier ?? field
    self.onAccept = onAccept
    self.onFocusLost = onFocusLost
    _model = State(initialValue: SuggestionModel(field: field))
  }

  private var activeProvider: (any SuggestionProvider)? { provider ?? environmentProvider }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextEditor(text: $text)
        .focused($focused)
        .overlay(alignment: .topLeading) { ghost }
        .onKeyPress(.tab) {
          guard model.suggestion != nil, Self.isBlank(text) else { return .ignored }
          accept()
          return .handled
        }
        .onChange(of: focused) { _, now in
          guard !now else { return }
          onFocusLost?()
          model.focusLost(text: text, provider: activeProvider)
        }
        .onChange(of: text) { _, new in
          // A text view that inserts the Tab itself, rather than passing the key press on.
          if model.suggestion != nil, new.contains("\t"), Self.isBlank(new) {
            accept()
          } else {
            model.textChanged(to: new)
          }
        }
        .accessibilityIdentifier(identifier)
      controls
    }
  }

  @ViewBuilder private var ghost: some View {
    if let suggestion = model.suggestion, Self.isBlank(text) {
      Text(suggestion)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 5)
        .allowsHitTesting(false)
        .accessibilityLabel("Suggestion: \(suggestion)")
        .accessibilityIdentifier("\(identifier).suggestion")
    }
  }

  @ViewBuilder private var controls: some View {
    switch model.state {
    case .idle:
      EmptyView()
    case .asking:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Suggesting…").font(.caption).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("\(identifier).progress")
    case .suggested:
      HStack(spacing: 12) {
        Button("Accept", action: accept)
          .accessibilityIdentifier("\(identifier).accept")
        Button {
          model.another(provider: activeProvider)
        } label: {
          Label("Another suggestion", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("\(identifier).another")
        Text("Tab to accept").font(.caption).foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .font(.caption)
    case .failed(let message):
      Text(message).font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("\(identifier).message")
    }
  }

  private static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func accept() {
    guard let suggestion = model.accept() else { return }
    text = suggestion
    onAccept?(suggestion)
  }
}
