import Testing

@testable import DossierCLICore

@Suite("DossierCLICore scaffold")
struct SmokeTests {
  @Test func commandNameIsDossier() {
    #expect(DossierCommand.configuration.commandName == "dossier")
  }
}
