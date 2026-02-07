import ArgumentParser

@main
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record audio, screen, or camera output from the terminal.",
        subcommands: [AudioCommand.self, ScreenCommand.self, CameraCommand.self],
        defaultSubcommand: AudioCommand.self
    )
}
