import Foundation

/// What the preview web view does with a navigation (PV-22). The decision is pure: the web view
/// only applies it.
public enum PreviewNavigation {
  public enum Policy: Equatable, Sendable {
    /// Follow it: it is the page itself, or a fragment on it.
    case allow
    /// Cancel it in the web view and hand it to the system (default browser or mail app).
    case openExternally
    /// Drop it.
    case cancel
  }

  /// Whether a navigation to `url` may go ahead in a web view showing `page`.
  ///
  /// - The page itself, and fragments on it, are allowed. For in-memory HTML, `page` is
  ///   `about:blank`; other `about:` URLs are not the page and are cancelled.
  /// - `http`, `https` and `mailto` open outside the viewer.
  /// - Everything else is cancelled, including other files in the bundle, `file:` URLs elsewhere,
  ///   `javascript:` and `data:`.
  public static func policy(for url: URL, page: URL) -> Policy {
    if isSamePage(url, page) { return .allow }
    switch url.scheme?.lowercased() {
    case "http", "https", "mailto": return .openExternally
    default: return .cancel
    }
  }

  private static func isSamePage(_ url: URL, _ page: URL) -> Bool {
    guard let a = withoutFragment(url), let b = withoutFragment(page) else { return false }
    if a.isFileURL, b.isFileURL {
      return a.resolvingSymlinksInPath().standardizedFileURL.path
        == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
    return a.absoluteString == b.absoluteString
  }

  private static func withoutFragment(_ url: URL) -> URL? {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    parts.fragment = nil
    return parts.url
  }
}
