import ArgumentParser

/// The root command of the `dossier` executable.
///
/// Run it through ``DossierCLI/run(_:sink:)``, which parses, executes in-process and returns
/// the exit status. The subcommands do their work in `execute(io:)`, not in `run()`.
public struct DossierCommand: ParsableCommand {
  /// Command configuration: name, abstract and the subcommand list.
  public static let configuration = CommandConfiguration(
    commandName: "dossier",
    abstract: "Read, write and validate .dossier character bundles.",
    discussion: """
      Every command takes --json: one object on standard output, errors as \
      {"error": {...}}, and a non-zero exit status.

      Exit status: validate gives 0 clean, 1 warnings only, 2 errors. Every other \
      command gives 0, or 1 when it fails. A bad command line gives 64. render and \
      migrate give 69: they are not available yet.
      """,
    subcommands: [
      CreateCommand.self, AddCommand.self, SelectCommand.self, RejectCommand.self,
      RemoveCommand.self, ListCommand.self, PromptCommand.self, ValidateCommand.self,
      RefreshCommand.self, CandidatesCommand.self, FaceCommand.self,
      RenderCommand.self, MigrateCommand.self,
    ]
  )

  /// Creates the command.
  public init() {}
}
