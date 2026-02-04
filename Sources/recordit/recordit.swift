import ArgumentParser

@main
struct Recordit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recordit",
        abstract: "Record audio, screen, or camera output from the terminal.",
        subcommands: [AudioCommand.self, ScreenCommand.self, CameraCommand.self],
        defaultSubcommand: AudioCommand.self
    )
}
