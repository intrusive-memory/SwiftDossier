import Foundation
import Testing

@testable import DossierUI

/// A provider that answers from a list and records what it was asked.
actor StubSuggestionProvider: SuggestionProvider {
  enum Failure: LocalizedError {
    case noKey
    var errorDescription: String? { "No API key is set." }
  }

  private var answers: [Result<String, Failure>]
  private(set) var requests: [SuggestionRequest] = []

  init(_ answers: [Result<String, Failure>]) {
    self.answers = answers
  }

  func suggest(_ request: SuggestionRequest) async throws -> String {
    requests.append(request)
    guard !answers.isEmpty else { return "" }
    return try answers.removeFirst().get()
  }
}

/// A provider that waits until it's told to answer, so a test can act while an ask is in flight.
actor GatedSuggestionProvider: SuggestionProvider {
  private var continuation: CheckedContinuation<String, Never>?
  private(set) var asked = 0

  func suggest(_ request: SuggestionRequest) async throws -> String {
    asked += 1
    return await withCheckedContinuation { continuation = $0 }
  }

  func answer(_ text: String) {
    continuation?.resume(returning: text)
    continuation = nil
  }
}

@MainActor
@Suite("SuggestionModelTests")
struct SuggestionModelTests {

  @Test func anEmptyBoxThatLosesFocusAsksAndShowsTheSuggestion() async {
    let provider = StubSuggestionProvider([.success("  Fifties, bottle blonde.\n")])
    let model = SuggestionModel(field: "Appearance")
    model.focusLost(text: " \n", provider: provider)
    #expect(model.state == .asking)
    await model.settle()
    #expect(model.state == .suggested("Fifties, bottle blonde."))
    #expect(await provider.requests == [SuggestionRequest(field: "Appearance")])
  }

  @Test func aBoxWithTextDoesNotAsk() async {
    let provider = StubSuggestionProvider([.success("unused")])
    let model = SuggestionModel(field: "Logline")
    model.focusLost(text: "A crime anthology.", provider: provider)
    await model.settle()
    #expect(model.state == .idle)
    #expect(await provider.requests.isEmpty)
  }

  @Test func withNoProviderNothingIsAsked() async {
    let model = SuggestionModel(field: "Logline")
    model.focusLost(text: "", provider: nil)
    #expect(model.state == .idle)
    #expect(model.task == nil)
  }

  @Test func acceptHandsTheSuggestionBackAndClears() async {
    let provider = StubSuggestionProvider([.success("One sentence.")])
    let model = SuggestionModel(field: "Logline")
    model.focusLost(text: "", provider: provider)
    await model.settle()
    #expect(model.accept() == "One sentence.")
    #expect(model.state == .idle)
    #expect(model.accept() == nil)
  }

  @Test func anotherSuggestionPassesTheRejectedOnes() async {
    let provider = StubSuggestionProvider([.success("First."), .success("Second."), .success("Third.")])
    let model = SuggestionModel(field: "Personality")
    model.focusLost(text: "", provider: provider)
    await model.settle()
    model.another(provider: provider)
    await model.settle()
    model.another(provider: provider)
    await model.settle()
    #expect(model.state == .suggested("Third."))
    #expect(
      await provider.requests.map(\.rejected) == [[], ["First."], ["First.", "Second."]])
  }

  @Test func typingDropsTheSuggestionAndTheRejectedList() async {
    let provider = StubSuggestionProvider([.success("First."), .success("Second.")])
    let model = SuggestionModel(field: "Personality")
    model.focusLost(text: "", provider: provider)
    await model.settle()
    model.another(provider: provider)
    await model.settle()
    model.textChanged(to: "My own words")
    #expect(model.state == .idle)
    #expect(model.rejected.isEmpty)
  }

  @Test func typingWhileAskingDropsTheLateAnswer() async {
    let provider = GatedSuggestionProvider()
    let model = SuggestionModel(field: "Backstory")
    model.focusLost(text: "", provider: provider)
    while await provider.asked == 0 { await Task.yield() }
    model.textChanged(to: "Typed first")
    await provider.answer("Too late.")
    await model.settle()
    #expect(model.state == .idle)
  }

  @Test func blankAnswersShowNothing() async {
    let provider = StubSuggestionProvider([.success("   ")])
    let model = SuggestionModel(field: "Arc")
    model.focusLost(text: "", provider: provider)
    await model.settle()
    #expect(model.state == .idle)
  }

  @Test func aFailedAskShowsItsMessage() async {
    let provider = StubSuggestionProvider([.failure(.noKey)])
    let model = SuggestionModel(field: "Wardrobe")
    model.focusLost(text: "", provider: provider)
    await model.settle()
    #expect(model.state == .failed("No API key is set."))
  }

  @Test func losingFocusAgainKeepsTheSuggestionOnShow() async {
    let provider = StubSuggestionProvider([.success("Kept."), .success("Not asked for.")])
    let model = SuggestionModel(field: "Logline")
    model.focusLost(text: "", provider: provider)
    await model.settle()
    model.focusLost(text: "", provider: provider)
    await model.settle()
    #expect(model.state == .suggested("Kept."))
    #expect(await provider.requests.count == 1)
  }
}
