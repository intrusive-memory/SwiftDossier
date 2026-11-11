import DossierCLICore
import Foundation

exit(await DossierCLI.runAsync(Array(CommandLine.arguments.dropFirst()), sink: ConsoleOutputSink()))
