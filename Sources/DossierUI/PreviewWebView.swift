import SwiftUI
import WebKit

/// What a ``PreviewWebView`` shows.
public enum PreviewContent: Equatable, Sendable {
  /// A stored page: `<bundle>/.preview/<key>.html`. Read access is `<bundle>/.preview/` only.
  case stored(page: URL, bundleURL: URL)
  /// A stored page outside a bundle, such as the LOCATIONS page `<index directory>/.locations-page/<key>.html`
  /// (§16.6). Read access is `readAccess` only: for the LOCATIONS page, `<index directory>/.locations-page/`.
  case storedPage(page: URL, readAccess: URL)
  /// Built HTML held in memory (PV-23), loaded with no base URL (its own URL is `about:blank`).
  case html(String)

  var pageURL: URL {
    switch self {
    case .stored(let page, _): return page
    case .storedPage(let page, _): return page
    case .html: return URL(string: "about:blank")!
    }
  }
}

/// The name the template posts its DF-51 messages to (`template/dossier.js`:
/// `window.webkit.messageHandlers.dossier`). The body is the clicked element's key.
let previewMessageHandlerName = "dossier"

/// A thin `WKWebView` wrapper. Every navigation decision goes through ``PreviewNavigation``.
public struct PreviewWebView {
  let content: PreviewContent
  let section: String?
  let onMessage: ((String, Any) -> Void)?

  /// - Parameters:
  ///   - content: What to show.
  ///   - section: The `id` of a LOCATIONS page section (§16.7) to scroll to once the page has
  ///     loaded, or `nil` for the top of the page. Changing only this scrolls; it never reloads.
  ///     An id that isn't `location-` and eight lowercase hex digits is ignored.
  ///   - onMessage: Called with each DF-51 message the page posts.
  public init(
    content: PreviewContent, section: String? = nil, onMessage: ((String, Any) -> Void)? = nil
  ) {
    self.content = content
    self.section = section
    self.onMessage = onMessage
  }

  /// The script that scrolls to `section`, or `nil` when there is none or it isn't a §16.7 section
  /// id (`^location-[0-9a-f]{8}$`). Only a validated id is put into the script.
  static func scrollScript(for section: String?) -> String? {
    guard let section, isSectionID(section) else { return nil }
    return "document.getElementById('\(section)')?.scrollIntoView()"
  }

  /// The script a change of `section` alone runs: the top of the page for `nil`, else
  /// ``scrollScript(for:)``.
  static func sectionChangeScript(for section: String?) -> String? {
    guard let section else { return "window.scrollTo(0, 0)" }
    return scrollScript(for: section)
  }

  /// Whether `id` matches `^location-[0-9a-f]{8}$`.
  static func isSectionID(_ id: String) -> Bool {
    let prefix = "location-"
    guard id.hasPrefix(prefix) else { return false }
    let hex = id.utf8.dropFirst(prefix.utf8.count)
    return hex.count == 8 && hex.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  @MainActor
  public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var onMessage: ((String, Any) -> Void)?
    var pageURL: URL
    var loaded: PreviewContent?
    /// The section to scroll to after the current load finishes, or now when no load is running.
    var section: String?
    /// Whether a load started by ``PreviewWebView/load(into:context:)`` hasn't finished yet.
    var isLoading = false

    init(pageURL: URL, onMessage: ((String, Any) -> Void)?) {
      self.pageURL = pageURL
      self.onMessage = onMessage
    }

    public func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      guard let url = navigationAction.request.url else { return .cancel }
      switch PreviewNavigation.policy(for: url, page: pageURL) {
      case .allow: return .allow
      case .cancel: return .cancel
      case .openExternally:
        Self.openExternally(url)
        return .cancel
      }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      isLoading = false
      scroll(webView)
    }

    public func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
      isLoading = false
    }

    public func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      isLoading = false
    }

    /// Scrolls to ``section`` when it is a valid section id; otherwise does nothing. A load
    /// already starts at the top.
    func scroll(_ webView: WKWebView) {
      guard let script = PreviewWebView.scrollScript(for: section) else { return }
      webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Scrolls for a change of ``section`` on a loaded page: to the section, or to the top for
    /// `nil`.
    func scrollForSectionChange(_ webView: WKWebView) {
      guard let script = PreviewWebView.sectionChangeScript(for: section) else { return }
      webView.evaluateJavaScript(script, completionHandler: nil)
    }

    public func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      onMessage?(message.name, message.body)
    }

    private static func openExternally(_ url: URL) {
      #if os(macOS)
        NSWorkspace.shared.open(url)
      #else
        UIApplication.shared.open(url)
      #endif
    }
  }

  @MainActor
  public func makeCoordinator() -> Coordinator {
    Coordinator(pageURL: content.pageURL, onMessage: onMessage)
  }

  @MainActor
  func makeWebView(_ context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.userContentController.add(context.coordinator, name: previewMessageHandlerName)
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    load(into: webView, context: context)
    return webView
  }

  @MainActor
  func load(into webView: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onMessage = onMessage
    let sectionChanged = coordinator.section != section
    coordinator.section = section
    guard coordinator.loaded != content else {
      // Same page: a new section scrolls now, or when the running load finishes. No reload.
      if sectionChanged, !coordinator.isLoading { coordinator.scrollForSectionChange(webView) }
      return
    }
    coordinator.loaded = content
    coordinator.pageURL = content.pageURL
    coordinator.isLoading = true
    switch content {
    case .stored(let page, let bundleURL):
      let previewDirectory = bundleURL.appendingPathComponent(".preview", isDirectory: true)
      webView.loadFileURL(page, allowingReadAccessTo: previewDirectory)
    case .storedPage(let page, let readAccess):
      webView.loadFileURL(page, allowingReadAccessTo: readAccess)
    case .html(let html):
      webView.loadHTMLString(html, baseURL: nil)
    }
  }

  @MainActor
  static func tearDown(_ webView: WKWebView) {
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: previewMessageHandlerName)
    webView.navigationDelegate = nil
  }
}

#if os(macOS)
  extension PreviewWebView: NSViewRepresentable {
    public func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    public func updateNSView(_ webView: WKWebView, context: Context) {
      load(into: webView, context: context)
    }
    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
      tearDown(webView)
    }
  }
#else
  extension PreviewWebView: UIViewRepresentable {
    public func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    public func updateUIView(_ webView: WKWebView, context: Context) {
      load(into: webView, context: context)
    }
    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
      tearDown(webView)
    }
  }
#endif
