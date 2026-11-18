import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "macremote.audio")
    let packets: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    override init() {
        var output: AsyncStream<Data>.Continuation!
        packets = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { output = $0 }
        continuation = output
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio, let packet = Self.packet(sample) { continuation.yield(packet) }
    }

    func finish() { continuation.finish() }

    static func packet(_ sample: CMSampleBuffer) -> Data? {
        guard sample.isValid,
              let timestamp = sample.presentationTimeStamp.mediaMicroseconds,
              let format = sample.formatDescription?.audioStreamBasicDescription, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return nil }
        let channels = Int(format.mChannelsPerFrame)
        let frames = sample.numSamples
        guard (1...2).contains(channels), (1...8192).contains(frames),
              (8000...96000).contains(format.mSampleRate) else { return nil }
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        return try? sample.withAudioBufferList { list, _ -> Data? in
            let bufferCount = planar ? channels : 1
            let samplesPerBuffer = planar ? frames : frames * channels
            guard list.count == bufferCount else { return nil }
            let buffers = list.compactMap { buffer -> UnsafePointer<Float>? in
                guard buffer.mDataByteSize >= samplesPerBuffer * MemoryLayout<Float>.stride,
                      let data = buffer.mData else { return nil }
                return UnsafePointer(data.assumingMemoryBound(to: Float.self))
            }
            guard buffers.count == bufferCount else { return nil }

            // Timestamp and sample rate are big-endian. Signed PCM samples are interleaved, little-endian.
            var time = timestamp.bigEndian
            var rate = UInt32(format.mSampleRate).bigEndian
            var packet = Data(capacity: 13 + frames * channels * 2)
            withUnsafeBytes(of: &time) { packet.append(contentsOf: $0) }
            withUnsafeBytes(of: &rate) { packet.append(contentsOf: $0) }
            packet.append(UInt8(channels))
            var pcm = [Int16](repeating: 0, count: frames * channels)
            for index in pcm.indices {
                let value = planar ? buffers[index % channels][index / channels] : buffers[0][index]
                if value.isFinite { pcm[index] = Int16(max(-1, min(1, value)) * 32767).littleEndian }
            }
            pcm.withUnsafeBytes { packet.append(contentsOf: $0) }
            return packet
        }
    }
}

extension CMTime {
    var mediaMicroseconds: UInt64? {
        let seconds = seconds
        guard seconds.isFinite, seconds >= 0, seconds < 9_000_000_000 else { return nil }
        return UInt64(seconds * 1_000_000)
    }
}
