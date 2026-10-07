import ScreenCaptureKit
import AVFoundation
import os

/// Tunable capture parameters.
enum AudioEngineConfig {
    /// Internal sample rate everything downstream (FFT, band math) assumes. ScreenCaptureKit is
    /// asked for this rate directly; if a buffer ever arrives at a different rate it is resampled,
    /// so band boundaries stay stable across headphones/speakers with different native rates.
    static let targetSampleRate: Double = 48_000
    /// Ring buffer capacity in frames per channel — at least 4x the FFT window (see
    /// `FFTConfig.windowSize`) so the capture callback never waits on the analysis side.
    static let ringBufferCapacity = 8192
    /// Log a repeating per-buffer failure on its first occurrence and then once every this many
    /// occurrences, so a persistent problem is visible without flooding the log at ~47 Hz.
    static let failureLogInterval = 500
    /// Unreadable buffers in a row after which the stream counts as broken rather than unlucky
    /// and is given up for a fresh one. ScreenCaptureKit delivers about 50 buffers a second, so 25
    /// is half a second of audio. Sane range: 5–100.
    static let unreadableBufferRun = 25
}

/// Captures system audio output — never the microphone — via ScreenCaptureKit and feeds 48kHz
/// stereo Float32 frames into `ringBuffer`, which `BeatDetector` reads as audio arrives (polling while idle).
///
/// ScreenCaptureKit over CoreAudio process taps: both need the same Screen & System Audio
/// Recording permission, and taps would mean hand-building an aggregate-device dictionary and
/// driving raw IOProc callbacks. SCStream's cost is a throwaway 2x2 video stream, since a content
/// filter must be tied to a display even when only `.audio` is consumed.
///
/// This class is the control plane (permission, start/stop) and lives on the main actor. Sample
/// delivery happens on `sampleQueue` inside `AudioSampleProcessor`, which is deliberately NOT
/// main-actor-isolated: hopping actors per audio callback would add jitter on a thread that must
/// never allocate or wait.
///
/// No microphone API is used anywhere in the app — no `AVAudioEngine.inputNode`, no
/// `AVCaptureDevice` audio input, no `NSMicrophoneUsageDescription`. If the orange microphone
/// indicator ever lights up, that's a bug.
@MainActor
final class AudioEngine: NSObject {
    enum PermissionState {
        case unknown, granted, denied
    }

    /// `start()` and `stop()` change this synchronously and leave only the ScreenCaptureKit calls
    /// to background tasks, so a caller that checks `isStarting`/`isCapturing` right after either
    /// call — or calls the other one in the same turn — always sees where things are headed. The
    /// generation counter lets an in-flight start notice it was superseded and tear down whatever
    /// it created. `.starting` carries the stream and processor as soon as they exist, so `stop()`
    /// can silence the processor immediately and a stream that dies mid-start is recognized.
    private enum Lifecycle {
        case idle
        case starting(generation: Int, stream: SCStream?, processor: AudioSampleProcessor?)
        case running(SCStream, processor: AudioSampleProcessor, display: CGDirectDisplayID, since: TimeInterval)
    }

    private let logger = Logger(subsystem: "com.openglow.app", category: "AudioEngine")
    private var lifecycle: Lifecycle = .idle
    private var generation = 0
    private let screenOutput = DiscardingScreenOutput()
    private let sampleQueue = DispatchQueue(label: "com.openglow.audio.samples", qos: .userInteractive)
    private let screenQueue = DispatchQueue(label: "com.openglow.audio.video-discard", qos: .background)

    let ringBuffer = AudioRingBuffer(capacity: AudioEngineConfig.ringBufferCapacity)

    private(set) var permissionState: PermissionState = .unknown
    private var access = CaptureAccess()

    /// Called on the main actor after every lifecycle change: starting, running, stopped, failed.
    var onStateChange: (() -> Void)?

    /// Called on the main actor when a starting or running stream stops without being asked to:
    /// why, and how long it had been running (0 if it never finished starting).
    var onUnexpectedStop: ((_ cause: CaptureStopCause, _ ranFor: TimeInterval) -> Void)?

    /// Called on the main actor when `start()` fails (as opposed to being superseded by `stop()`).
    var onStartFailed: ((_ cause: CaptureStopCause) -> Void)?

    /// Why capture most recently failed to start or stopped unexpectedly. Kept while a retry
    /// starts; nil once capture runs, and after a deliberate `stop()`.
    private(set) var lastFailure: CaptureFailure?

    /// How readable the running stream's buffers are; all zero when not running.
    var captureHealth: CaptureHealth {
        if case .running(_, let processor, _, _) = lifecycle { return processor.health }
        return CaptureHealth()
    }

    /// The display the running stream's content filter is tied to. ScreenCaptureKit needs one
    /// even for audio, so the stream is restarted when that display goes away.
    var captureDisplayID: CGDirectDisplayID? {
        if case .running(_, _, let display, _) = lifecycle { return display }
        return nil
    }

    var isCapturing: Bool {
        if case .running = lifecycle { return true }
        return false
    }

    var isStarting: Bool {
        if case .starting = lifecycle { return true }
        return false
    }

    /// Checks current authorization without prompting. This is a live query to the privacy
    /// service on every call — but only as long as `CGRequestScreenCaptureAccess` is never called
    /// in this process: after that call, macOS caches its answer for the rest of the process's
    /// life and this would keep returning it even after the user grants access. So this app
    /// never calls it. A refusal from ScreenCaptureKit itself overrules a yes (see `CaptureAccess`).
    @discardableResult
    func checkPermission() -> PermissionState {
        permissionState = access.evaluate(preflight: CGPreflightScreenCaptureAccess())
        return permissionState
    }

    /// The user asked to try again: a refusal from ScreenCaptureKit no longer holds back the next
    /// `start()`.
    func allowRetryAfterRefusal() {
        access.userRetried()
    }

    /// Asks ScreenCaptureKit for shareable content once. When access is undecided this makes
    /// macOS show its permission prompt and list Open Glow under Screen & System Audio Recording;
    /// the check behind it lives outside this process, so unlike `CGRequestScreenCaptureAccess`
    /// it doesn't freeze `checkPermission()`. Failing is expected when access isn't granted yet.
    func registerForScreenRecording() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            logger.notice("Screen Recording access request: \(error.localizedDescription, privacy: .public)")
        }
        checkPermission()
    }

    /// Begins capture and returns at once, already `.starting`. Does nothing if capture is
    /// already starting or running, or if access isn't granted.
    func start() {
        guard case .idle = lifecycle else { return }
        guard checkPermission() == .granted else {
            logger.error("Capture not started: Screen Recording preflight returned false")
            return
        }
        generation += 1
        let myGeneration = generation
        lifecycle = .starting(generation: myGeneration, stream: nil, processor: nil)
        ringBuffer.reset()
        onStateChange?()
        Task { await performStart(generation: myGeneration) }
    }

    private func performStart(generation myGeneration: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isStillStarting(myGeneration) else { return }

            let mainDisplayID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
                logger.error("Capture not started: SCShareableContent returned no displays")
                failStart(myGeneration, CaptureFailure(cause: .failed, reason: "No display is available to attach audio capture to."))
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            // Our own process makes no sound, but excluding it keeps a future UI sound from
            // feeding back into the glow.
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(AudioEngineConfig.targetSampleRate)
            config.channelCount = 2
            // The video half of the stream exists only because SCStream requires a display
            // filter: keep it as small and infrequent as the API allows.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: AudioEngineConfig.targetSampleRate, channels: 2) else {
                logger.error("Capture not started: could not build the 48kHz stereo target format")
                failStart(myGeneration, CaptureFailure(cause: .failed, reason: "The audio format couldn't be set up."))
                return
            }
            let processor = AudioSampleProcessor(ringBuffer: ringBuffer, targetFormat: targetFormat) { [weak self] processor in
                let id = ObjectIdentifier(processor)
                Task { @MainActor in self?.abandonUnreadableStream(processorID: id) }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            lifecycle = .starting(generation: myGeneration, stream: stream, processor: processor)

            try stream.addStreamOutput(processor, type: .audio, sampleHandlerQueue: sampleQueue)
            // Without a .screen output, ScreenCaptureKit logs a dropped-frame error for every
            // video frame it can't deliver; this sink accepts and ignores them.
            try stream.addStreamOutput(screenOutput, type: .screen, sampleHandlerQueue: screenQueue)
            try await stream.startCapture()

            guard isStillStarting(myGeneration) else {
                // stop() ran while startCapture was in flight, or the stream already died: honor it.
                processor.cancel()
                try? await stream.stopCapture()
                return
            }
            lifecycle = .running(stream, processor: processor, display: display.displayID, since: ProcessInfo.processInfo.systemUptime)
            lastFailure = nil
            logger.notice("Audio capture started on display \(display.displayID, privacy: .public)")
            onStateChange?()
        } catch {
            logger.error("Capture failed to start: \(error.localizedDescription, privacy: .public)")
            failStart(myGeneration, CaptureFailure(cause: .classify(error), reason: error.localizedDescription))
        }
    }

    /// Ends a start that failed on its own. A start that `stop()` superseded ends quietly.
    private func failStart(_ generation: Int, _ failure: CaptureFailure) {
        guard isStillStarting(generation) else { return }
        if case .starting(_, _, let processor) = lifecycle { processor?.cancel() }
        lifecycle = .idle
        lastFailure = failure
        noteRefusal(failure.cause)
        onStateChange?()
        onStartFailed?(failure.cause)
    }

    private func noteRefusal(_ cause: CaptureStopCause) {
        guard cause == .accessDenied else { return }
        access.captureRefused()
        permissionState = .denied
        logger.error("ScreenCaptureKit refused capture: Screen & System Audio Recording access is missing")
    }

    /// Stops capture and returns at once, already `.idle`; the stream finishes stopping in the
    /// background. Also clears `lastFailure`: a deliberate stop ends any failure episode.
    func stop() {
        generation += 1
        lastFailure = nil
        switch lifecycle {
        case .idle:
            return
        case .starting(_, _, let processor):
            // Silence the in-flight start's processor now; that start sees the generation change
            // after its next await and tears down whatever else it has created.
            processor?.cancel()
        case .running(let stream, let processor, _, _):
            processor.cancel()
            Task { [logger] in
                do {
                    try await stream.stopCapture()
                } catch {
                    logger.error("Capture did not stop cleanly: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        lifecycle = .idle
        // The cancelled processor can't write any more, so nothing stale survives this reset.
        ringBuffer.reset()
        logger.notice("Audio capture stopped")
        onStateChange?()
    }

    private func isStillStarting(_ generation: Int) -> Bool {
        if case .starting(let current, _, _) = lifecycle, current == generation { return true }
        return false
    }

    fileprivate func handleStreamStopped(_ streamID: ObjectIdentifier, _ failure: CaptureFailure) {
        let processor: AudioSampleProcessor?
        let ranFor: TimeInterval
        switch lifecycle {
        case .running(let current, let running, _, let since) where ObjectIdentifier(current) == streamID:
            processor = running
            ranFor = ProcessInfo.processInfo.systemUptime - since
        case .starting(_, let current?, let starting) where ObjectIdentifier(current) == streamID:
            // Died before startCapture() returned; that start sees the generation change and
            // stands down instead of marking a dead stream as running.
            processor = starting
            ranFor = 0
        default:
            // A late callback for an old stream must not tear down a newer one.
            return
        }
        streamEnded(processor: processor, ranFor: ranFor, failure)
    }

    /// The stream whose processor is `processorID` delivers only buffers that can't be read — a
    /// format the converter can't take, typically after an output-device change. Gives it up like
    /// a stream that stopped, so the app's retry starts a fresh one that negotiates its format anew.
    private func abandonUnreadableStream(processorID: ObjectIdentifier) {
        let processor: AudioSampleProcessor
        let ranFor: TimeInterval
        switch lifecycle {
        case .running(let stream, let running, _, let since) where ObjectIdentifier(running) == processorID:
            processor = running
            ranFor = ProcessInfo.processInfo.systemUptime - since
            Task { [logger] in
                do {
                    try await stream.stopCapture()
                } catch {
                    logger.error("Unreadable capture did not stop cleanly: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .starting(_, _, let starting?) where ObjectIdentifier(starting) == processorID:
            // The in-flight start sees the generation change and stops the stream itself.
            processor = starting
            ranFor = 0
        default:
            return
        }
        streamEnded(processor: processor, ranFor: ranFor, CaptureFailure(cause: .unreadable, reason: "macOS delivered audio Open Glow couldn't read."))
    }

    private func streamEnded(processor: AudioSampleProcessor?, ranFor: TimeInterval, _ failure: CaptureFailure) {
        generation += 1
        lifecycle = .idle
        processor?.cancel()
        ringBuffer.reset()
        lastFailure = failure
        logger.error("Audio capture stopped unexpectedly: \(failure.reason, privacy: .public)")
        noteRefusal(failure.cause)
        onStateChange?()
        onUnexpectedStop?(failure.cause, ranFor)
    }
}

extension AudioEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let streamID = ObjectIdentifier(stream)
        let failure = CaptureFailure(cause: .classify(error), reason: error.localizedDescription)
        Task { @MainActor [weak self] in
            self?.handleStreamStopped(streamID, failure)
        }
    }
}

/// Accepts and discards the stream's 2x2 video frames.
private final class DiscardingScreenOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

/// Hands a single input buffer to `AVAudioConverter`'s pull callback exactly once. A class (not a
/// captured `var`) because the callback is `@Sendable`; it only ever runs synchronously inside
/// `convert`, on the sample queue.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// Runs entirely on the ScreenCaptureKit sample-delivery queue, never the main actor, and writes
/// 48kHz stereo Float32 frames into the ring buffer.
///
/// ScreenCaptureKit delivers deinterleaved Float32 (one AudioBuffer per channel).
/// `CMSampleBuffer.withAudioBufferList` sizes the buffer list for the real channel count; the
/// previous version passed a list with room for a single AudioBuffer, which fails with
/// kCMSampleBufferError_ArrayTooSmall (-12737) for stereo, so no audio ever reached analysis.
///
/// When the delivered format already matches the target (the normal case), channel pointers are
/// copied straight into the ring buffer with no allocation. Anything else goes through an
/// `AVAudioConverter` using the pull-callback API — the one-shot `convert(to:from:)` can't change
/// sample rate. The format is checked on every buffer, so a stream that changes format midway
/// (after an output-device change, say) gets a converter built for the new one; one that goes
/// back to the target format drops its converter, so returning to the old format later starts
/// from fresh resampler state instead of splicing in the tail of audio from before.
///
/// `@unchecked Sendable`: mutable state is only touched on the serial sample queue (SCStream
/// delivers to one queue serially); `cancelled` and `sharedHealth` are lock-protected because the
/// main actor uses them.
final class AudioSampleProcessor: NSObject, SCStreamOutput, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.openglow.app", category: "AudioCapture")
    private let ringBuffer: AudioRingBuffer
    private let targetFormat: AVAudioFormat
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var converterSourceASBD: AudioStreamBasicDescription?
    private var outputBuffer: AVAudioPCMBuffer?
    private var loggedFirstBuffer = false
    private var failureCount = 0
    /// Whether the buffer being ingested has reported a failure.
    private var bufferFailed = false
    /// Sample-queue copy of `sharedHealth.droppedInARow`, so a readable buffer only takes the
    /// lock when it ends a run of failures.
    private var droppedInARow = 0
    private let sharedHealth = OSAllocatedUnfairLock(initialState: CaptureHealth())
    private let onUnreadable: (@Sendable (AudioSampleProcessor) -> Void)?

    /// How readable the buffers have been so far. Read from the main actor.
    var health: CaptureHealth { sharedHealth.withLock { $0 } }

    /// `onUnreadable` runs on the sample queue, once each time a run of unreadable buffers
    /// reaches `AudioEngineConfig.unreadableBufferRun`.
    init(ringBuffer: AudioRingBuffer, targetFormat: AVAudioFormat, onUnreadable: (@Sendable (AudioSampleProcessor) -> Void)? = nil) {
        self.ringBuffer = ringBuffer
        self.targetFormat = targetFormat
        self.onUnreadable = onUnreadable
    }

    /// Stops writing into the ring buffer immediately, even if the stream delivers a few more
    /// buffers while it shuts down.
    func cancel() {
        cancelled.withLock { $0 = true }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        ingest(sampleBuffer)
    }

    /// Writes one captured audio buffer into the ring buffer. Separate from the SCStream callback
    /// so tests can feed synthetic buffers in each layout ScreenCaptureKit might deliver.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard !cancelled.withLock({ $0 }), sampleBuffer.isValid else { return }
        bufferFailed = false
        defer { if !bufferFailed { bufferWasReadable() } }
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = formatDescription.audioStreamBasicDescription else {
            reportFailure("audio buffer has no stream description")
            return
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            logger.notice("First audio buffer: \(asbd.mSampleRate, privacy: .public) Hz, \(asbd.mChannelsPerFrame, privacy: .public) ch, flags \(asbd.mFormatFlags, privacy: .public), \(frames, privacy: .public) frames")
        }

        do {
            try sampleBuffer.withAudioBufferList { bufferList, _ in
                if Self.isDirectlyUsable(asbd) {
                    if converter != nil { dropConverter() }
                    writeDirect(bufferList, channels: Int(asbd.mChannelsPerFrame), frames: frames)
                } else {
                    convertAndWrite(bufferList, asbd: asbd, formatDescription: formatDescription, frames: frames)
                }
            }
        } catch {
            reportFailure("could not read audio buffer list: \(error.localizedDescription)")
        }
    }

    private static func isDirectlyUsable(_ asbd: AudioStreamBasicDescription) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            && asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && asbd.mBitsPerChannel == 32
            && (asbd.mChannelsPerFrame == 1 || asbd.mChannelsPerFrame == 2)
            && asbd.mSampleRate == AudioEngineConfig.targetSampleRate
    }

    private func writeDirect(_ bufferList: UnsafeMutableAudioBufferListPointer, channels: Int, frames: Int) {
        guard bufferList.count >= channels,
              let left = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else {
            reportFailure("buffer list has \(bufferList.count) buffers for \(channels) channels")
            return
        }
        // Mono content drives both edges equally.
        let rightBuffer = channels > 1 ? bufferList[1] : bufferList[0]
        guard let right = rightBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            reportFailure("right channel has no data")
            return
        }
        let available = Int(min(bufferList[0].mDataByteSize, rightBuffer.mDataByteSize)) / MemoryLayout<Float>.size
        ringBuffer.write(left: left, right: right, count: min(frames, available))
    }

    private func convertAndWrite(
        _ bufferList: UnsafeMutableAudioBufferListPointer,
        asbd: AudioStreamBasicDescription,
        formatDescription: CMFormatDescription,
        frames: Int
    ) {
        if converter == nil || !Self.sameFormat(asbd, converterSourceASBD) {
            guard let (sourceFormat, newConverter) = makeConverter(asbd, formatDescription: formatDescription) else {
                reportFailure("unsupported capture format: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, flags \(asbd.mFormatFlags)")
                return
            }
            // Only remember the format once a converter for it actually exists, so a failure is
            // retried on the next buffer instead of being cached forever.
            converter = newConverter
            converterSourceFormat = sourceFormat
            converterSourceASBD = asbd
            logger.notice("Converting capture format \(asbd.mSampleRate, privacy: .public) Hz / \(asbd.mChannelsPerFrame, privacy: .public) ch / flags \(asbd.mFormatFlags, privacy: .public) to 48kHz stereo")
        }
        guard let converter, let sourceFormat = converterSourceFormat,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: bufferList.unsafePointer) else {
            reportFailure("could not wrap the capture buffer for conversion")
            return
        }
        input.frameLength = AVAudioFrameCount(min(frames, Int(input.frameCapacity)))

        let needed = AVAudioFrameCount((Double(input.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)) + 64
        if outputBuffer.map({ $0.frameCapacity < needed }) ?? true {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: needed)
        }
        guard let output = outputBuffer else {
            reportFailure("could not allocate the conversion buffer")
            return
        }
        output.frameLength = 0

        let feeder = OneShotInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if let buffer = feeder.take() {
                inputStatus.pointee = .haveData
                return buffer
            }
            // .noDataNow (not .endOfStream) keeps the resampler's state for the next buffer.
            inputStatus.pointee = .noDataNow
            return nil
        }
        if status == .error {
            reportFailure("conversion failed: \(conversionError?.localizedDescription ?? "unknown error")")
            return
        }
        guard output.frameLength > 0, let channels = output.floatChannelData else { return }
        let right = targetFormat.channelCount > 1 ? channels[1] : channels[0]
        ringBuffer.write(left: channels[0], right: right, count: Int(output.frameLength))
    }

    /// A converter from `asbd` to the target format. Beyond two channels AVAudioFormat needs a
    /// channel layout: the stream's own when it has a known one (then downmixed, so center and
    /// surrounds count), otherwise the first two channels are taken as left and right — without
    /// that map a discrete layout converts to silence.
    private func makeConverter(_ asbd: AudioStreamBasicDescription, formatDescription: CMFormatDescription) -> (AVAudioFormat, AVAudioConverter)? {
        var description = asbd
        let channels = asbd.mChannelsPerFrame
        guard channels > 2 else {
            guard let format = AVAudioFormat(streamDescription: &description),
                  let converter = AVAudioConverter(from: format, to: targetFormat) else { return nil }
            return (format, converter)
        }
        var layoutSize = 0
        let streamLayout = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &layoutSize)
            .flatMap { AVAudioChannelLayout(layout: $0) }
            .flatMap { $0.channelCount == channels ? $0 : nil }
        let isDiscrete = streamLayout.map { $0.layoutTag & 0xFFFF_0000 == kAudioChannelLayoutTag_DiscreteInOrder } ?? true
        guard let layout = (isDiscrete ? nil : streamLayout) ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels),
              let format = AVAudioFormat(streamDescription: &description, channelLayout: layout),
              let converter = AVAudioConverter(from: format, to: targetFormat) else { return nil }
        if isDiscrete {
            converter.channelMap = [0, 1]
        } else {
            converter.downmix = true
        }
        return (format, converter)
    }

    private func dropConverter() {
        converter = nil
        converterSourceFormat = nil
        converterSourceASBD = nil
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription?) -> Bool {
        guard let b else { return false }
        return a.mSampleRate == b.mSampleRate
            && a.mFormatID == b.mFormatID
            && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    private func bufferWasReadable() {
        guard droppedInARow > 0 else { return }
        droppedInARow = 0
        sharedHealth.withLock { $0.droppedInARow = 0 }
    }

    private func reportFailure(_ message: String) {
        bufferFailed = true
        failureCount += 1
        droppedInARow += 1
        sharedHealth.withLock {
            $0.droppedBuffers += 1
            $0.droppedInARow += 1
        }
        if failureCount == 1 || failureCount % AudioEngineConfig.failureLogInterval == 0 {
            logger.error("Dropped audio buffer (\(self.failureCount, privacy: .public) so far): \(message, privacy: .public)")
        }
        if droppedInARow == AudioEngineConfig.unreadableBufferRun { onUnreadable?(self) }
    }
}
