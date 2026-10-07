import AVFoundation
import CoreMedia
import os
import Testing
@testable import OpenGlow

/// A CMSampleBuffer in `format`, filled by `sample`, like the ones ScreenCaptureKit hands to the
/// `.audio` output. With `describeLayout` false a multichannel buffer carries no channel layout.
private func makeBuffer(
    _ format: AVAudioFormat,
    frames: Int,
    describeLayout: Bool = true,
    sample: (_ channel: Int, _ frame: Int) -> Float
) throws -> CMSampleBuffer {
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    pcm.frameLength = AVAudioFrameCount(frames)
    let data = try #require(pcm.floatChannelData)
    let channels = Int(format.channelCount)
    for frame in 0..<frames {
        for channel in 0..<channels {
            if format.isInterleaved {
                data[0][frame * channels + channel] = sample(channel, frame)
            } else {
                data[channel][frame] = sample(channel, frame)
            }
        }
    }

    var formatDescription: CMAudioFormatDescription?
    let layout = describeLayout ? format.channelLayout : nil
    let layoutSize = layout.map { _ in MemoryLayout<AudioChannelLayout>.size } ?? 0
    #expect(CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: format.streamDescription, layoutSize: layoutSize, layout: layout?.layout,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
    ) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
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

/// A buffer with samples but no format description: nothing can read it.
private func makeUnreadableBuffer(frames: Int = 480) throws -> CMSampleBuffer {
    var sampleBuffer: CMSampleBuffer?
    #expect(CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: nil, sampleCount: frames, sampleTimingEntryCount: 0,
        sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
    ) == noErr)
    return try #require(sampleBuffer)
}

private func pcmFormat(_ sampleRate: Double, channels: AVAudioChannelCount, interleaved: Bool) throws -> AVAudioFormat {
    try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: interleaved))
}

private func layoutFormat(_ sampleRate: Double, tag: AudioChannelLayoutTag, interleaved: Bool) throws -> AVAudioFormat {
    let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
    return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: interleaved, channelLayout: layout)
}

private func makeProcessor(onUnreadable: (@Sendable (AudioSampleProcessor) -> Void)? = nil) throws -> (AudioSampleProcessor, AudioRingBuffer) {
    let ring = AudioRingBuffer(capacity: AudioEngineConfig.ringBufferCapacity)
    let target = try #require(AVAudioFormat(standardFormatWithSampleRate: AudioEngineConfig.targetSampleRate, channels: 2))
    return (AudioSampleProcessor(ringBuffer: ring, targetFormat: target, onUnreadable: onUnreadable), ring)
}

/// Frames written so far, and the latest `count` of them.
private func latest(_ ring: AudioRingBuffer, count: Int) -> (left: [Float], right: [Float], written: UInt64) {
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    let (available, sequence) = left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in ring.read(left: l.baseAddress!, right: r.baseAddress!, count: count) }
    }
    return (Array(left.prefix(available)), Array(right.prefix(available)), sequence)
}

private func rms(_ values: ArraySlice<Float>) -> Float {
    (values.map { $0 * $0 }.reduce(0, +) / Float(max(values.count, 1))).squareRoot()
}

/// An output-device change can hand the running stream a new format, and then another, and back.
@Suite("Capture formats: changes mid-stream")
struct CaptureFormatChangeTests {
    private struct Segment {
        var format: AVAudioFormat
        var buffers: Int
        /// Constant left and right levels, so each segment's output is recognizable.
        var left: Float
        var right: Float
    }

    @Test func everyFormatChangeKeepsAudioFlowingAtTheTargetRate() throws {
        let (processor, ring) = try makeProcessor()
        let frames = 960
        let segments = [
            Segment(format: try pcmFormat(48_000, channels: 2, interleaved: false), buffers: 10, left: 0.8, right: 0.2),
            Segment(format: try pcmFormat(44_100, channels: 2, interleaved: true), buffers: 20, left: 0.6, right: 0.1),
            Segment(format: try pcmFormat(96_000, channels: 1, interleaved: false), buffers: 20, left: 0.4, right: 0.4),
            Segment(format: try pcmFormat(48_000, channels: 2, interleaved: false), buffers: 10, left: 0.3, right: 0.7),
            Segment(format: try pcmFormat(44_100, channels: 2, interleaved: true), buffers: 20, left: 0.5, right: 0.25),
        ]
        var written: UInt64 = 0
        for segment in segments {
            for _ in 0..<segment.buffers {
                processor.ingest(try makeBuffer(segment.format, frames: frames) { channel, _ in
                    channel == 0 ? segment.left : segment.right
                })
            }
            let expected = Double(segment.buffers * frames) * 48_000 / segment.format.sampleRate
            let (left, right, total) = latest(ring, count: 2048)
            let added = Double(total - written)
            #expect(abs(added - expected) < expected * 0.03 + 64, "\(segment.format): \(added) frames, expected about \(expected)")
            // Past the resampler's settle, the levels are the new format's, on the right sides.
            let tail = 512
            #expect(abs(rms(left.suffix(tail)) - segment.left) < 0.01, "\(segment.format) left")
            #expect(abs(rms(right.suffix(tail)) - segment.right) < 0.01, "\(segment.format) right")
            written = total
        }
        #expect(processor.health == CaptureHealth())
    }

    @Test func sixDiscreteChannelsKeepTheFirstTwo() throws {
        let (processor, ring) = try makeProcessor()
        let format = try layoutFormat(48_000, tag: kAudioChannelLayoutTag_DiscreteInOrder | 6, interleaved: false)
        for _ in 0..<4 {
            processor.ingest(try makeBuffer(format, frames: 960, describeLayout: false) { channel, _ in
                [0.7, 0.3, 0.9, 0.9, 0.9, 0.9][channel]
            })
        }
        let (left, right, total) = latest(ring, count: 1024)
        #expect(total == 4 * 960)
        #expect(abs(rms(left.suffix(512)) - 0.7) < 0.01)
        #expect(abs(rms(right.suffix(512)) - 0.3) < 0.01)
        #expect(processor.health == CaptureHealth())
    }

    @Test func surroundIsDownmixedSoEveryChannelCounts() throws {
        let (processor, ring) = try makeProcessor()
        let format = try layoutFormat(48_000, tag: kAudioChannelLayoutTag_MPEG_5_1_A, interleaved: true)
        // Silence on the front pair; only the center and surrounds carry sound.
        for _ in 0..<4 {
            processor.ingest(try makeBuffer(format, frames: 960) { channel, frame in
                channel < 2 ? 0 : Float(sin(Double(frame) * 0.05)) * 0.5
            })
        }
        let (left, right, total) = latest(ring, count: 1024)
        #expect(total == 4 * 960)
        #expect(rms(left.suffix(512)) > 0.05)
        #expect(rms(right.suffix(512)) > 0.05)
        #expect(processor.health == CaptureHealth())
    }

    /// An unreadable run is reported once when it reaches the threshold; a readable buffer ends
    /// it, and a later run is reported again.
    @Test func runsOfUnreadableBuffersAreReportedOnce() throws {
        let reports = OSAllocatedUnfairLock(initialState: 0)
        let (processor, ring) = try makeProcessor { _ in reports.withLock { $0 += 1 } }
        let run = AudioEngineConfig.unreadableBufferRun
        let readable = try makeBuffer(try pcmFormat(48_000, channels: 2, interleaved: false), frames: 480) { _, _ in 0.5 }
        let unreadable = try makeUnreadableBuffer()

        for _ in 0..<(run - 1) { processor.ingest(unreadable) }
        #expect(reports.withLock { $0 } == 0)
        #expect(!processor.health.isUnreadable)
        processor.ingest(readable)
        #expect(processor.health == CaptureHealth(droppedBuffers: run - 1, droppedInARow: 0))

        for _ in 0..<(run * 3) { processor.ingest(unreadable) }
        #expect(reports.withLock { $0 } == 1)
        #expect(processor.health.isUnreadable)

        processor.ingest(readable)
        #expect(!processor.health.isUnreadable)
        for _ in 0..<run { processor.ingest(unreadable) }
        #expect(reports.withLock { $0 } == 2)
        #expect(latest(ring, count: 1024).written == 2 * 480)
    }

    @Test func aCancelledProcessorIgnoresEverything() throws {
        let reports = OSAllocatedUnfairLock(initialState: 0)
        let (processor, ring) = try makeProcessor { _ in reports.withLock { $0 += 1 } }
        processor.cancel()
        let unreadable = try makeUnreadableBuffer()
        for _ in 0..<(AudioEngineConfig.unreadableBufferRun * 2) { processor.ingest(unreadable) }
        processor.ingest(try makeBuffer(try pcmFormat(48_000, channels: 2, interleaved: false), frames: 480) { _, _ in 0.5 })
        #expect(reports.withLock { $0 } == 0)
        #expect(latest(ring, count: 1024).written == 0)
    }
}
