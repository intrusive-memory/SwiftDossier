import Foundation
import Testing

@testable import DossierUI

@Suite
struct PreviewWebViewContentTests {
  let store = URL(fileURLWithPath: "/tmp/project/.locations-page", isDirectory: true)
  var page: URL { store.appendingPathComponent("abc.html") }

  @Test func storedPageEqualityFollowsPageAndReadAccess() {
    let other = store.appendingPathComponent("def.html")
    #expect(PreviewContent.storedPage(page: page, readAccess: store) == .storedPage(page: page, readAccess: store))
    #expect(PreviewContent.storedPage(page: page, readAccess: store) != .storedPage(page: other, readAccess: store))
    #expect(
      PreviewContent.storedPage(page: page, readAccess: store)
        != .storedPage(page: page, readAccess: store.deletingLastPathComponent()))
    #expect(
      PreviewContent.storedPage(page: page, readAccess: store)
        != .stored(page: page, bundleURL: store.deletingLastPathComponent()))
    #expect(PreviewContent.storedPage(page: page, readAccess: store).pageURL == page)
  }

  @MainActor
  @Test func aSectionOnlyChangeKeepsTheContent() {
    let content = PreviewContent.storedPage(page: page, readAccess: store)
    let first = PreviewWebView(content: content, section: "location-0123abcd")
    let second = PreviewWebView(content: content, section: "location-89abcdef")
    #expect(first.content == second.content)
    #expect(first.section != second.section)
  }

  @Test func aValidSectionIDGivesTheScrollScript() {
    #expect(
      PreviewWebView.scrollScript(for: "location-0123abcd")
        == "document.getElementById('location-0123abcd')?.scrollIntoView()")
  }

  @Test(arguments: [
    "location-0123ABCD", "location-0123abc", "location-0123abcde", "location-0123abcg",
    "Location-0123abcd", "x-location-0123abcd", "location-', alert(1), '", "location-0123abc'",
    "", "location-",
  ])
  func idsThatDontMatchAreRefused(_ id: String) {
    #expect(!PreviewWebView.isSectionID(id))
    #expect(PreviewWebView.scrollScript(for: id) == nil)
  }

  @Test func noSectionHasNoScript() {
    #expect(PreviewWebView.scrollScript(for: nil) == nil)
  }

  @Test func aChangeToNoSectionScrollsToTheTop() {
    #expect(PreviewWebView.sectionChangeScript(for: nil) == "window.scrollTo(0, 0)")
    #expect(
      PreviewWebView.sectionChangeScript(for: "location-0123abcd")
        == PreviewWebView.scrollScript(for: "location-0123abcd"))
    #expect(PreviewWebView.sectionChangeScript(for: "location-', alert(1), '") == nil)
  }
}
