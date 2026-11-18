import CoreMedia
import Foundation
import VideoToolbox

/// One low-latency H.264 access unit per submitted frame, with no B-frame reordering.
final class H264Encoder {
    static let frameRate: Int32 = 60

    enum Output { case frame(Data), dropped, failed }
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw Self.error(status) }
        do {
            let settings: [(CFString, CFTypeRef)] = [
                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
                (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
                (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
                (kVTCompressionPropertyKey_ExpectedFrameRate, Int(Self.frameRate) as CFNumber),
                (kVTCompressionPropertyKey_AverageBitRate, 3_000_000 as CFNumber),
                (kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(Self.frameRate * 2) as CFNumber),
                (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber),
            ]
            for (key, value) in settings {
                let result = VTSessionSetProperty(session, key: key, value: value)
                guard result == noErr else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(result),
                                  userInfo: [NSLocalizedDescriptionKey: "\(key): \(result)"])
                }
            }
            let result = VTCompressionSessionPrepareToEncodeFrames(session)
            guard result == noErr else { throw Self.error(result) }
        } catch {
            stop()
            throw error
        }
    }

    func encode(_ pixels: CVPixelBuffer, at timestamp: CMTime, completion: @escaping (Output) -> Void) {
        guard let session else { completion(.failed); return }
        let width = width
        let height = height
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: timestamp, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, flags, sample in
            guard status == noErr else { completion(.failed); return }
            if flags.contains(.frameDropped) { completion(.dropped); return }
            guard let sample, let packet = Self.packet(sample, width: width, height: height) else {
                completion(.failed)
                return
            }
            completion(.frame(packet))
        }
        if status != noErr { completion(.failed) }
    }

    func stop() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    deinit { stop() }

    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    private static func packet(_ sample: CMSampleBuffer, width: Int, height: Int) -> Data? {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var parameterSets = [Data]()
        var lengthBytes: Int32 = 0
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var length = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &lengthBytes
            )
            guard status == noErr, let pointer else { return nil }
            parameterSets.append(Data(bytes: pointer, count: length))
        }
        guard let sps = parameterSets.first, sps.count >= 4, lengthBytes == 4 else { return nil }
        let seconds = sample.presentationTimeStamp.seconds
        guard seconds.isFinite, seconds >= 0 else { return nil }
        // MRV1, keyframe flag, profile/compatibility/level, dimensions, timestamp, Annex B access unit.
        var packet = Data([0x4d, 0x52, 0x56, 1, keyframe ? 1 : 0])
        packet.append(sps.subdata(in: 1..<4))
        var w = UInt16(width).bigEndian
        var h = UInt16(height).bigEndian
        var time = UInt64(seconds * 1_000_000).bigEndian
        withUnsafeBytes(of: &w) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &time) { packet.append(contentsOf: $0) }
        let startCode = Data([0, 0, 0, 1])
        if keyframe {
            for parameter in parameterSets {
                packet.append(startCode)
                packet.append(parameter)
            }
        }
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        guard !avcc.isEmpty else { return nil }
        let status = avcc.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: address)
        }
        guard status == noErr else { return nil }
        var offset = 0
        while offset + 4 <= avcc.count {
            let length = avcc[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length > 0, length <= avcc.count - offset else { return nil }
            packet.append(startCode)
            packet.append(avcc.subdata(in: offset..<offset + length))
            offset += length
        }
        guard offset == avcc.count, packet.count < 768 * 1024 - 28 else { return nil }
        return packet
    }
}
