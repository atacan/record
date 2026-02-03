import ArgumentParser
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Darwin

struct ScreenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Record the primary display to a temporary file.")

    @Option(help: "Stop recording after this many seconds. If omitted, press Ctrl-C to stop.")
    var duration: Double?

    @Flag(help: "List available displays and exit.")
    var listDisplays = false

    @Flag(help: "List available windows and exit.")
    var listWindows = false

    @Flag(help: "Print machine-readable JSON to stdout.")
    var json = false

    @Option(help: "Display ID to record, or 'primary'.")
    var display: String?

    @Option(help: "Window ID or title substring to record.")
    var window: String?

    mutating func run() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        if listDisplays {
            let displays = content.displays
            if json {
                struct RectInfo: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
                struct DisplayInfo: Codable { let id: UInt32; let width: Int; let height: Int; let frame: RectInfo }
                let out = displays.map {
                    DisplayInfo(
                        id: $0.displayID,
                        width: $0.width,
                        height: $0.height,
                        frame: RectInfo(
                            x: $0.frame.origin.x,
                            y: $0.frame.origin.y,
                            width: $0.frame.size.width,
                            height: $0.frame.size.height
                        )
                    )
                }
                let data = try JSONEncoder().encode(out)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for display in displays {
                    print("\(display.displayID)\t\(display.width)x\(display.height)\t\(display.frame)")
                }
            }
            return
        }

        if listWindows {
            let windows = content.windows
            if json {
                struct RectInfo: Codable { let x: Double; let y: Double; let width: Double; let height: Double }
                struct WindowInfo: Codable {
                    let id: UInt32
                    let title: String?
                    let app: String?
                    let pid: Int32?
                    let layer: Int
                    let onScreen: Bool
                    let active: Bool?
                    let frame: RectInfo
                }
                let out = windows.map {
                    WindowInfo(
                        id: $0.windowID,
                        title: $0.title,
                        app: $0.owningApplication?.applicationName,
                        pid: $0.owningApplication?.processID,
                        layer: $0.windowLayer,
                        onScreen: $0.isOnScreen,
                        active: $0.isActive,
                        frame: RectInfo(
                            x: $0.frame.origin.x,
                            y: $0.frame.origin.y,
                            width: $0.frame.size.width,
                            height: $0.frame.size.height
                        )
                    )
                }
                let data = try JSONEncoder().encode(out)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for window in windows {
                    let title = window.title ?? "(untitled)"
                    let app = window.owningApplication?.applicationName ?? "(unknown)"
                    let activeFlag = window.isActive ? "*" : " "
                    let onScreenFlag = window.isOnScreen ? "on" : "off"
                    print("\(activeFlag) \(window.windowID)\t\(app)\t\(title)\t\(onScreenFlag)")
                }
            }
            return
        }

        let chosenWindow: SCWindow?
        if let window {
            if let windowID = UInt32(window) {
                chosenWindow = content.windows.first { $0.windowID == windowID }
            } else {
                let matches = content.windows.filter {
                    let title = $0.title ?? ""
                    let app = $0.owningApplication?.applicationName ?? ""
                    return title.range(of: window, options: .caseInsensitive) != nil ||
                        app.range(of: window, options: .caseInsensitive) != nil
                }
                if matches.count == 1 {
                    chosenWindow = matches.first
                } else if matches.isEmpty {
                    throw ValidationError("No window matches '\(window)'. Use --list-windows to see available windows.")
                } else {
                    let names = matches.compactMap { $0.title ?? $0.owningApplication?.applicationName }.joined(separator: ", ")
                    throw ValidationError("Multiple windows match '\(window)': \(names). Please be more specific.")
                }
            }
        } else {
            chosenWindow = nil
        }

        let chosenDisplay: SCDisplay?
        if chosenWindow != nil {
            chosenDisplay = nil
        } else if let display {
            if display.lowercased() == "primary" {
                chosenDisplay = content.displays.first
            } else if let displayID = UInt32(display) {
                chosenDisplay = content.displays.first { $0.displayID == displayID }
            } else {
                throw ValidationError("Invalid display '\(display)'. Use a display ID or 'primary'.")
            }
        } else {
            chosenDisplay = content.displays.first
        }

        if chosenWindow == nil, chosenDisplay == nil {
            log("No displays available for capture.")
            throw ExitCode(2)
        }

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recordit-screen-\(UUID().uuidString).mp4"
        )

        let recorder = try ScreenRecorder(
            outputURL: outputURL,
            display: chosenDisplay,
            window: chosenWindow
        )

        let signalStream = AsyncStream<Void> { continuation in
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler {
                continuation.yield()
                continuation.finish()
            }
            source.resume()
            continuation.onTermination = { _ in
                source.cancel()
            }
        }

        if let duration {
            log("Screen recording… will stop automatically after \(duration) seconds (or Ctrl-C to stop).")
        } else {
            log("Screen recording… press Ctrl-C to stop.")
        }
        print(outputURL.path())

        try await recorder.start()

        if let duration {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } else {
            for await _ in signalStream {
                break
            }
        }

        try await recorder.stop()
    }
}

final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "recordit.screen.capture")

    init(outputURL: URL, display: SCDisplay?, window: SCWindow?) throws {
        let filter: SCContentFilter
        if let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            throw ValidationError("No display or window selected for capture.")
        }

        let config = SCStreamConfiguration()
        if let display {
            config.width = display.width
            config.height = display.height
        } else if let window {
            config.width = Int(window.frame.size.width)
            config.height = Int(window.frame.size.height)
        } else {
            config.width = 1920
            config.height = 1080
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: config.width,
                AVVideoHeightKey: config.height
            ]
        )
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
        } else {
            throw NSError(domain: "recordit.screen", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to configure video writer input."
            ])
        }

        super.init()

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async throws {
        try await stream.stopCapture()
        input.markAsFinished()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if let error = self.writer.error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if writer.status == .unknown {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
        }

        if writer.status == .failed {
            log("Writer failed: \(writer.error?.localizedDescription ?? "unknown error")")
            return
        }

        if input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                log("Failed to append sample buffer: \(writer.error?.localizedDescription ?? "unknown error")")
            }
        }
    }
}
