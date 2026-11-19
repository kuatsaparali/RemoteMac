import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames: AsyncThrowingStream<Data, Error>
    let queue = DispatchQueue(label: "macremote.frames")
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let videoRate: Int32
    private let videoBitRate: Int
    private var latest: (pixels: CVPixelBuffer, time: CMTime)?
    private var lastTime = -Double.infinity
    private var requested = false
    private var encoding = false
    private var finished = false
    private var wantsVideo = false
    private var timestamps = false
    private var restartEncoder = false
    private var interval = 1.0 / 12
    private var encoder: H264Encoder?

    init(mobile: Bool) {
        self.videoRate = mobile ? 60 : H264Encoder.frameRate
        self.videoBitRate = mobile ? 2_500_000 : 5_000_000
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        frames = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.continuation = continuation
        super.init()
    }

    func requestFrame() {
        queue.async {
            self.requested = true
            self.encodeLatest()
        }
    }

    func configure(video: Bool, audio: Bool) {
        queue.async {
            self.wantsVideo = video
            self.timestamps = audio
            self.interval = video ? 1.0 / Double(self.videoRate) : 1.0 / 20
            self.restartEncoder = true
            self.encodeLatest()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixels = sampleBuffer.imageBuffer else { return }
        // Keep the newest raw frame. Never discard an encoded H.264 dependency frame.
        latest = (pixels, sampleBuffer.presentationTimeStamp)
        encodeLatest()
    }

    private func encodeLatest() {
        guard !finished, !encoding else { return }
        if restartEncoder {
            encoder?.stop()
            encoder = nil
            lastTime = -Double.infinity
            restartEncoder = false
        }
        guard requested, let frame = latest, frame.time.seconds - lastTime >= interval * 0.9 else { return }
        requested = false
        lastTime = frame.time.seconds
        if wantsVideo && encoder == nil {
            encoder = try? H264Encoder(width: CVPixelBufferGetWidth(frame.pixels), height: CVPixelBufferGetHeight(frame.pixels),
                                        frameRate: videoRate, bitRate: videoBitRate)
            if encoder == nil {
                wantsVideo = false
                interval = 1.0 / 20
            }
        }
        guard let encoder else { jpeg(frame.pixels, at: frame.time); return }
        encoding = true
        encoder.encode(frame.pixels, at: frame.time) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                self.encoding = false
                if self.restartEncoder {
                    self.requested = true
                    self.encodeLatest()
                } else {
                    switch result {
                    case .frame(let packet):
                        self.continuation.yield(packet)
                    case .dropped:
                        self.encoder?.stop()
                        self.encoder = nil
                        self.jpeg(frame.pixels, at: frame.time)
                    case .failed:
                        self.encoder?.stop()
                        self.encoder = nil
                        self.wantsVideo = false
                        self.interval = 1.0 / 20
                        self.jpeg(frame.pixels, at: frame.time)
                    }
                }
            }
        }
    }

    private func jpeg(_ pixels: CVPixelBuffer, at time: CMTime) {
        let image = CIImage(cvPixelBuffer: pixels)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        if let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.6]),
           jpeg.count < 768 * 1024 - 40 {
            if timestamps, let timestamp = time.mediaMicroseconds {
                var stamp = timestamp.bigEndian
                var packet = Data([0x4d, 0x52, 0x4a, 1])
                withUnsafeBytes(of: &stamp) { packet.append(contentsOf: $0) }
                packet.append(jpeg)
                continuation.yield(packet)
            } else {
                continuation.yield(jpeg)
            }
        } else {
            requested = true
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish(throwing: error)
    }

    func finish() {
        queue.async {
            self.finished = true
            self.latest = nil
            self.encoder?.stop()
            self.encoder = nil
            self.continuation.finish()
        }
    }
}

@MainActor
final class ScreenFeed {
    let displayID: CGDirectDisplayID
    private let stream: SCStream
    private let output: FrameOutput
    private let audioOutput = SystemAudioOutput()
    private let width: Int
    private let height: Int

    var frames: AsyncThrowingStream<Data, Error> { output.frames }
    var audioPackets: AsyncStream<Data> { audioOutput.packets }

    init(mobile: Bool) async throws {
        let main = CGMainDisplayID()
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = available.displays.first(where: { $0.displayID == main }) else { throw SessionError.noDisplay }
        displayID = main
        let maxWidth: Double = mobile ? 1024 : 1440
        let maxHeight: Double = mobile ? 720 : 960
        let scale = min(1, maxWidth / Double(display.width), maxHeight / Double(display.height))
        width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        let config = Self.configuration(width: width, height: height, frameRate: 12, audio: false)
        let output = FrameOutput(mobile: mobile)
        self.output = output
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let localApp = available.applications.filter { $0.processID == ownProcess }
        let filter = SCContentFilter(display: display, excludingApplications: localApp, exceptingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: audioOutput.queue)
    }

    func requestFrame() { output.requestFrame() }
    func configure(video: Bool, audio: Bool) {
        output.configure(video: video, audio: audio)
        let config = Self.configuration(width: width, height: height, frameRate: video ? output.videoRate : 20, audio: audio)
        stream.updateConfiguration(config, completionHandler: { _ in })
    }
    func start() async throws { try await stream.startCapture() }

    func stop() async {
        output.finish()
        audioOutput.finish()
        try? await stream.stopCapture()
    }

    private static func configuration(width: Int, height: Int, frameRate: Int32, audio: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = audio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        return config
    }
}
