import ArgumentParser

struct ConfigGet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config-get",
    abstract: "Read a value from config.toml"
  )

  @Argument(help: "Config key to read (e.g. flake)")
  var key: String

  func run() throws {
    let config = try DVMConfig.load()
    switch key {
    case "flake":
      guard let flake = config.flake else { throw ExitCode(1) }
      print(flake)

    default:
      throw ExitCode(1)
    }
  }
}
