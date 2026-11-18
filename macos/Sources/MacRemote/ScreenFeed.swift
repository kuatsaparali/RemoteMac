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
    private var latest: (pixels: CVPixelBuffer, time: CMTime)?
    private var lastTime = -Double.infinity
    private var requested = false
    private var encoding = false
    private var finished = false
    private var wantsVideo = false
    private var restartEncoder = false
    private var interval = 1.0 / 12
    private var encoder: H264Encoder?

    override init() {
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

    func configure(video: Bool) {
        queue.async {
            self.wantsVideo = video
            self.interval = video ? 1.0 / Double(H264Encoder.frameRate) : 1.0 / 20
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
            encoder = try? H264Encoder(width: CVPixelBufferGetWidth(frame.pixels), height: CVPixelBufferGetHeight(frame.pixels))
            if encoder == nil {
                wantsVideo = false
                interval = 1.0 / 20
            }
        }
        guard let encoder else { jpeg(frame.pixels); return }
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
                        self.jpeg(frame.pixels)
                    case .failed:
                        self.encoder?.stop()
                        self.encoder = nil
                        self.wantsVideo = false
                        self.interval = 1.0 / 20
                        self.jpeg(frame.pixels)
                    }
                }
            }
        }
    }

    private func jpeg(_ pixels: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixels)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        if let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.6]),
           jpeg.count < 768 * 1024 - 28 {
            continuation.yield(jpeg)
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
    private let width: Int
    private let height: Int

    var frames: AsyncThrowingStream<Data, Error> { output.frames }

    init() async throws {
        let main = CGMainDisplayID()
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = available.displays.first(where: { $0.displayID == main }) else { throw SessionError.noDisplay }
        displayID = main
        let scale = min(1, 1440 / Double(display.width), 960 / Double(display.height))
        width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        let config = Self.configuration(width: width, height: height, frameRate: 12)
        let output = FrameOutput()
        self.output = output
        stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
    }

    func requestFrame() { output.requestFrame() }
    func configure(video: Bool) {
        output.configure(video: video)
        let config = Self.configuration(width: width, height: height, frameRate: video ? H264Encoder.frameRate : 20)
        stream.updateConfiguration(config, completionHandler: { _ in })
    }
    func start() async throws { try await stream.startCapture() }

    func stop() async {
        output.finish()
        try? await stream.stopCapture()
    }

    private static func configuration(width: Int, height: Int, frameRate: Int32) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        return config
    }
}
