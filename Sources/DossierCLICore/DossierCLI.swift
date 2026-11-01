import ArgumentParser
import Dossier

/// The root command of the `dossier` executable. Subcommands arrive in later sorties.
public struct DossierCommand: ParsableCommand {
  /// Command configuration: name and one-line abstract.
  public static let configuration = CommandConfiguration(
    commandName: "dossier",
    abstract: "Read, write and validate .dossier character bundles."
  )

  /// Creates the command.
  public init() {}

  /// Placeholder body; prints usage.
  public func run() throws {
    print(Self.helpMessage())
  }
}
