import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    override init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        frames = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.continuation = continuation
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixels = sampleBuffer.imageBuffer else { return }

        let image = CIImage(cvPixelBuffer: pixels)
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        if let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [qualityKey: 0.65]),
           jpeg.count < 768 * 1024 - 28 {
            continuation.yield(jpeg)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish(throwing: error)
    }

    func finish() { continuation.finish() }
}

@MainActor
final class ScreenFeed {
    let displayID: CGDirectDisplayID
    private let stream: SCStream
    private let output: FrameOutput

    var frames: AsyncThrowingStream<Data, Error> { output.frames }

    init() async throws {
        let main = CGMainDisplayID()
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = available.displays.first(where: { $0.displayID == main }) else {
            throw SessionError.noDisplay
        }
        displayID = main
        let scale = min(1, 1440 / Double(display.width), 960 / Double(display.height))
        let config = SCStreamConfiguration()
        config.width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        config.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 12)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        let output = FrameOutput()
        self.output = output
        stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: config, delegate: output
        )
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "macremote.frames"))
    }

    func start() async throws { try await stream.startCapture() }

    func stop() async {
        output.finish()
        try? await stream.stopCapture()
    }
}
