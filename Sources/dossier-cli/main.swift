import DossierCLICore
import Foundation

exit(DossierCLI.run(Array(CommandLine.arguments.dropFirst()), sink: ConsoleOutputSink()))
