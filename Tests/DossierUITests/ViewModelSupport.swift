import CoreGraphics
import Dossier
import DossierCore
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import DossierUI

/// A bundle in a temporary directory, made through the public API. Invented characters only.
struct UIProject {
  static let character = "THE TINKER"
  let root: URL
  var bundleURL: URL { root.appendingPathComponent("characters/\(Self.character).dossier", isDirectory: true) }
  var descriptionURL: URL { bundleURL.appendingPathComponent("CHARACTER.md") }
  var storeURL: URL { bundleURL.appendingPathComponent(".preview", isDirectory: true) }

  static let made = Date(timeIntervalSince1970: 1_790_000_000)

  /// A bundle with a selected `CHARACTER.md`, or none when `description` is `nil`.
  init(description: String? = "---\ntype: character\ncharacter: \(UIProject.character)\n---\n\n## Logline\n\nA tinker who mends radios.\n") throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DossierUITests-\(UUID().uuidString)", isDirectory: true)
    let characters = root.appendingPathComponent("characters", isDirectory: true)
    try FileManager.default.createDirectory(at: characters, withIntermediateDirectories: true)
    try DossierBundle.create(character: Self.character, role: "lead", in: characters)
    if let description {
      let file = root.appendingPathComponent("CHARACTER.md")
      try Data(description.utf8).write(to: file)
      defer { try? FileManager.default.removeItem(at: file) }
      var bundle = try open()
      try bundle.add(file, kind: .description, options: options(select: true))
    }
  }

  func open() throws -> DossierBundle { try DossierBundle.open(at: bundleURL) }

  /// Builds and stores the preview, as another viewer would have.
  @discardableResult
  func storePreview() throws -> PreviewResult {
    try DossierBundle.openForPreview(at: bundleURL, cast: nil).showPreview()
  }

  /// Adds a synthetic PNG portrait, selected.
  @discardableResult
  func addPortrait() throws -> Asset {
    let file = root.appendingPathComponent("image-\(UUID().uuidString).png")
    try Self.png(width: 18, height: 32).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    var bundle = try open()
    return try bundle.add(file, kind: .portrait, options: options(select: true))
  }

  private func options(select: Bool) -> AddOptions {
    AddOptions(provenance: JSONObject([("provider", .string("manual"))]), createdAt: Self.made, select: select)
  }

  static func png(width: Int, height: Int) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }
}

/// The library's builder, counting its calls and able to hold a call open until it's released.
final class RecordingBuilder: PreviewBuilding {
  enum Call: Hashable, Sendable {
    case build(String)
    case rebuild(String)

    static func build(_ url: URL) -> Call { .build(RecordingBuilder.path(url)) }
    static func rebuild(_ url: URL) -> Call { .rebuild(RecordingBuilder.path(url)) }
  }

  private struct Gates {
    var calls: [Call] = []
    var held: Set<Call>
    var released: Set<Call> = []
    var waiting: [Call: [CheckedContinuation<Void, Never>]] = [:]
    var startWaiters: [Call: [CheckedContinuation<Void, Never>]] = [:]
  }

  private let gates: Mutex<Gates>
  private let real = DossierPreviewBuilder()

  /// - Parameter holding: Calls that wait for ``release(_:)`` before they run.
  init(holding: Set<Call> = []) {
    gates = Mutex(Gates(held: holding))
  }

  var calls: [Call] { gates.withLock { $0.calls } }

  func release(_ call: Call) {
    let waiters = gates.withLock { gates in
      gates.released.insert(call)
      return gates.waiting.removeValue(forKey: call) ?? []
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Waits until `call` has started.
  func waitUntilStarted(_ call: Call) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let goNow = gates.withLock { gates -> Bool in
        if gates.calls.contains(call) { return true }
        gates.startWaiters[call, default: []].append(continuation)
        return false
      }
      if goNow { continuation.resume() }
    }
  }

  func build(_ bundle: DossierBundle) async throws -> PreviewResult {
    await pass(.build(bundle.url))
    return try await real.build(bundle)
  }

  func rebuild(_ bundle: DossierBundle, cast: URL?) async throws -> RebuildResult {
    await pass(.rebuild(bundle.url))
    return try await real.rebuild(bundle, cast: cast)
  }

  private func pass(_ call: Call) async {
    let startWaiters = gates.withLock { gates in
      gates.calls.append(call)
      return gates.startWaiters.removeValue(forKey: call) ?? []
    }
    for waiter in startWaiters { waiter.resume() }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let goNow = gates.withLock { gates -> Bool in
        guard gates.held.contains(call), !gates.released.contains(call) else { return true }
        gates.waiting[call, default: []].append(continuation)
        return false
      }
      if goNow { continuation.resume() }
    }
  }

  static func path(_ url: URL) -> String { url.standardizedFileURL.path }
}

/// The states a view model goes through, by name.
@MainActor
final class StateLog {
  private(set) var names: [String]

  init(_ model: DossierViewModel) {
    names = [Self.name(model.state)]
    model.onStateChange = { [weak self] state in self?.names.append(Self.name(state)) }
  }

  static func name(_ state: DossierViewModel.State) -> String {
    switch state {
    case .updating: return "updating"
    case .loading: return "loading"
    case .page: return "page"
    case .rebuilding: return "rebuilding"
    case .failed: return "failed"
    }
  }
}

extension DossierViewModel.State {
  var page: PreviewResult? {
    if case .page(let result) = self { return result }
    return nil
  }

  var failure: DossierViewModel.FailureReason? {
    if case .failed(let reason) = self { return reason }
    return nil
  }
}
