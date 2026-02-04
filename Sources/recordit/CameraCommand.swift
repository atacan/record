import ArgumentParser
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct CameraCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "camera",
        abstract: "Record camera video or take a photo to a temporary file."
    )

    enum Mode: String, CaseIterable, ExpressibleByArgument {
        case video
        case photo
    }

    enum PhotoFormat: String, CaseIterable, ExpressibleByArgument {
        case jpeg
        case heic

        var fileExtension: String {
            switch self {
            case .jpeg:
                return "jpg"
            case .heic:
                return "heic"
            }
        }

        var codec: AVVideoCodecType {
            switch self {
            case .jpeg:
                return .jpeg
            case .heic:
                return .hevc
            }
        }
    }

    @Flag(help: "List available cameras and exit.")
    var listCameras = false

    @Option(help: "Camera ID or name substring to use for capture.")
    var camera: String?

    @Option(help: "Capture mode: video or photo. Default: video.")
    var mode: Mode?

    @Flag(help: "Capture a single photo (alias for --mode photo).")
    var photo = false

    @Option(help: "Stop recording after this many seconds. If omitted, press the stop key to stop.")
    var duration: Double?

    @Option(help: "Write output to this file or directory. Default: temporary directory.")
    var output: String?

    @Option(help: "Filename pattern when output is a directory. Supports strftime tokens, {uuid}, and {chunk}.")
    var name: String?

    @Flag(help: "Overwrite output file if it exists.")
    var overwrite = false

    @Flag(help: "Print machine-readable JSON to stdout.")
    var json = false

    @Option(help: "Stop key (single ASCII character). Default: s.")
    var stopKey: String?

    @Option(help: "Stop when output file reaches this size in MB.")
    var maxSizeMB: Double?

    @Option(help: "Split recording into chunks of this many seconds. Output must be a directory.")
    var split: Double?

    @Option(help: "Frames per second.")
    var fps: Double?

    @Option(help: "Capture resolution as WIDTHxHEIGHT (e.g. 1280x720).")
    var resolution: String?

    @Flag(help: "Record from the system default microphone.")
    var audio = false

    @Option(help: "Photo format. Default: jpeg.")
    var photoFormat: PhotoFormat?

    mutating func run() async throws {
        do {
            if listCameras {
                try listAvailableCameras(json: json)
                return
            }

            let resolvedMode = try resolveMode()
            try validateOptions(mode: resolvedMode)

            let devices = discoverCameras()
            guard !devices.isEmpty else {
                log("No cameras available for capture.")
                throw ExitCode(2)
            }

            let chosenCamera = try resolveCamera(devices: devices, selection: camera)

            let granted = await requestCameraPermission()
            guard granted else {
                log("""
                Camera permission not granted.

                Since this is a CLI tool, macOS usually assigns camera permission to your terminal app.
                Enable it in:
                  System Settings → Privacy & Security → Camera → (Terminal / iTerm / your terminal)
                """)
                throw ExitCode(2)
            }

            if audio {
                let micGranted = await requestMicrophonePermission()
                guard micGranted else {
                    log("""
                    Microphone permission not granted.

                    Since this is a CLI tool, macOS usually assigns microphone permission to your terminal app.
                    Enable it in:
                      System Settings → Privacy & Security → Microphone → (Terminal / iTerm / your terminal)
                    """)
                    throw ExitCode(2)
                }
            }

            let targetResolution = try resolution.map { try parseResolution($0) }

            switch resolvedMode {
            case .photo:
                let format = photoFormat ?? .jpeg
                let outputURL = try resolveOutputURL(
                    output: output,
                    name: name,
                    fileExtension: format.fileExtension,
                    chunkIndex: nil,
                    requireDirectory: false,
                    prefix: "recordit-photo"
                )

                if FileManager.default.fileExists(atPath: outputURL.path) {
                    if overwrite {
                        try FileManager.default.removeItem(at: outputURL)
                    } else {
                        throw ValidationError("Output file already exists. Use --overwrite to replace it.")
                    }
                }

                let capturer = try CameraPhotoCapturer(device: chosenCamera, resolution: targetResolution)
                try await capturer.capturePhoto(to: outputURL, format: format)

                if json {
                    struct Output: Codable {
                        let path: String
                        let mode: String
                        let format: String
                    }

                    let out = Output(path: outputURL.path, mode: "photo", format: format.rawValue)
                    let data = try JSONEncoder().encode(out)
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    print(outputURL.path())
                }

            case .video:
                let stopKeyValue = stopKey ?? "s"
                let stopKeys = try resolveKeySet(stopKeyValue, label: "Stop key")
                let stopKeyDisplay = stopKeyValue.uppercased()

                let overallDeadline = duration.map { Date().addingTimeInterval($0) }
                let shouldSplit = split != nil
                var chunkIndex = 1
                let maxSizeBytes = maxSizeMB.map { Int64($0 * 1_048_576) }

                let recorder = try CameraVideoRecorder(
                    device: chosenCamera,
                    captureAudio: audio,
                    resolution: targetResolution,
                    fps: fps
                )

                while true {
                    if let overallDeadline, overallDeadline <= Date() {
                        break
                    }

                    let url = try resolveOutputURL(
                        output: output,
                        name: name,
                        fileExtension: "mov",
                        chunkIndex: shouldSplit ? chunkIndex : nil,
                        requireDirectory: shouldSplit,
                        prefix: "recordit-camera"
                    )

                    if FileManager.default.fileExists(atPath: url.path) {
                        if overwrite {
                            try FileManager.default.removeItem(at: url)
                        } else {
                            throw ValidationError("Output file already exists. Use --overwrite to replace it.")
                        }
                    }

                    try recorder.startRecording(to: url)

                    var stopMessage = "press '\(stopKeyDisplay)' to stop"
                    if let split {
                        stopMessage += ", split every \(split)s"
                    }
                    if let maxSizeMB {
                        stopMessage += " or when file reaches \(maxSizeMB) MB"
                    }

                    let chunkLabel = shouldSplit ? " (chunk \(chunkIndex))" : ""
                    if let duration {
                        log("Camera recording\(chunkLabel)… will stop automatically after \(duration) seconds or when you \(stopMessage).")
                    } else {
                        log("Camera recording\(chunkLabel)… \(stopMessage).")
                    }

                    let remainingDuration = overallDeadline.map { max(0, $0.timeIntervalSinceNow) }
                    let stopReason = try await waitForStopKeyOrDuration(
                        remainingDuration,
                        splitDuration: split,
                        stopKeys: stopKeys,
                        maxSizeBytes: maxSizeBytes,
                        outputURL: url
                    )

                    try await recorder.stopRecording()

                    if json {
                        struct Output: Codable {
                            let path: String
                            let mode: String
                            let fps: Double?
                            let resolution: String?
                            let audio: Bool
                            let duration: Double?
                            let maxSizeMB: Double?
                            let chunk: Int
                            let stopReason: StopReason
                        }

                        let out = Output(
                            path: url.path,
                            mode: "video",
                            fps: fps,
                            resolution: targetResolution.map { "\($0.width)x\($0.height)" },
                            audio: audio,
                            duration: duration,
                            maxSizeMB: maxSizeMB,
                            chunk: chunkIndex,
                            stopReason: stopReason
                        )
                        let data = try JSONEncoder().encode(out)
                        FileHandle.standardOutput.write(data)
                        FileHandle.standardOutput.write(Data("\n".utf8))
                    } else {
                        print(url.path())
                    }

                    if stopReason == .split {
                        chunkIndex += 1
                        continue
                    }
                    break
                }

                recorder.stopSession()
            }
        } catch {
            log("Error: \(error)")
            throw ExitCode(1)
        }
    }

    private func resolveMode() throws -> Mode {
        if photo {
            if mode == .video {
                throw ValidationError("--photo conflicts with --mode video. Use --mode photo or drop --photo.")
            }
            return .photo
        }
        return mode ?? .video
    }

    private func validateOptions(mode: Mode) throws {
        if let duration, duration <= 0 {
            throw ValidationError("Duration must be greater than 0 seconds.")
        }
        if let split, split <= 0 {
            throw ValidationError("Split duration must be greater than 0 seconds.")
        }
        if let maxSizeMB, maxSizeMB <= 0 {
            throw ValidationError("Max size must be greater than 0 MB.")
        }
        if let fps, fps <= 0 {
            throw ValidationError("FPS must be greater than 0.")
        }

        if mode == .photo {
            if duration != nil {
                throw ValidationError("--duration is only supported for video capture.")
            }
            if split != nil {
                throw ValidationError("--split is only supported for video capture.")
            }
            if maxSizeMB != nil {
                throw ValidationError("--max-size is only supported for video capture.")
            }
            if fps != nil {
                throw ValidationError("--fps is only supported for video capture.")
            }
            if audio {
                throw ValidationError("--audio is only supported for video capture.")
            }
        }
    }
}

private struct CameraInfo: Codable {
    let id: String
    let name: String
    let position: String
    let isDefault: Bool
}

private func listAvailableCameras(json: Bool) throws {
    let devices = discoverCameras()
    let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID

    if json {
        let out = devices.map {
            CameraInfo(
                id: $0.uniqueID,
                name: $0.localizedName,
                position: cameraPositionLabel($0.position),
                isDefault: $0.uniqueID == defaultID
            )
        }
        let data = try JSONEncoder().encode(out)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        for device in devices {
            let marker = (device.uniqueID == defaultID) ? "*" : " "
            print("\(marker) \(device.localizedName)\t\(device.uniqueID)")
        }
    }
}

private func discoverCameras() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]

    if #available(macOS 13.0, *) {
        types.append(.continuityCamera)
    }
    if #available(macOS 14.0, *) {
        types.append(.deskViewCamera)
    }

    let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    return session.devices.sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
}

private func resolveCamera(devices: [AVCaptureDevice], selection: String?) throws -> AVCaptureDevice {
    guard let selection else {
        return AVCaptureDevice.default(for: .video) ?? devices[0]
    }

    if let exact = devices.first(where: { $0.uniqueID.caseInsensitiveCompare(selection) == .orderedSame }) {
        return exact
    }

    let matches = devices.filter { $0.localizedName.range(of: selection, options: .caseInsensitive) != nil }
    if matches.count == 1, let match = matches.first {
        return match
    }
    if matches.isEmpty {
        throw ValidationError("No camera matches '\(selection)'. Use --list-cameras to see available cameras.")
    }

    let names = matches.map { $0.localizedName }.joined(separator: ", ")
    throw ValidationError("Multiple cameras match '\(selection)': \(names). Please be more specific.")
}

private func cameraPositionLabel(_ position: AVCaptureDevice.Position) -> String {
    switch position {
    case .front: return "front"
    case .back: return "back"
    default: return "unspecified"
    }
}

private func parseResolution(_ value: String) throws -> CMVideoDimensions {
    let parts = value.lowercased().split(separator: "x")
    guard parts.count == 2,
          let width = Int32(parts[0]),
          let height = Int32(parts[1]),
          width > 0,
          height > 0 else {
        throw ValidationError("Resolution must be formatted as WIDTHxHEIGHT (e.g. 1280x720).")
    }
    return CMVideoDimensions(width: width, height: height)
}

private func resolveKeySet(_ key: String, label: String) throws -> Set<UInt8> {
    guard key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII else {
        throw ValidationError("\(label) must be a single ASCII character.")
    }

    var keys: Set<UInt8> = [UInt8(scalar.value)]
    if scalar.properties.isAlphabetic {
        if let upper = key.uppercased().unicodeScalars.first {
            keys.insert(UInt8(upper.value))
        }
        if let lower = key.lowercased().unicodeScalars.first {
            keys.insert(UInt8(lower.value))
        }
    }
    return keys
}

private func formatFilename(pattern: String, date: Date, uuid: UUID, chunkIndex: Int?, prefix: String) -> String {
    var t = time_t(date.timeIntervalSince1970)
    var tm = tm()
    localtime_r(&t, &tm)

    var buffer = [CChar](repeating: 0, count: 256)
    let count = strftime(&buffer, buffer.count, pattern, &tm)
    if count == 0 {
        return "\(prefix)-\(uuid.uuidString)"
    }

    let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
    let base = String(bytes: bytes, encoding: .utf8) ?? "\(prefix)-\(uuid.uuidString)"
    var result = base.replacingOccurrences(of: "{uuid}", with: uuid.uuidString)
    if let chunkIndex {
        result = result.replacingOccurrences(of: "{chunk}", with: String(chunkIndex))
    }
    return result
}

private func resolveOutputURL(
    output: String?,
    name: String?,
    fileExtension: String,
    chunkIndex: Int?,
    requireDirectory: Bool,
    prefix: String
) throws -> URL {
    let fileManager = FileManager.default
    let uuid = UUID()
    let defaultPattern = (chunkIndex == nil) ? "\(prefix)-%Y%m%d-%H%M%S" : "\(prefix)-%Y%m%d-%H%M%S-{chunk}"
    let pattern = name ?? defaultPattern

    func ensureExtension(_ filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        if url.pathExtension.isEmpty {
            return filename + "." + fileExtension
        }
        return filename
    }

    if let output {
        let outputURL = URL(fileURLWithPath: output)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex, prefix: prefix)
                return outputURL.appendingPathComponent(ensureExtension(filename))
            }
            if requireDirectory {
                throw ValidationError("Output must be a directory when using --split.")
            }
            return URL(fileURLWithPath: ensureExtension(outputURL.path))
        }

        if output.hasSuffix("/") {
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex, prefix: prefix)
            return outputURL.appendingPathComponent(ensureExtension(filename))
        }

        if requireDirectory {
            if !outputURL.pathExtension.isEmpty {
                throw ValidationError("Output must be a directory when using --split.")
            }
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex, prefix: prefix)
            return outputURL.appendingPathComponent(ensureExtension(filename))
        }

        if outputURL.pathExtension.isEmpty {
            return URL(fileURLWithPath: ensureExtension(outputURL.path))
        }
        return outputURL
    }

    let filename = formatFilename(pattern: pattern, date: Date(), uuid: uuid, chunkIndex: chunkIndex, prefix: prefix)
    let tempDir = fileManager.temporaryDirectory
    return tempDir.appendingPathComponent(ensureExtension(filename))
}

private func waitForStopKeyOrDuration(
    _ duration: Double?,
    splitDuration: Double?,
    stopKeys: Set<UInt8>,
    maxSizeBytes: Int64?,
    outputURL: URL?
) async throws -> StopReason {
    let rawMode = TerminalRawMode()
    defer { _ = rawMode }

    let deadline = duration.map { Date().addingTimeInterval($0) }
    var splitRemaining = splitDuration
    let sizeInterval: TimeInterval = 0.5
    var nextSizeCheck = Date()
    let fileManager = FileManager.default
    var buffer: UInt8 = 0
    var lastTick = Date()

    while true {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now

        if let deadline, now >= deadline {
            return .duration
        }
        if let remaining = splitRemaining {
            let updated = remaining - elapsed
            splitRemaining = updated
            if updated <= 0 {
                return .split
            }
        }
        if let maxSizeBytes, let outputURL, now >= nextSizeCheck {
            if let attrs = try? fileManager.attributesOfItem(atPath: outputURL.path),
               let size = attrs[.size] as? NSNumber,
               size.int64Value >= maxSizeBytes {
                return .maxSize
            }
            nextSizeCheck = now.addingTimeInterval(sizeInterval)
        }

        var timeout = 0.25
        if let deadline {
            timeout = min(timeout, max(0, deadline.timeIntervalSince(now)))
        }
        if let splitRemaining {
            timeout = min(timeout, max(0, splitRemaining))
        }
        if maxSizeBytes != nil, outputURL != nil {
            timeout = min(timeout, max(0, nextSizeCheck.timeIntervalSince(now)))
        }
        let timeoutMs = Int32(max(1, Int(timeout * 1000)))

        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&fds, 1, timeoutMs)
        if ready > 0 && (fds.revents & Int16(POLLIN)) != 0 {
            let count = read(STDIN_FILENO, &buffer, 1)
            if count == 1 && stopKeys.contains(buffer) {
                return .key
            }
        }
    }
}

private func requestCameraPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        return true
    case .notDetermined:
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                cont.resume(returning: granted)
            }
        }
    case .denied, .restricted:
        return false
    @unknown default:
        return false
    }
}

private final class CameraVideoRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let session: AVCaptureSession
    private let output: AVCaptureMovieFileOutput
    private var continuation: CheckedContinuation<Void, Error>?
    private let continuationLock = NSLock()

    init(device: AVCaptureDevice, captureAudio: Bool, resolution: CMVideoDimensions?, fps: Double?) throws {
        session = AVCaptureSession()
        output = AVCaptureMovieFileOutput()

        try configureDevice(device, resolution: resolution, fps: fps)

        session.beginConfiguration()

        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else {
            throw ValidationError("Unable to add camera input to capture session.")
        }
        session.addInput(videoInput)

        if captureAudio {
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                throw ValidationError("No microphone available for capture.")
            }
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            } else {
                throw ValidationError("Unable to add microphone input to capture session.")
            }
        }

        guard session.canAddOutput(output) else {
            throw ValidationError("Unable to add movie output to capture session.")
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func startRecording(to url: URL) throws {
        guard !output.isRecording else {
            throw ValidationError("Recording already in progress.")
        }
        output.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() async throws {
        guard output.isRecording else {
            return
        }
        try await withCheckedThrowingContinuation { cont in
            continuationLock.lock()
            continuation = cont
            continuationLock.unlock()
            output.stopRecording()
        }
    }

    func stopSession() {
        session.stopRunning()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        continuationLock.lock()
        let continuation = self.continuation
        self.continuation = nil
        continuationLock.unlock()
        guard let continuation else { return }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private final class CameraPhotoCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session: AVCaptureSession
    private let output: AVCaptureVideoDataOutput
    private let device: AVCaptureDevice
    private let queue = DispatchQueue(label: "recordit.camera.photo")
    private let ciContext = CIContext()
    private let state = PhotoCaptureState()

    init(device: AVCaptureDevice, resolution: CMVideoDimensions?) throws {
        session = AVCaptureSession()
        output = AVCaptureVideoDataOutput()
        self.device = device

        try configureDevice(device, resolution: resolution, fps: nil)

        session.beginConfiguration()
        session.sessionPreset = .photo

        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else {
            throw ValidationError("Unable to add camera input to capture session.")
        }
        session.addInput(videoInput)

        guard session.canAddOutput(output) else {
            throw ValidationError("Unable to add video output to capture session.")
        }
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        session.addOutput(output)
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        session.startRunning()
    }

    func capturePhoto(to url: URL, format: CameraCommand.PhotoFormat) async throws {
        defer { session.stopRunning() }
        try await warmUpIfNeeded()
        let image = try await awaitFrame(timeout: 2.0)
        try writeImage(image, to: url, format: format)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        guard let continuation = state.consumeFrameIfReady() else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            continuation.resume(throwing: ValidationError("Unable to encode photo."))
            return
        }

        continuation.resume(returning: cgImage)
    }

    private func warmUpIfNeeded() async throws {
        if session.isRunning == false {
            session.startRunning()
        }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let adjusting = device.isAdjustingExposure || device.isAdjustingWhiteBalance || device.isAdjustingFocus
            if !adjusting {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    private func awaitFrame(timeout: TimeInterval) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            state.beginCapture(cont, skipFrames: 5)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [state] in
                if let continuation = state.takeForTimeout() {
                    continuation.resume(throwing: ValidationError("Timed out waiting for a camera frame."))
                }
            }
        }
    }

    private func writeImage(_ image: CGImage, to url: URL, format: CameraCommand.PhotoFormat) throws {
        let type: CFString
        switch format {
        case .jpeg:
            type = UTType.jpeg.identifier as CFString
        case .heic:
            if #available(macOS 11.0, *),
               let types = CGImageDestinationCopyTypeIdentifiers() as? [CFString],
               types.contains(UTType.heic.identifier as CFString) {
                type = UTType.heic.identifier as CFString
            } else {
                throw ValidationError("HEIC encoding is not supported on this system.")
            }
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw ValidationError("Unable to create image destination.")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw ValidationError("Unable to write photo.")
        }
    }
}

private final class PhotoCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var frameCountdown = 0
    private var didCapture = false

    func beginCapture(_ continuation: CheckedContinuation<CGImage, Error>, skipFrames: Int) {
        lock.lock()
        self.continuation = continuation
        frameCountdown = max(0, skipFrames)
        didCapture = false
        lock.unlock()
    }

    func consumeFrameIfReady() -> CheckedContinuation<CGImage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, !didCapture else {
            return nil
        }
        if frameCountdown > 0 {
            frameCountdown -= 1
            return nil
        }
        didCapture = true
        self.continuation = nil
        return continuation
    }

    func takeForTimeout() -> CheckedContinuation<CGImage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, !didCapture else {
            return nil
        }
        didCapture = true
        self.continuation = nil
        return continuation
    }
}

private func configureDevice(_ device: AVCaptureDevice, resolution: CMVideoDimensions?, fps: Double?) throws {
    if resolution == nil && fps == nil {
        if device.isExposureModeSupported(.continuousAutoExposure) ||
            device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) ||
            device.isFocusModeSupported(.continuousAutoFocus) {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        }
        return
    }

    let selectedFormat = try selectFormat(device: device, resolution: resolution, fps: fps)

    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }

    if let selectedFormat {
        device.activeFormat = selectedFormat
    }

    if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
    }
    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
        device.whiteBalanceMode = .continuousAutoWhiteBalance
    }
    if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
    }

    if let fps {
        let duration = CMTimeMakeWithSeconds(1.0 / fps, preferredTimescale: 600)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }
}

private func selectFormat(
    device: AVCaptureDevice,
    resolution: CMVideoDimensions?,
    fps: Double?
) throws -> AVCaptureDevice.Format? {
    guard resolution != nil || fps != nil else {
        return nil
    }

    let formats = device.formats
    let matches = formats.filter { format in
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        if let resolution, (dims.width != resolution.width || dims.height != resolution.height) {
            return false
        }
        if let fps {
            return format.videoSupportedFrameRateRanges.contains { range in
                fps >= range.minFrameRate && fps <= range.maxFrameRate
            }
        }
        return true
    }

    if matches.isEmpty {
        if let resolution, let fps {
            throw ValidationError("No camera format supports \(resolution.width)x\(resolution.height) at \(fps) fps.")
        }
        if let resolution {
            throw ValidationError("No camera format supports \(resolution.width)x\(resolution.height).")
        }
        if let fps {
            throw ValidationError("No camera format supports \(fps) fps.")
        }
    }

    if resolution != nil {
        return matches.max { lhs, rhs in
            let lhsRange = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rhsRange = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return lhsRange < rhsRange
        }
    }

    return matches.max { lhs, rhs in
        let lhsDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
        let rhsDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
        return (lhsDims.width * lhsDims.height) < (rhsDims.width * rhsDims.height)
    }
}
