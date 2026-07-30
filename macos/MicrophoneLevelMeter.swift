import AVFoundation
import CoreGraphics
import Foundation

struct MicrophoneLevelMeter {
    let minimumLevel: CGFloat = 0.12

    private let sampleCount: Int
    private(set) var levels: [CGFloat]
    private var smoothedLevel: CGFloat

    init(sampleCount: Int = 12) {
        self.sampleCount = max(sampleCount, 1)
        levels = Array(repeating: minimumLevel, count: max(sampleCount, 1))
        smoothedLevel = minimumLevel
    }

    mutating func record(amplitude: Float) {
        let clampedAmplitude = CGFloat(min(max(amplitude, 0), 1))
        let targetLevel = minimumLevel + (1 - minimumLevel) * clampedAmplitude
        let smoothing: CGFloat = targetLevel > smoothedLevel ? 0.62 : 0.22
        smoothedLevel += (targetLevel - smoothedLevel) * smoothing
        levels.removeFirst()
        levels.append(smoothedLevel)
    }

    mutating func reset() {
        levels = Array(repeating: minimumLevel, count: sampleCount)
        smoothedLevel = minimumLevel
    }

    nonisolated static func normalizedAmplitude(integerSample: Int32, bitDepth: UInt32) -> Float {
        guard (2...32).contains(bitDepth) else { return 0 }
        let maximumMagnitude = Float((UInt64(1) << (bitDepth - 1)) - 1)
        return min(abs(Float(integerSample)) / maximumMagnitude, 1)
    }

    nonisolated static func peakAmplitude(in sampleBuffer: CMSampleBuffer) -> Float {
        guard sampleBuffer.isValid,
              sampleBuffer.dataReadiness == .ready,
              let format = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM else {
            return 0
        }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        ) == noErr else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        ) == noErr else {
            return 0
        }

        let bytesPerSample = max(Int(description.mBitsPerChannel) / 8, 1)
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / bytesPerSample
            for index in 0..<sampleCount {
                let amplitude: Float
                switch (isFloat, description.mBitsPerChannel) {
                case (true, 32):
                    amplitude = abs(data.assumingMemoryBound(to: Float.self)[index])
                case (true, 64):
                    amplitude = Float(abs(data.assumingMemoryBound(to: Double.self)[index]))
                case (false, 16):
                    amplitude = normalizedAmplitude(
                        integerSample: Int32(data.assumingMemoryBound(to: Int16.self)[index]),
                        bitDepth: 16
                    )
                case (false, 24):
                    let bytes = data.assumingMemoryBound(to: UInt8.self)
                    let offset = index * 3
                    let raw = UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                    let signedSample = Int32(bitPattern: raw & 0x80_0000 == 0 ? raw : raw | 0xFF00_0000)
                    amplitude = normalizedAmplitude(integerSample: signedSample, bitDepth: 24)
                case (false, 32):
                    amplitude = normalizedAmplitude(
                        integerSample: data.assumingMemoryBound(to: Int32.self)[index],
                        bitDepth: 32
                    )
                default:
                    continue
                }
                peak = max(peak, min(amplitude, 1))
            }
        }
        return peak
    }
}
