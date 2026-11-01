import ArgumentParser
import Dossier
import DossierCore
import Foundation

/// `dossier update`: the marker of DOSSIER-FORMAT 5.7, around a command or across several.
struct UpdateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Signal to other applications that a bundle is being updated (DOSSIER-FORMAT 5.7).",
    discussion: """
      A marker is a signal, not a lock: it doesn't stop another writer. begin, renew and end are \
      for an update that spans separate commands, and nothing renews a begun marker but renew.
      """,
    subcommands: subcommands)

  private static var subcommands: [any ParsableCommand.Type] {
    var commands: [any ParsableCommand.Type] = [
      UpdateBeginCommand.self, UpdateRenewCommand.self, UpdateEndCommand.self,
    ]
    #if os(macOS)
      commands.insert(UpdateRunCommand.self, at: 0)
    #endif
    return commands
  }
}

/// What `begin` and `renew` take: seconds ahead for `expiresAt`.
struct UpdateLifetimeOptions: ParsableArguments {
  @Option(help: "Seconds until the marker stops counting if it isn't renewed: 1 to 3600.")
  var ttl = Int(DossierBundle.defaultUpdateLifetime)

  func validate() throws {
    guard (1...3600).contains(ttl) else { throw ValidationError("--ttl must be from 1 to 3600") }
  }
}

struct UpdateBeginCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "begin", abstract: "Write a marker, and print its id for renew and end.")
  @Argument(help: "The bundle.") var bundle: String
  @Option(help: "One line for a person: what the update is doing.") var label: String?
  @Option(help: "The name of the tool making the update.") var writer = "dossier"
  @OptionGroup var lifetime: UpdateLifetimeOptions
  @OptionGroup var output: OutputOptions

  func validate() throws {
    if writer.isEmpty { throw ValidationError("--writer can't be empty") }
  }

  func execute(io: CommandIO) throws -> Int32 {
    let marker = try openBundle(bundle).beginUpdate(
      label: label, writer: writer, lifetime: TimeInterval(lifetime.ttl))
    if io.json { io.emit(updateJSON(marker)) } else { io.line(marker.id) }
    return 0
  }
}

struct UpdateRenewCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "renew", abstract: "Replace a marker with a later expiry.")
  @Argument(help: "The bundle.") var bundle: String
  @Argument(help: "The id begin printed.") var id: String
  @OptionGroup var lifetime: UpdateLifetimeOptions
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    let marker = try openBundle(bundle).renewUpdate(id: id, lifetime: TimeInterval(lifetime.ttl))
    if io.json {
      io.emit(updateJSON(marker))
    } else {
      io.line("Renewed \(marker.id) until \(timestamp(marker.expiresAt))")
    }
    return 0
  }
}

struct UpdateEndCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "end", abstract: "Remove a marker, after the update's last write.")
  @Argument(help: "The bundle.") var bundle: String
  @Argument(help: "The id begin printed.") var id: String
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    try openBundle(bundle).endUpdate(id: id)
    if io.json { io.emit(["ended": id]) } else { io.line("Ended \(id)") }
    return 0
  }
}

private func updateJSON(_ marker: UpdateMarkerHandle) -> [String: Any] {
  ["id": marker.id, "expiresAt": timestamp(marker.expiresAt)]
}

private func timestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}

#if os(macOS)
  struct UpdateRunCommand: DossierSubcommand {
    static let configuration = CommandConfiguration(
      commandName: "run",
      abstract: "Hold a marker while a command runs, and exit with its status.",
      discussion: """
        The command is run as given, with no shell, found on PATH when it has no slash. The marker \
        is renewed while it runs and removed when it ends, however it ends, unless this process is \
        killed outright, in which case the marker stops counting by itself. SIGTERM and SIGHUP are \
        passed on to the command. A command killed by a signal gives 128 + the signal; one that \
        can't be started gives 127 when it isn't found and 126 otherwise. With --json the command's \
        standard output goes to standard error, so that standard output is the one object.
        """)
    @Argument(help: "The bundle.") var bundle: String
    @Option(help: "One line for a person: what the update is doing.") var label: String?
    @OptionGroup var output: OutputOptions
    @Argument(parsing: .postTerminator, help: "The command and its arguments, after --.") var command: [String] = []

    func validate() throws {
      if command.isEmpty { throw ValidationError("give the command to run after --") }
    }

    func execute(io: CommandIO) throws -> Int32 {
      var target = try openBundle(bundle)
      let status = try target.withUpdate(label: label ?? command.joined(separator: " ")) { _ in
        try ChildProcess.run(command, standardOutputToError: io.json)
      }
      if io.json { io.emit(["command": command, "exitStatus": status]) }
      return status
    }
  }
#endif
