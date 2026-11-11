import Foundation
import Testing

@testable import DossierUI

@Suite
struct PreviewNavigationTests {
  let bundle = URL(fileURLWithPath: "/tmp/HUNTER.dossier", isDirectory: true)
  var page: URL { bundle.appendingPathComponent(".preview/abc.html") }

  @Test func thePageIsAllowed() {
    #expect(PreviewNavigation.policy(for: page, page: page) == .allow)
  }

  @Test func aFragmentOnThePageIsAllowed() throws {
    let url = try #require(URL(string: page.absoluteString + "#profile"))
    #expect(PreviewNavigation.policy(for: url, page: page) == .allow)
  }

  @Test func anotherFileInTheBundleIsCancelled() {
    let url = bundle.appendingPathComponent("images/x.png")
    #expect(PreviewNavigation.policy(for: url, page: page) == .cancel)
  }

  @Test func aFileOutsideTheBundleIsCancelled() {
    #expect(PreviewNavigation.policy(for: URL(string: "file:///etc/passwd")!, page: page) == .cancel)
  }

  @Test func httpsOpensExternally() {
    #expect(
      PreviewNavigation.policy(for: URL(string: "https://example.com")!, page: page)
        == .openExternally)
  }

  @Test func httpOpensExternally() {
    #expect(
      PreviewNavigation.policy(for: URL(string: "http://example.com/a")!, page: page)
        == .openExternally)
  }

  @Test func mailtoOpensExternally() {
    #expect(
      PreviewNavigation.policy(for: URL(string: "mailto:a@b.c")!, page: page) == .openExternally)
  }

  @Test func javascriptAndDataAreCancelled() {
    #expect(PreviewNavigation.policy(for: URL(string: "javascript:alert(1)")!, page: page) == .cancel)
    #expect(
      PreviewNavigation.policy(for: URL(string: "data:text/html,<b>x</b>")!, page: page) == .cancel)
  }

  @Test func inMemoryPageAllowsAboutBlankAndItsFragments() {
    let blank = URL(string: "about:blank")!
    #expect(PreviewNavigation.policy(for: blank, page: blank) == .allow)
    #expect(PreviewNavigation.policy(for: URL(string: "about:blank#profile")!, page: blank) == .allow)
  }

  @Test func otherAboutURLsAreCancelled() {
    let blank = URL(string: "about:blank")!
    #expect(PreviewNavigation.policy(for: URL(string: "about:srcdoc")!, page: blank) == .cancel)
  }

  @Test func inMemoryPageStillOpensLinksExternally() {
    let blank = URL(string: "about:blank")!
    #expect(
      PreviewNavigation.policy(for: URL(string: "https://example.com")!, page: blank)
        == .openExternally)
  }
}
