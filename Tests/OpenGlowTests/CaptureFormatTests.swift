import AVFoundation
import CoreMedia
import Testing
@testable import OpenGlow

/// Builds a CMSampleBuffer like the ones ScreenCaptureKit hands to the `.audio` output.
private func makeSampleBuffer(
    sampleRate: Double,
    channels: AVAudioChannelCount,
    interleaved: Bool,
    frames: Int,
    sample: (_ channel: Int, _ frame: Int) -> Float
) throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: interleaved))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    pcm.frameLength = AVAudioFrameCount(frames)
    let data = try #require(pcm.floatChannelData)
    for frame in 0..<frames {
        for channel in 0..<Int(channels) {
            if interleaved {
                data[0][frame * Int(channels) + channel] = sample(channel, frame)
            } else {
                data[channel][frame] = sample(channel, frame)
            }
        }
    }

    var formatDescription: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
    ) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    #expect(CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
    ) == noErr)
    let buffer = try #require(sampleBuffer)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
        buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList
    ) == noErr)
    return buffer
}

private func makeProcessor() throws -> (AudioSampleProcessor, AudioRingBuffer) {
    let ring = AudioRingBuffer(capacity: AudioEngineConfig.ringBufferCapacity)
    let target = try #require(AVAudioFormat(standardFormatWithSampleRate: AudioEngineConfig.targetSampleRate, channels: 2))
    return (AudioSampleProcessor(ringBuffer: ring, targetFormat: target), ring)
}

private func readAll(_ ring: AudioRingBuffer) -> (left: [Float], right: [Float], sequence: UInt64) {
    var left = [Float](repeating: 0, count: ring.capacity)
    var right = [Float](repeating: 0, count: ring.capacity)
    let (available, sequence) = left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in ring.read(left: l.baseAddress!, right: r.baseAddress!, count: ring.capacity) }
    }
    return (Array(left.prefix(available)), Array(right.prefix(available)), sequence)
}

@Suite("Capture formats")
struct CaptureFormatTests {
    /// ScreenCaptureKit's actual layout. The original code failed on exactly this with
    /// kCMSampleBufferError_ArrayTooSmall, so no audio ever reached analysis.
    @Test func deinterleavedStereoAt48kHzReachesTheRingBuffer() throws {
        let (processor, ring) = try makeProcessor()
        let buffer = try makeSampleBuffer(sampleRate: 48_000, channels: 2, interleaved: false, frames: 1024) { channel, _ in
            channel == 0 ? 0.8 : 0.2
        }
        processor.ingest(buffer)

        let (left, right, sequence) = readAll(ring)
        #expect(sequence == 1024)
        #expect(left.count == 1024)
        #expect(left.allSatisfy { $0 == 0.8 })
        #expect(right.allSatisfy { $0 == 0.2 })
    }

    @Test func interleavedStereoIsConverted() throws {
        let (processor, ring) = try makeProcessor()
        let buffer = try makeSampleBuffer(sampleRate: 48_000, channels: 2, interleaved: true, frames: 1024) { channel, _ in
            channel == 0 ? 0.8 : 0.2
        }
        processor.ingest(buffer)

        let (left, right, _) = readAll(ring)
        #expect(left.count == 1024)
        #expect(left.allSatisfy { abs($0 - 0.8) < 1e-5 })
        #expect(right.allSatisfy { abs($0 - 0.2) < 1e-5 })
    }

    @Test func mono44_1kHzIsResampledTo48kHzOnBothChannels() throws {
        let (processor, ring) = try makeProcessor()
        let buffers = 10
        let frames = 1024
        for index in 0..<buffers {
            let buffer = try makeSampleBuffer(sampleRate: 44_100, channels: 1, interleaved: false, frames: frames) { _, frame in
                Float(sin(2 * Double.pi * 440 * Double(index * frames + frame) / 44_100)) * 0.5
            }
            processor.ingest(buffer)
        }

        let (left, right, sequence) = readAll(ring)
        let expected = Double(buffers * frames) * 48_000 / 44_100
        #expect(abs(Double(sequence) - expected) < expected * 0.02, "resampled \(sequence) frames, expected about \(Int(expected))")
        #expect(left == right, "mono content should drive both edges equally")
        let rms = sqrt(left.suffix(4096).map { $0 * $0 }.reduce(0, +) / 4096)
        #expect(abs(rms - 0.5 / Float(2).squareRoot()) < 0.02, "resampled RMS \(rms) should match the 0.5-amplitude sine")
    }
}
