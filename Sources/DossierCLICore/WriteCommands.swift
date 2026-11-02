import ArgumentParser
import Dossier
import DossierCore
import Foundation

struct CreateCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "create", abstract: "Make an empty bundle, and add its member to CAST.md through Reparto.")

  @Argument(help: "The character's name, as typed. It is canonicalized.") var name: String
  @Option(help: "The tier: lead, costar, supporting, guest or background.") var role: String
  @Option(name: .customLong("in"), help: "The directory the bundle goes in, by convention characters/.")
  var directory: String
  @Option(help: "The CAST.md to update. Without one the bundle is an orphan.") var cast: String?
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    let json = io.json
    let created = try DossierBundle.create(
      character: name, role: role, in: fileURL(directory), cast: cast.map(fileURL)
    ) { report in
      // Before anything is written. In JSON mode it goes in the object instead.
      if !json { for line in castReportLines(report) { io.note(line) } }
    }
    if io.json {
      var object: [String: Any] = [
        "bundle": created.bundle.url.path, "character": created.bundle.manifest.character,
        "role": role, "memberAdded": created.memberAdded,
      ]
      if let report = created.castReport { object["castReport"] = castReportJSON(report) }
      io.emit(object)
    } else {
      io.line("Created \(created.bundle.url.path)")
      if created.castReport != nil { io.line(created.memberAdded ? "Added the member to CAST.md" : "Updated the member in CAST.md") }
    }
    return 0
  }
}

struct AddCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "add", abstract: "Copy a file into a bundle and record it as an asset.")

  @Argument(help: "The bundle.") var bundle: String
  @Argument(help: "The file to copy. It is never changed.") var file: String
  @Option(help: "The asset kind, such as portrait, view, expression, vox, voiceSample.") var kind: String
  @Option(help: "The variant: a view or expression name, or a voice sample's.") var variant: String?
  @Option(help: "A voice sample's model size.") var model: String?
  @Option(name: .customLong("sample-text"), help: "The words a voice sample speaks.") var sampleText: String?
  @Option(help: "A voice sample's language.") var language: String?
  @Option(help: "Display text.") var label: String?
  @Flag(help: "Select the new asset, demoting the previous selection.") var select = false
  @Option(help: "A Vinetas sidecar. It stays outside the bundle.") var sidecar: String?
  @Option(help: "JSON merged over the sidecar's provenance.") var provenance: String?
  @Option(
    name: .customLong("reference-roles"),
    help: "The role of each reference, in order, comma-separated: portrait,face.")
  var referenceRoles: String?
  @Option(help: "The lora object, as JSON.") var lora: String?
  @Option(help: "The training object, as JSON.") var training: String?
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    var options = AddOptions()
    options.variant = variant
    options.model = model
    options.sampleText = sampleText
    options.language = language
    options.label = label
    options.select = select
    options.sidecar = sidecar.map(fileURL)
    options.provenance = try provenance.map { try parseObject($0, option: "--provenance") }
    options.lora = try lora.map { try parseObject($0, option: "--lora") }
    options.training = try training.map { try parseObject($0, option: "--training") }
    if let referenceRoles {
      options.referenceRoles = referenceRoles.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    }
    // A `dossier`'s `template` input (§7): the template this tool carries.
    if AssetKind(rawValue: kind) == .dossier { options.template = try DossierTemplate.current }
    var target = try openBundle(bundle)
    let asset = try target.add(fileURL(file), kind: AssetKind(rawValue: kind), options: options)
    if io.json {
      io.emit(["asset": assetJSON(asset)])
    } else {
      io.line("Added " + assetLine(asset))
    }
    return 0
  }
}

struct SelectCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "select", abstract: "Select an asset, demoting the previous selection.")
  @Argument(help: "The bundle.") var bundle: String
  @Argument(help: "The asset's path in the bundle.") var path: String
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    var target = try openBundle(bundle)
    let asset = try target.select(path: path)
    if io.json { io.emit(["asset": assetJSON(asset)]) } else { io.line("Selected " + assetLine(asset)) }
    return 0
  }
}

struct RejectCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "reject", abstract: "Mark an asset as not to be used. The file stays.")
  @Argument(help: "The bundle.") var bundle: String
  @Argument(help: "The asset's path in the bundle.") var path: String
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    var target = try openBundle(bundle)
    let asset = try target.reject(path: path)
    if io.json { io.emit(["asset": assetJSON(asset)]) } else { io.line("Rejected " + assetLine(asset)) }
    return 0
  }
}

struct RemoveCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "remove", abstract: "Delete one asset and its file. Needs --yes.",
    discussion: "Also the way out for an asset whose file is gone, which every other write refuses.")
  @Argument(help: "The bundle.") var bundle: String
  @Argument(help: "The asset's path in the bundle.") var path: String
  @Flag(help: "Confirm the deletion.") var yes = false
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    guard yes else {
      throw CLIFailure("confirmation-required", "remove deletes \(path) and its file; pass --yes to confirm")
    }
    var target = try openBundle(bundle)
    try target.remove(path: path)
    if io.json { io.emit(["removed": path]) } else { io.line("Removed \(path)") }
    return 0
  }
}

struct PromptCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "prompt", abstract: "Print or set one of the manifest's prompts: identity, portrait, subject.")
  @Argument(help: "The bundle.") var bundle: String
  @Argument(help: "identity, portrait or subject.") var key: String
  @Option(name: .customLong("set"), help: "The new text.") var text: String?
  @Option(help: "A file holding the new text.") var file: String?
  @OptionGroup var output: OutputOptions

  func validate() throws {
    if text != nil && file != nil { throw ValidationError("--set and --file are exclusive") }
    if PromptKey(rawValue: key) == nil {
      throw ValidationError("the key must be one of \(PromptKey.allCases.map(\.rawValue).joined(separator: ", "))")
    }
  }

  func execute(io: CommandIO) throws -> Int32 {
    guard let promptKey = PromptKey(rawValue: key) else { throw CLIFailure("usage", "unknown prompt key \(key)") }
    var target = try openBundle(bundle)
    var newText = text
    if let file {
      guard let data = try? Data(contentsOf: fileURL(file)) else {
        throw CLIFailure("file-unreadable", "can't read \(file)")
      }
      newText = String(decoding: data, as: UTF8.self)
    }
    if let newText { try target.setPrompt(promptKey, newText) }
    let prompts = target.manifest.prompts
    let current: String?
    switch promptKey {
    case .identity: current = prompts?.identity
    case .portrait: current = prompts?.portrait
    case .subject: current = prompts?.subject
    }
    if io.json {
      io.emit(["key": key, "text": current.map { $0 as Any } ?? NSNull(), "written": newText != nil])
    } else if let current {
      io.line(current)
    }
    return 0
  }
}

struct RefreshCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "refresh",
    abstract: "Accept changed files, and adopt files another tool put in the bundle (DOSSIER-FORMAT 5.6).",
    discussion: """
      The one way to accept a file changed by hand: it records the new hash and size, reports each \
      file by path, and clears E-FILE-HASH. No other command does. It can't clear E-FILE-MISSING: a \
      missing file must be restored, or, if it's an asset, taken out with remove.
      """)
  @Argument(help: "The bundle.") var bundle: String
  @Option(help: "The CAST.md, for adopting an orphan bundle.") var cast: String?
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    var target = try openBundle(bundle)
    let json = io.json
    let report = try target.refresh(cast: cast.map(fileURL)) { castReport in
      if !json { for line in castReportLines(castReport) { io.note(line) } }
    }
    if io.json {
      var object: [String: Any] = [
        "accepted": report.accepted,
        "adopted": report.adopted.map(assetJSON),
        "unclassified": report.unclassified.map { ["path": $0.path, "reason": $0.reason.description] },
      ]
      if let orphan = report.orphan { object["orphan"] = String(describing: orphan) }
      if let castReport = report.castReport { object["castReport"] = castReportJSON(castReport) }
      io.emit(object)
    } else {
      for path in report.accepted { io.line("Accepted \(path)") }
      for asset in report.adopted { io.line("Adopted " + assetLine(asset)) }
      for file in report.unclassified { io.line("Unclassified \(file.path): \(file.reason)") }
      if let orphan = report.orphan { io.line("Orphan: \(orphan)") }
      if report.accepted.isEmpty && report.adopted.isEmpty && report.unclassified.isEmpty {
        io.line("Nothing to accept or adopt")
      }
    }
    return 0
  }
}

struct FaceCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "face", abstract: "Crop the face from the selected portrait and select it (DOSSIER-FORMAT 8.5).")
  @Argument(help: "The bundle.") var bundle: String
  @Option(help: "A hand-set face box in the portrait's pixels, origin top-left: x,y,w,h. Recorded and reused.")
  var box: String?
  @OptionGroup var output: OutputOptions

  func validate() throws {
    if let box, FaceCommand.parse(box) == nil {
      throw ValidationError("--box must be four non-negative numbers, x,y,w,h, with a width and height above 0")
    }
  }

  static func parse(_ text: String) -> FaceBox? {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
      .map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3] else { return nil }
    let result = FaceBox(x: x, y: y, width: w, height: h)
    return result.isValid ? result : nil
  }

  func execute(io: CommandIO) throws -> Int32 {
    var target = try openBundle(bundle)
    let derived = try target.deriveFace(box: box.flatMap(FaceCommand.parse))
    if io.json {
      io.emit([
        "asset": assetJSON(derived.asset), "written": derived.wasWritten, "handSet": derived.handSet,
        "box": ["x": derived.box.x, "y": derived.box.y, "width": derived.box.width, "height": derived.box.height],
        "crop": ["left": derived.crop.left, "top": derived.crop.top, "side": derived.crop.side],
      ])
    } else {
      io.line(
        "\(derived.wasWritten ? "Added" : "Already there:") " + assetLine(derived.asset)
          + "  \(derived.crop.side)x\(derived.crop.side) at (\(derived.crop.left),\(derived.crop.top))")
    }
    return 0
  }
}
