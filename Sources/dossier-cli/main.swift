import DossierCLICore
import Foundation

exit(await DossierCLI.run(Array(CommandLine.arguments.dropFirst()), sink: ConsoleOutputSink()))
