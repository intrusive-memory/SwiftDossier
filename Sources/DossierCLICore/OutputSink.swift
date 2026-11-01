import Foundation

/// Where a command's output goes. Every byte a command produces leaves through this
/// protocol, never through a global stream, so a test can drive a command in-process and
/// read both channels apart.
public protocol OutputSink: Sendable {
  /// Writes to standard output, exactly as given. No newline is added.
  func writeOutput(_ text: String)
  /// Writes to standard error, exactly as given. No newline is added.
  func writeError(_ text: String)
}

/// The sink the `dossier` executable runs with: the real standard output and standard error.
public struct ConsoleOutputSink: OutputSink {
  /// Creates the real sink.
  public init() {}

  /// Writes `text` to the real standard output.
  public func writeOutput(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }

  /// Writes `text` to the real standard error.
  public func writeError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
  }
}
