import SwiftUI
import WebKit

/// What a ``PreviewWebView`` shows.
public enum PreviewContent: Equatable, Sendable {
  /// A stored page: `<bundle>/.preview/<key>.html`. Read access is `<bundle>/.preview/` only.
  case stored(page: URL, bundleURL: URL)
  /// Built HTML held in memory (PV-23), loaded with no base URL (its own URL is `about:blank`).
  case html(String)

  var pageURL: URL {
    switch self {
    case .stored(let page, _): return page
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
  let onMessage: ((String, Any) -> Void)?

  public init(content: PreviewContent, onMessage: ((String, Any) -> Void)? = nil) {
    self.content = content
    self.onMessage = onMessage
  }

  @MainActor
  public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var onMessage: ((String, Any) -> Void)?
    var pageURL: URL
    var loaded: PreviewContent?

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
    guard coordinator.loaded != content else { return }
    coordinator.loaded = content
    coordinator.pageURL = content.pageURL
    switch content {
    case .stored(let page, let bundleURL):
      let previewDirectory = bundleURL.appendingPathComponent(".preview", isDirectory: true)
      webView.loadFileURL(page, allowingReadAccessTo: previewDirectory)
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
