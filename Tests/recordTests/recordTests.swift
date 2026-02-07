import Foundation
import Testing
@testable import record

private func parseAudioCommand(_ arguments: [String]) throws -> AudioCommand {
    try AudioCommand.parseAsRoot(arguments) as! AudioCommand
}

@Test func parseAudioSourceOption() throws {
    let command = try parseAudioCommand(["--source", "both"])
    #expect(command.source == .both)
}

@Test func systemSourceRejectsLinearPCM() {
    var threw = false
    do {
        _ = try parseAudioCommand(["--source", "system", "--format", "linearPCM"])
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func bothSourceRejectsSilenceOptions() {
    var threw = false
    do {
        _ = try parseAudioCommand(["--source", "both", "--silence-db", "-50", "--silence-duration", "2"])
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func micSourceRejectsDisplaySelector() {
    var threw = false
    do {
        _ = try parseAudioCommand(["--source", "mic", "--display", "primary"])
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func sourceDefaultsMatchDesign() throws {
    let command = try parseAudioCommand([])

    #expect(command.defaultFormat(for: .mic) == .linearPCM)
    #expect(command.defaultFormat(for: .system) == .aac)
    #expect(command.defaultFormat(for: .both) == .aac)

    #expect(command.defaultSampleRate(for: .mic) == 44_100)
    #expect(command.defaultSampleRate(for: .system) == 48_000)
    #expect(command.defaultChannels(for: .mic) == 1)
    #expect(command.defaultChannels(for: .both) == 2)
}

@Test func outputExtensionMappingIsStable() throws {
    let commandCAF = try parseAudioCommand(["--output", NSTemporaryDirectory() + "/record-test-\(UUID().uuidString)"])
    let cafURL = try commandCAF.resolveOutputURL(extension: AudioCommand.AudioFormat.linearPCM.fileExtension)
    #expect(cafURL.pathExtension == "caf")

    let commandM4A = try parseAudioCommand(["--output", NSTemporaryDirectory() + "/record-test-\(UUID().uuidString)"])
    let m4aURL = try commandM4A.resolveOutputURL(extension: AudioCommand.AudioFormat.aac.fileExtension)
    #expect(m4aURL.pathExtension == "m4a")
}

@Test func mixerClipsAndAverages() {
    #expect(StreamAudioPipeline.mixSample(system: 1.0, microphone: 1.0) == 1.0)
    #expect(StreamAudioPipeline.mixSample(system: -1.0, microphone: -1.0) == -1.0)

    let neutral = StreamAudioPipeline.mixSample(system: 0.5, microphone: -0.5)
    #expect(abs(neutral) < 0.0001)
}
