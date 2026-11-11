import ArgumentParser
import Dossier
import DossierCore
import Foundation

/// A failure a command reports itself, with the exit status it asks for.
struct CLIFailure: Error {
  /// A short stable name, for the `--json` error object.
  let code: String
  /// For people.
  let message: String
  /// The process exit status.
  let status: Int32

  init(_ code: String, _ message: String, status: Int32 = 1) {
    self.code = code
    self.message = message
    self.status = status
  }
}

/// What every subcommand takes.
struct OutputOptions: ParsableArguments {
  @Flag(name: .long, help: "Print one JSON object on standard output; errors as {\"error\": {...}}.")
  var json = false
}

/// A subcommand that runs in-process against a sink.
protocol DossierSubcommand: ParsableCommand {
  var output: OutputOptions { get }
  /// The exit status for a thrown error that isn't a ``CLIFailure``.
  static var failureStatus: Int32 { get }
  /// Runs the command, writing only through `io`, and returns the exit status.
  func execute(io: CommandIO) throws -> Int32
}

extension DossierSubcommand {
  static var failureStatus: Int32 { 1 }
}

/// A subcommand that suspends. The synchronous ``DossierCLI/run(_:sink:)`` refuses it
/// (`async-required`); the `async` one runs it.
protocol AsyncDossierSubcommand: DossierSubcommand {
  func executeAsync(io: CommandIO) async throws -> Int32
}

/// A command's way out: the sink, and whether it speaks JSON.
struct CommandIO {
  let sink: any OutputSink
  let json: Bool

  /// A line on standard output.
  func line(_ text: String) { sink.writeOutput(text + "\n") }
  /// A line on standard error.
  func note(_ text: String) { sink.writeError(text + "\n") }

  /// The one JSON object of a `--json` run.
  func emit(_ object: [String: Any]) {
    sink.writeOutput(JSONOut.string(object) + "\n")
  }
}

/// Foundation-side JSON for output.
enum JSONOut {
  static func string(_ object: [String: Any]) -> String {
    let data = try? JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  /// A package JSON value as a Foundation one.
  static func foundation(_ value: JSONValue) -> Any {
    let data = Data(("[" + value.canonicalEncoded() + "]").utf8)
    let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    return array?.first ?? NSNull()
  }

  static func foundation(_ object: JSONObject) -> Any { foundation(.object(object)) }
}

/// The in-process entry to the CLI: `main.swift` calls it with the real sink, tests with a buffer.
public enum DossierCLI {
  /// Runs the command line `arguments` (without the executable's name).
  ///
  /// - Returns: The exit status. `validate` gives 0 clean, 1 warnings only, 2 errors; `update run`
  ///   its command's; the other commands give 0 or 1; a bad command line gives ArgumentParser's own.
  public static func run(_ arguments: [String], sink: any OutputSink) -> Int32 {
    var failureStatus: Int32 = 1
    do {
      guard let command = try parse(arguments, sink: sink) else { return 0 }
      failureStatus = type(of: command).failureStatus
      return try command.execute(io: CommandIO(sink: sink, json: command.output.json))
    } catch {
      return fail(error, arguments: arguments, failureStatus: failureStatus, sink: sink)
    }
  }

  /// ``run(_:sink:)`` for a caller that can `await`: it also runs a command that suspends, such as
  /// `preview --rebuild`, without blocking a thread. `main.swift` calls this one.
  public static func run(_ arguments: [String], sink: any OutputSink) async -> Int32 {
    var failureStatus: Int32 = 1
    do {
      guard let command = try parse(arguments, sink: sink) else { return 0 }
      failureStatus = type(of: command).failureStatus
      let io = CommandIO(sink: sink, json: command.output.json)
      if let asynchronous = command as? any AsyncDossierSubcommand {
        return try await asynchronous.executeAsync(io: io)
      }
      return try command.execute(io: io)
    } catch {
      return fail(error, arguments: arguments, failureStatus: failureStatus, sink: sink)
    }
  }

  /// The parsed subcommand, or `nil` after writing help.
  private static func parse(_ arguments: [String], sink: any OutputSink) throws -> (any DossierSubcommand)? {
    let parsed = try DossierCommand.parseAsRoot(arguments)
    guard let command = parsed as? any DossierSubcommand else {
      // `add --help` parses as ArgumentParser's own help command, whose type says nothing about
      // which command was asked about, so the command line has to say.
      sink.writeOutput(DossierCommand.helpMessage(for: helpTarget(arguments)) + "\n")
      return nil
    }
    return command
  }

  private static func fail(_ error: Error, arguments: [String], failureStatus: Int32, sink: any OutputSink) -> Int32 {
    let json = arguments.prefix { $0 != "--" }.contains("--json")
    if let failure = error as? CLIFailure {
      report(code: failure.code, message: failure.message, json: json, sink: sink)
      return failure.status
    }
    let status = DossierCommand.exitCode(for: error)
    let message = DossierCommand.message(for: error)
    if status == .success {
      sink.writeOutput(message + "\n")
      return 0
    }
    if status == .validationFailure {
      report(code: "usage", message: message, json: json, sink: sink)
      return status.rawValue
    }
    let described = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    let name = String(String(describing: error).prefix { $0 != "(" })
    var paths: [String]?
    if case DossierWriteError.assetFilesMissing(let missing) = error { paths = missing }
    report(code: name, message: described, paths: paths, json: json, sink: sink)
    return failureStatus
  }

  /// The command a help request is about: `add --help`, `help add`, `update run -h`, or `update`.
  /// The path of subcommand names on the command line, stopping at the first word that isn't one.
  static func helpTarget(_ arguments: [String]) -> any ParsableCommand.Type {
    var target: any ParsableCommand.Type = DossierCommand.self
    var words = arguments.prefix { $0 != "--" }.filter { !$0.hasPrefix("-") }[...]
    if words.first == "help" { words = words.dropFirst() }
    for word in words {
      let next = target.configuration.subcommands.first { command in
        command._commandName == word || command.configuration.aliases.contains(word)
      }
      guard let next else { break }
      target = next
    }
    return target
  }

  private static func report(code: String, message: String, paths: [String]? = nil, json: Bool, sink: any OutputSink) {
    if json {
      var object: [String: Any] = ["code": code, "message": message]
      if let paths { object["paths"] = paths }
      sink.writeOutput(JSONOut.string(["error": object]) + "\n")
    } else {
      sink.writeError("error: \(message)\n")
    }
  }
}
