import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// Keep stdout clean for piping: put status/errors on stderr
func log(_ message: String) {
    let data = (message + "\n").data(using: .utf8)!
    FileHandle.standardError.write(data)
}

final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "recordit.screen.capture")

    init(outputURL: URL, display: SCDisplay) throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
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

@main
struct RecorditScreen {
    static func main() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                log("No displays available for capture.")
                exit(2)
            }

            let filename = "recordit-screen-\(UUID().uuidString).mp4"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

            let recorder = try ScreenRecorder(outputURL: url, display: display)

            signal(SIGINT, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signalSource.setEventHandler {
                Task {
                    do {
                        try await recorder.stop()
                        exit(0)
                    } catch {
                        log("Error stopping: \(error)")
                        exit(1)
                    }
                }
            }
            signalSource.resume()

            log("Screen recording… press Ctrl-C to stop.")
            print(url.path())

            try await recorder.start()
            dispatchMain()
        } catch {
            log("Error: \(error)")
            exit(1)
        }
    }
}
