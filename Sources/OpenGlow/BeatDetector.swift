import Accelerate
import Foundation
import os

/// FFT and analysis-cadence tuning. Kept together since changing `windowSize` changes the
/// frequency resolution of everything below it.
enum FFTConfig {
    /// FFT window size in samples. 2048 samples @ 48kHz ≈ 42.7ms of audio per window — a
    /// reasonable trade-off between frequency resolution (bin width ≈ 23Hz) and time resolution
    /// for beat detection. Must be a power of two.
    static let windowSize = 2048
    static let log2Size = vDSP_Length(log2(Double(windowSize)))
    /// Samples between analyzed windows (75% overlap). Every hop of captured audio is analyzed
    /// exactly once, however ScreenCaptureKit happens to chunk its delivery.
    static let hopSize = 512
    static var hopDuration: TimeInterval { Double(hopSize) / AudioEngineConfig.targetSampleRate }
    /// Most hops analyzed in one tick; a bigger backlog (the analysis queue was starved) skips
    /// ahead to recent audio rather than falling further behind.
    static let maxCatchUpHops = 8
    /// Frequency range analyzed for onsets (snares, hats, plucks — anything percussive).
    static let fluxBand: ClosedRange<Double> = 30...12_000
    /// Sub-range watched separately for kicks, which carry most of a beat's visual weight and
    /// would be diluted in a full-band average.
    static let kickBand: ClosedRange<Double> = 30...250
}

/// Frequency band boundaries in Hz.
enum FrequencyBands {
    static let bass: ClosedRange<Double> = 20...250
    static let mid: ClosedRange<Double> = 250...4_000
    static let treble: ClosedRange<Double> = 4_000...16_000
}

/// Envelope, beat, gate and normalization tuning — these are the "feel" knobs.
enum EnvelopeConfig {
    /// Seconds for a band's displayed energy to rise toward a louder value. Short, so transients
    /// read as sharp rather than mushy. Sane range: 0.002–0.03.
    static let attackSeconds: Double = 0.005
    /// Seconds for it to fall back after the signal quiets. Long relative to attack so the glow
    /// decays visibly instead of flickering. Sane range: 0.08–0.4.
    static let releaseSeconds: Double = 0.150
    /// Seconds for a beat pulse to decay — a beat reads as a spike with its own falloff rather
    /// than riding the bass envelope. Sane range: 0.1–0.4.
    static let beatDecaySeconds: Double = 0.220
    /// Minimum seconds of audio between beats, so one kick's decay tail can't fire several.
    static let refractoryPeriod: TimeInterval = 0.100

    /// Seconds of onset-strength history for the adaptive onset threshold.
    static let fluxHistoryDuration: TimeInterval = 1.0
    /// A kick-band onset needs strength above the median of the last second plus this margin,
    /// in nats of log-magnitude rise averaged over the band. Onset strength doesn't depend on
    /// volume, so a fixed margin means the same thing for loud and quiet music, and the median
    /// (unlike a mean/σ threshold) isn't inflated by the kicks themselves. Measured on 45 real
    /// tracks: 0.45 catches ~56% of kicks at full strength with ~78% precision and ~0.08
    /// full-strength flashes/s on beatless pads; 0.4 catches more but flashes more on pads, 0.5
    /// fewer of both. Sane range: 0.35–0.6.
    static let kickOnsetMargin: Float = 0.45
    /// A kick-band onset also needs the kick band to hold at least this share (dB) of the
    /// analyzed power, so low-frequency bleed under hi-hats can't fire kick beats.
    static let kickMinimumShareDb: Float = -10
    /// If the full band fires a hop or two before the kick band on the same hit (the beater click
    /// or a hat on the downbeat), a kick crossing within this many seconds counts as that beat's
    /// kick (it's sized as one) instead of being lost to the refractory period.
    static let kickUpgradeWindow: TimeInterval = 0.04
    /// The same margin for the full band (snares, hats, plucks). Noise and pads sit within
    /// ≈0.03 of their median here. Sane range: 0.03–0.12.
    static let fullOnsetMargin: Float = 0.05
    /// Quiet bins are floored this far below the window's mean magnitude (0.01 = -40dB) before
    /// taking logs, so near-empty bins can't produce huge random log changes.
    static let onsetLogFloor: Float = 0.01

    /// Per-band loudness normalization works in dB against a rolling ceiling and floor, so each
    /// band spans 0...1 over the range the current track actually uses. dB/second the ceiling
    /// relaxes after a loud peak (also through pauses, so a quieter next track isn't squashed).
    static let loudnessCeilingDecayDbPerSecond: Float = 3
    /// dB/second the floor creeps up toward the current level after a quiet moment.
    static let loudnessFloorRiseDbPerSecond: Float = 3
    /// Minimum dB spread between floor and ceiling, so near-constant material isn't stretched
    /// into full-scale flicker. Sane range: 12–30.
    static let loudnessMinimumRangeDb: Float = 18
    /// A band this many dB below the loudest band reads as 0 rather than being stretched to full
    /// scale on its own (a hi-hat-only intro must not throb the bass). Sane range: 20–50.
    static let bandRelativeFloorDb: Float = 20
    /// Seconds for the shared stereo peak (left/right normalization) to relax after loud audio.
    static let stereoPeakDecaySeconds: Double = 6.0

    /// Level (linear RMS of both channels) that opens the gate, ≈ -52dBFS. Typical music sits
    /// at -16 to -28dBFS RMS; only very quiet recordings come near this.
    static let gateOpenLevel: Float = 0.0025
    /// Level below which the gate starts closing, ≈ -58dBFS. The gap between the two is
    /// hysteresis: audio hovering around one threshold doesn't flip the glow on and off.
    static let gateCloseLevel: Float = 0.00125
    /// Seconds the level must stay below `gateCloseLevel` before the gate actually closes.
    static let gateCloseHold: TimeInterval = 0.25
    /// Seconds with the gate closed (or no audio arriving) before the idle glow takes over.
    static let silenceTimeout: TimeInterval = 3.0
    /// If no new frames arrive for this long, capture has stalled (player paused, stream
    /// stopped): the buffered audio is discarded and treated as silence.
    static let staleAudioTimeout: TimeInterval = 0.3
    /// If capture delivers nothing at all this long after starting, log an error — "nothing
    /// arrived" must not look identical to "quiet music".
    static let noAudioWarningDelay: TimeInterval = 3.0
    /// Seconds between analysis ticks while nothing is playing. The ring buffer holds ~170ms,
    /// so a 50ms poll can't miss audio resuming. While music plays, each delivery of captured
    /// audio triggers a tick instead (see `BeatDetector`).
    static let idlePollInterval: TimeInterval = 0.05
    /// Seconds between backup ticks while music plays. Ticks then follow audio deliveries, so
    /// these only notice a stalled capture (`staleAudioTimeout`), at most this much late.
    /// Sane range: 0.05–0.15.
    static let deliveryWatchdogInterval: TimeInterval = 0.1
}

/// Beat sizing: how big each detected beat looks, 0...1 (see `BeatSizer`). Large hits — accented
/// kicks, drops, hits in loud sections — fire the full burst; ghost notes, soft kicks, hat and
/// snare ticks and quiet passages only a subtle move. Tuned on the same 45 real tracks as the
/// onset margins.
enum BeatSizeConfig {
    /// Hops after the onset hop during which a beat may still grow: detection fires early in the
    /// attack, before the hit's low end peaks. 3 hops ≈ 32ms, inside `kickUpgradeWindow`, so an
    /// upgrading kick always lands inside it. Sane range: 2–4.
    static let growthHops = 3
    /// dB/second the reference (the loudest recent hit's low end) relaxes, so a quieter section
    /// reads as quieter for a while and then comes back to full size: 12dB down reads small for
    /// ≈2s, large again after ≈5s and full after ≈7s. Sane range: 1–3.
    static let referenceDecayDbPerSecond: Float = 1.5
    /// A kick whose low end peaks within this many dB of the reference is full size, so equal
    /// kicks of a steady loop all burst despite a dB or two of jitter. Sane range: 0–4.
    static let fullSizeWithinDb: Float = 2
    /// Further below the reference, size falls to `minimumSize` over this many dB: a kick 6dB
    /// under the last accent comes out ≈0.8, one 12dB under ≈0.06. Sane range: 6–16.
    static let sizeRangeDb: Float = 10
    /// Kick-band onset strength above its running median (nats, peak over the growth hops) at or
    /// below which a hit had no low-end onset of its own — a hat, snare or pluck over whatever
    /// the bass is doing. Hats in real mixes sit ≈0.03, kicks ≈0.5. Sane range: 0.05–0.15.
    static let kickEvidenceLow: Float = 0.1
    /// …and at or above which it counts fully as a kick. Sane range: 0.15–0.45.
    static let kickEvidenceHigh: Float = 0.2
    /// Size factor (before the response curve) for a hit with no low-end onset: such beats top
    /// out ≈0.08 however loud the mix. 0...1.
    static let nonKickWeight: Float = 0.1
    /// Smallest size any beat gets, so even a ghost note moves the glow a little. 0...0.3.
    static let minimumSize: Float = 0.05
}

/// Smoothed, ready-to-render output of the analysis, copied by value across the analysis-queue →
/// main-actor handoff.
struct AudioAnalysisState: Sendable, Equatable {
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var beatPulse: Float = 0
    var leftEnergy: Float = 0
    var rightEnergy: Float = 0
    var isSilent: Bool = true
    /// False until captured audio has been analyzed in this session.
    var hasAudio: Bool = false
}

/// One-pole envelope follower with independent attack/release time constants.
struct EnvelopeFollower {
    var attackSeconds: Double
    var releaseSeconds: Double
    private(set) var value: Float = 0

    mutating func update(target: Float, dt: Double) -> Float {
        let timeConstant = target > value ? attackSeconds : releaseSeconds
        let alpha = Float(1 - exp(-dt / max(timeConstant, 0.0001)))
        value += alpha * (target - value)
        return value
    }

    mutating func reset() { value = 0 }
}

/// Maps a band's level onto 0...1 relative to a rolling dB ceiling and floor.
struct LoudnessRange {
    private(set) var ceiling: Float = -200
    private var floor: Float = -200
    private(set) var isInitialized = false

    /// `minimumFloor` ties the band to the others: nothing below it can read above 0.
    mutating func normalize(db: Float, dt: Float, minimumFloor: Float) -> Float {
        let minimumRange = EnvelopeConfig.loudnessMinimumRangeDb
        if !isInitialized {
            ceiling = db
            floor = db - minimumRange
            isInitialized = true
        }
        ceiling = max(db, ceiling - EnvelopeConfig.loudnessCeilingDecayDbPerSecond * dt)
        floor = min(db, floor + EnvelopeConfig.loudnessFloorRiseDbPerSecond * dt)
        if ceiling - floor < minimumRange { floor = ceiling - minimumRange }
        let effectiveFloor = max(floor, minimumFloor)
        guard ceiling > effectiveFloor else { return 0 }
        return min(max((db - effectiveFloor) / (ceiling - effectiveFloor), 0), 1)
    }

    /// Lets the ceiling decay while nothing is being measured, so a pause doesn't preserve the
    /// last track's loudness indefinitely.
    mutating func relax(dt: Float) {
        guard isInitialized else { return }
        ceiling -= EnvelopeConfig.loudnessCeilingDecayDbPerSecond * dt
        floor = min(floor, ceiling - EnvelopeConfig.loudnessMinimumRangeDb)
    }

    mutating func reset() { isInitialized = false }
}

/// Rolling history and adaptive threshold for one onset-strength signal.
///
/// The history is also kept sorted, updated in place as values arrive and expire (a binary search
/// and a short shift each), so the median is a lookup rather than a sort or selection per hop.
struct OnsetTrack {
    let margin: Float
    /// The last `count` values in arrival order (a ring), so the one expiring is known.
    private var history: [Float]
    /// The same values ascending, in `sorted[0..<count]`.
    private var sorted: [Float]
    private var index = 0
    private(set) var count = 0

    init(capacity: Int, margin: Float) {
        self.margin = margin
        history = [Float](repeating: 0, count: capacity)
        sorted = history
    }

    /// Median of the history (call before appending the current value), or nil until a few hops
    /// of history exist — so capture starting mid-song doesn't read as a beat.
    func median() -> Float? {
        guard count >= 8 else { return nil }
        let n = count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Whether `value` clears the adaptive threshold: `median` (from `median()`) plus the margin.
    func exceeds(_ value: Float, median: Float?) -> Bool {
        guard let median else { return false }
        return value > median + margin
    }

    mutating func append(_ value: Float) {
        // NaN (only from non-finite audio) would break the ordering the binary searches rely on.
        let value = value.isNaN ? Float.infinity : value
        let capacity = history.count
        let n = count
        sorted.withUnsafeMutableBufferPointer { buffer in
            let s = buffer.baseAddress!
            var end = n
            if n == capacity {
                // Drop the value about to be overwritten: any copy of it will do.
                let removed = Self.firstIndex(notBelow: history[index], in: s, count: n)
                (s + removed).update(from: s + removed + 1, count: n - removed - 1)
                end -= 1
            }
            let insertion = Self.firstIndex(notBelow: value, in: s, count: end)
            (s + insertion + 1).update(from: s + insertion, count: end - insertion)
            s[insertion] = value
        }
        history[index] = value
        index = (index + 1) % capacity
        count = min(n + 1, capacity)
    }

    mutating func clear() {
        index = 0
        count = 0
    }

    /// Lower bound: the first position in the ascending `values[0..<count]` holding `value` or
    /// more (`count` if none).
    private static func firstIndex(notBelow value: Float, in values: UnsafePointer<Float>, count: Int) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// Sizes each beat 0...1 by how hard its low end hits, compared with recent hits.
///
/// The hit's kick-band level, peaking over its onset hop and the next `growthHops`, is measured
/// against a reference: the loudest recent hit, relaxing slowly, and never below the loudest
/// band's ceiling going into the hit (so a hat-only loop, whose low end sits far under its
/// treble, stays small). That loudness is scaled by how clearly the kick band had an onset of
/// its own, so hats and snare ticks over a loud bass line stay small too, and then shaped by a
/// smoothstep so a beat reads as either a burst or a subtle move. Equal kicks all come out near
/// full size, however loud the track; a soft kick after an accent, or the first seconds of a
/// quieter section, come out small.
struct BeatSizer {
    /// Kick-band level (dB) of the loudest recent hit, relaxing at `referenceDecayDbPerSecond`.
    private var referenceDb: Float = BeatSizer.floorDb
    /// Hops of the hit in progress still to be measured, including the current one; 0 when idle.
    private var hopsLeft = 0
    // The hit in progress: what it's measured against, its peaks so far, and its size so far.
    private var hitReferenceDb: Float = 0
    private var peakDb: Float = BeatSizer.floorDb
    private var peakKickRise: Float = -.infinity
    private var size: Float = 0

    private static let floorDb: Float = -200

    /// A beat fired on this hop: start sizing it, or — for a kick upgrading the beat in
    /// progress — keep sizing the same hit for another `growthHops`.
    mutating func beginHit(loudestBandCeilingDb: Float) {
        if hopsLeft == 0 {
            hitReferenceDb = max(referenceDb, loudestBandCeilingDb)
            peakDb = Self.floorDb
            peakKickRise = -.infinity
            size = 0
        }
        hopsLeft = BeatSizeConfig.growthHops + 1
    }

    /// Feeds one analyzed hop: the kick band's level (dB) and its onset strength above the
    /// running median. Returns the hit's size when it grew on this hop, nil otherwise.
    mutating func update(kickBandDb: Float, kickRise: Float, dt: Float) -> Float? {
        referenceDb = max(referenceDb - BeatSizeConfig.referenceDecayDbPerSecond * dt, Self.floorDb)
        guard hopsLeft > 0 else { return nil }
        hopsLeft -= 1
        peakDb = max(peakDb, kickBandDb)
        peakKickRise = max(peakKickRise, kickRise)
        if hopsLeft == 0 { referenceDb = max(referenceDb, peakDb) }
        let graded = gradedSize()
        guard graded > size else { return nil }
        size = graded
        return size
    }

    mutating func reset() {
        referenceDb = Self.floorDb
        hopsLeft = 0
    }

    private func gradedSize() -> Float {
        let config = BeatSizeConfig.self
        let belowReference = hitReferenceDb - peakDb - config.fullSizeWithinDb
        let loudness = min(max(1 - belowReference / config.sizeRangeDb, 0), 1)
        let kickEvidence = (peakKickRise - config.kickEvidenceLow) / (config.kickEvidenceHigh - config.kickEvidenceLow)
        let kickness = min(max(kickEvidence, 0), 1)
        let x = loudness * (config.nonKickWeight + (1 - config.nonKickWeight) * kickness)
        // Smoothstep: flattens both ends, so most beats land clearly big or clearly small.
        let shaped = x * x * (3 - 2 * x)
        return config.minimumSize + (1 - config.minimumSize) * shaped
    }
}

/// Reads captured audio from the ring buffer, runs an FFT band/beat analysis on every 512-sample
/// hop, and publishes a smoothed `AudioAnalysisState` for the renderer.
///
/// While music plays, the ring buffer wakes the analysis as each capture delivery lands (≈47 a
/// second, two hops each), so a hit is analyzed as soon as it arrives and nothing wakes up just
/// to find no new audio; a slow watchdog timer notices the deliveries stopping. Otherwise (no
/// audio yet, silence, a stalled stream) a 50ms timer polls.
///
/// Analysis runs on its own serial queue; each overlay's display link reads the latest snapshot
/// at the display's refresh rate. All mutable state here is touched only on `analysisQueue` —
/// `start()`, `stop()` and `restartSession()` hop onto it too — so a tick still running from a
/// cancelled source can never overlap a new session. The snapshot has its own lock because the
/// main actor reads it.
///
/// Beat detection is a log-magnitude onset detector (after SuperFlux): each bin's rise over the
/// previous frame's ±1-bin neighborhood, minus the median change across bins — so vibrato and
/// slowly beating partials don't register, and neither does a crescendo, fade or level jump,
/// which moves every bin together. It runs on two bands with their own thresholds (median of the
/// last second plus a fixed margin): the kick band, and the full band for snares, hats and plucks.
///
/// Which band fired doesn't set how big the beat looks: `BeatSizer` grades every beat 0...1 by
/// how loud its low end peaks against recent hits and whether the kick band had an onset of its
/// own, over the onset hop and the next few (a beat's size can still rise for ≈32ms as its low
/// end peaks, never drop). So a steady four-on-the-floor bursts on every kick, while an accented
/// pattern's soft kicks, hats and snares over a bass line, a hat-only loop, and the first seconds
/// of a quieter section only nudge the glow. `beatPulse` carries that size, already shaped, for
/// the renderer to map linearly.
final class BeatDetector: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.openglow.app", category: "BeatDetector")
    private let ringBuffer: AudioRingBuffer
    private let analysisQueue = DispatchQueue(label: "com.openglow.audio.analysis", qos: .userInitiated)
    private let published = OSAllocatedUnfairLock(initialState: AudioAnalysisState())
    private var timer: DispatchSourceTimer?
    /// Signalled by the ring buffer when new audio lands, while `followsDeliveries`.
    private var deliveries: DispatchSourceUserDataAdd?
    private var followsDeliveries = false

    // FFT setup and scratch, allocated once.
    private let fftSetup: FFTSetup
    private let halfSize = FFTConfig.windowSize / 2
    private var window = [Float](repeating: 0, count: FFTConfig.windowSize)
    private var leftSamples = [Float](repeating: 0, count: FFTConfig.windowSize)
    private var rightSamples = [Float](repeating: 0, count: FFTConfig.windowSize)
    private var windowed = [Float](repeating: 0, count: FFTConfig.windowSize)
    private var realPart = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private var imagPart = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private var channelPower = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private var power = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private var logMagnitude = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private var previousLogMagnitude = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private var olderLogMagnitude = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private var rise = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private var medianScratch = [Float](repeating: 0, count: FFTConfig.windowSize / 2)
    private let bassBins: Range<Int>
    private let midBins: Range<Int>
    private let trebleBins: Range<Int>
    private let fluxBins: Range<Int>
    /// Kick bins as offsets within `fluxBins`.
    private let kickOffsets: Range<Int>

    // Per-session state.
    private var bassEnvelope = EnvelopeFollower(attackSeconds: EnvelopeConfig.attackSeconds, releaseSeconds: EnvelopeConfig.releaseSeconds)
    private var midEnvelope = EnvelopeFollower(attackSeconds: EnvelopeConfig.attackSeconds, releaseSeconds: EnvelopeConfig.releaseSeconds)
    private var trebleEnvelope = EnvelopeFollower(attackSeconds: EnvelopeConfig.attackSeconds, releaseSeconds: EnvelopeConfig.releaseSeconds)
    private var leftEnvelope = EnvelopeFollower(attackSeconds: EnvelopeConfig.attackSeconds, releaseSeconds: EnvelopeConfig.releaseSeconds)
    private var rightEnvelope = EnvelopeFollower(attackSeconds: EnvelopeConfig.attackSeconds, releaseSeconds: EnvelopeConfig.releaseSeconds)
    private var bassRange = LoudnessRange()
    private var midRange = LoudnessRange()
    private var trebleRange = LoudnessRange()
    private var stereoPeak: Float = 1e-4
    private var beatPulse: Float = 0
    private var lastBeatAudioTime: TimeInterval = -.infinity
    private var kickOnsets: OnsetTrack
    private var fullOnsets: OnsetTrack
    private var hasPreviousShape = false
    private var hasOlderShape = false
    private var lastBeatWasFullOnly = false
    private var beatSizer = BeatSizer()
    private var cursor: UInt64?
    private var gateOpen = false
    private var gateHasOpened = false
    private var resumeOnsetPending = false
    private var belowGateTime: TimeInterval = 0
    private var quietSince: TimeInterval?
    private var lastFreshTime: TimeInterval = 0
    private var isStale = false
    private var lastProcessTime: TimeInterval?
    private var sessionStart: TimeInterval = 0
    private var hasAudio = false
    private var warnedNoAudio = false
    private var wasSilent = true
    /// Beats fired since the detector was created, the audio time of the latest, and its size so
    /// far (it can still grow for `BeatSizeConfig.growthHops`). Read by tests; several hops can be
    /// analyzed in one tick, so the published pulse alone can't count them.
    private(set) var beatCount = 0
    private(set) var lastBeatAudioTimeForTesting: TimeInterval = 0
    private(set) var lastBeatStrengthForTesting: Float = 0

    init(ringBuffer: AudioRingBuffer) {
        self.ringBuffer = ringBuffer
        guard let setup = vDSP_create_fftsetup(FFTConfig.log2Size, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for window size \(FFTConfig.windowSize) — windowSize must be a power of two")
        }
        fftSetup = setup
        vDSP_hann_window(&window, vDSP_Length(FFTConfig.windowSize), Int32(vDSP_HANN_NORM))
        let binCount = FFTConfig.windowSize / 2
        bassBins = Self.binRange(for: FrequencyBands.bass, binCount: binCount)
        midBins = Self.binRange(for: FrequencyBands.mid, binCount: binCount)
        trebleBins = Self.binRange(for: FrequencyBands.treble, binCount: binCount)
        fluxBins = Self.binRange(for: FFTConfig.fluxBand, binCount: binCount)
        let kickBins = Self.binRange(for: FFTConfig.kickBand, binCount: binCount)
        kickOffsets = (kickBins.lowerBound - fluxBins.lowerBound)..<(kickBins.upperBound - fluxBins.lowerBound)
        let historyLength = max(16, Int(EnvelopeConfig.fluxHistoryDuration / FFTConfig.hopDuration))
        kickOnsets = OnsetTrack(capacity: historyLength, margin: EnvelopeConfig.kickOnsetMargin)
        fullOnsets = OnsetTrack(capacity: historyLength, margin: EnvelopeConfig.fullOnsetMargin)
    }

    deinit {
        if let deliveries {
            ringBuffer.setWriteObserver(nil)
            deliveries.cancel()
        }
        timer?.cancel()
        vDSP_destroy_fftsetup(fftSetup)
    }

    func start() {
        analysisQueue.async { [self] in
            guard timer == nil else { return }
            // Clear before the first tick: a restart must never analyze audio from before the
            // stop (e.g. the last window before sleep).
            ringBuffer.reset()
            beginSession(now: ProcessInfo.processInfo.systemUptime)
            let source = DispatchSource.makeTimerSource(queue: analysisQueue)
            source.setEventHandler { [weak self] in
                self?.tick()
            }
            let arrivals = DispatchSource.makeUserDataAddSource(queue: analysisQueue)
            arrivals.setEventHandler { [weak self] in
                self?.tick()
            }
            timer = source
            deliveries = arrivals
            followsDeliveries = false
            Self.schedule(source, followingDeliveries: false)
            source.resume()
            arrivals.resume()
            logger.notice("Beat detector started")
        }
    }

    func stop() {
        analysisQueue.async { [self] in
            guard let timer else { return }
            ringBuffer.setWriteObserver(nil)
            deliveries?.cancel()
            deliveries = nil
            timer.cancel()
            self.timer = nil
            beginSession(now: ProcessInfo.processInfo.systemUptime)
            publish(AudioAnalysisState())
            logger.notice("Beat detector stopped")
        }
    }

    /// Starts a fresh analysis session without stopping the timer — used when capture restarts
    /// underneath a running detector, so "no audio yet" warnings and the onset history refer to
    /// the new stream rather than the old one.
    func restartSession() {
        analysisQueue.async { [self] in
            guard timer != nil else { return }
            ringBuffer.reset()
            beginSession(now: ProcessInfo.processInfo.systemUptime)
            publish(AudioAnalysisState())
        }
    }

    /// The most recent published analysis. Safe to call from any thread.
    func snapshot() -> AudioAnalysisState {
        published.withLock { $0 }
    }

    /// Resets all per-session state. Internal (not private) so tests can drive analysis with
    /// synthetic audio and simulated time; the app only calls it via start/stop/restartSession.
    func beginSession(now: TimeInterval) {
        bassEnvelope.reset(); midEnvelope.reset(); trebleEnvelope.reset()
        leftEnvelope.reset(); rightEnvelope.reset()
        bassRange.reset(); midRange.reset(); trebleRange.reset()
        stereoPeak = 1e-4
        beatPulse = 0
        lastBeatAudioTime = -.infinity
        clearOnsetHistory()
        cursor = nil
        gateOpen = false
        gateHasOpened = false
        resumeOnsetPending = false
        belowGateTime = 0
        quietSince = now
        lastFreshTime = now
        isStale = false
        lastProcessTime = nil
        sessionStart = now
        hasAudio = false
        warnedNoAudio = false
        wasSilent = true
    }

    private func tick() {
        process(now: ProcessInfo.processInfo.systemUptime)
        setFollowsDeliveries(hasAudio && !isStale && !wasSilent)
    }

    /// Switches between ticking on each audio delivery (with a slow watchdog timer) and polling.
    private func setFollowsDeliveries(_ follow: Bool) {
        guard follow != followsDeliveries, let timer else { return }
        followsDeliveries = follow
        ringBuffer.setWriteObserver(follow ? deliveries : nil, minimumFrames: FFTConfig.hopSize)
        Self.schedule(timer, followingDeliveries: follow)
    }

    private static func schedule(_ timer: DispatchSourceTimer, followingDeliveries: Bool) {
        let interval = followingDeliveries ? EnvelopeConfig.deliveryWatchdogInterval : EnvelopeConfig.idlePollInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(15))
    }

    /// One analysis tick at wall-clock time `now`: analyzes every hop that has arrived since the
    /// last tick, or handles no-audio / stalled / idle states. Internal for tests; in the app it
    /// only runs on `analysisQueue`.
    func process(now: TimeInterval) {
        let wallDt = min(max(now - (lastProcessTime ?? now), 0), 1)
        lastProcessTime = now

        let (available, sequence) = ringBuffer.status()
        let oldest = sequence - UInt64(available)
        let window = UInt64(FFTConfig.windowSize)
        let hop = UInt64(FFTConfig.hopSize)

        // Skip ahead if we've fallen too far behind, then keep the next window fully inside what
        // the buffer still holds (after a reset or an overrun).
        var next = cursor ?? (oldest + window - hop)
        if sequence > next, (sequence - next) / hop > UInt64(FFTConfig.maxCatchUpHops) {
            next = sequence - UInt64(FFTConfig.maxCatchUpHops) * hop
        }
        cursor = max(next, oldest + window - hop)

        var analyzedHops = 0
        while let current = cursor, current + hop <= sequence, analyzedHops < FFTConfig.maxCatchUpHops {
            let end = current + hop
            let read = leftSamples.withUnsafeMutableBufferPointer { left in
                rightSamples.withUnsafeMutableBufferPointer { right in
                    ringBuffer.read(left: left.baseAddress!, right: right.baseAddress!, count: FFTConfig.windowSize, endingAt: end)
                }
            }
            cursor = end
            guard read else { break }
            analyzeHop(audioTime: Double(end) / AudioEngineConfig.targetSampleRate, now: now)
            analyzedHops += 1
        }

        if analyzedHops > 0 {
            lastFreshTime = now
            isStale = false
            if !hasAudio {
                hasAudio = true
                logger.notice("Analysis is receiving audio")
            }
        } else if hasAudio {
            if !isStale, now - lastFreshTime > EnvelopeConfig.staleAudioTimeout {
                // Capture stopped delivering. Discard what's buffered so it's never re-analyzed
                // or mixed into the first window when audio resumes, and treat it as silence.
                isStale = true
                ringBuffer.reset()
                cursor = nil
                closeGate(now: now)
            }
            if isStale || !gateOpen {
                decayIdle(dt: wallDt)
            }
        } else if !warnedNoAudio, now - sessionStart > EnvelopeConfig.noAudioWarningDelay {
            warnedNoAudio = true
            logger.error("No audio received from capture \(Int(now - self.sessionStart), privacy: .public)s after start (\(available, privacy: .public) frames buffered)")
        }

        let silent = !gateOpen && now - (quietSince ?? now) >= EnvelopeConfig.silenceTimeout
        if silent != wasSilent, hasAudio {
            logger.notice("\(silent ? "Audio silent — idle glow" : "Audio playing", privacy: .public)")
        }
        wasSilent = silent

        var state = AudioAnalysisState()
        state.bass = bassEnvelope.value
        state.mid = midEnvelope.value
        state.treble = trebleEnvelope.value
        state.leftEnergy = leftEnvelope.value
        state.rightEnergy = rightEnvelope.value
        state.beatPulse = beatPulse
        state.isSilent = silent || !hasAudio
        state.hasAudio = hasAudio
        publish(state)
    }

    // MARK: - Per-hop analysis

    private func analyzeHop(audioTime: TimeInterval, now: TimeInterval) {
        let dt = FFTConfig.hopDuration
        let n = vDSP_Length(FFTConfig.windowSize)
        var leftRMS: Float = 0
        var rightRMS: Float = 0
        vDSP_rmsqv(leftSamples, 1, &leftRMS, n)
        vDSP_rmsqv(rightSamples, 1, &rightRMS, n)
        // Per-channel power, not a mono mix: out-of-phase stereo content must not cancel out.
        let level = sqrt((leftRMS * leftRMS + rightRMS * rightRMS) / 2)
        updateGate(level: level, dt: dt, now: now)

        var bass: Float = 0, mid: Float = 0, treble: Float = 0, left: Float = 0, right: Float = 0
        var beat: (fired: Bool, size: Float?) = (false, nil)

        if gateOpen {
            computePowerSpectrum()

            let bassDb = Self.decibels(bandPower(bassBins))
            let midDb = Self.decibels(bandPower(midBins))
            let trebleDb = Self.decibels(bandPower(trebleBins))
            let decay = EnvelopeConfig.loudnessCeilingDecayDbPerSecond * Float(dt)
            let loudestCeiling = max(bassRange.ceiling, midRange.ceiling, trebleRange.ceiling)
            let loudest = max(bassDb, midDb, trebleDb, loudestCeiling - decay)
            let minimumFloor = loudest - EnvelopeConfig.bandRelativeFloorDb
            bass = bassRange.normalize(db: bassDb, dt: Float(dt), minimumFloor: minimumFloor)
            mid = midRange.normalize(db: midDb, dt: Float(dt), minimumFloor: minimumFloor)
            treble = trebleRange.normalize(db: trebleDb, dt: Float(dt), minimumFloor: minimumFloor)

            // Stereo levels share one linear peak so each edge's brightness keeps its balance
            // relative to the other.
            stereoPeak = max(max(leftRMS, rightRMS), stereoPeak * Float(exp(-dt / EnvelopeConfig.stereoPeakDecaySeconds)))
            left = min(leftRMS / stereoPeak, 1)
            right = min(rightRMS / stereoPeak, 1)

            beat = detectBeat(audioTime: audioTime, loudestBandCeilingDb: loudestCeiling)
        } else {
            relaxRanges(dt: Float(dt))
        }

        _ = bassEnvelope.update(target: bass, dt: dt)
        _ = midEnvelope.update(target: mid, dt: dt)
        _ = trebleEnvelope.update(target: treble, dt: dt)
        _ = leftEnvelope.update(target: left, dt: dt)
        _ = rightEnvelope.update(target: right, dt: dt)
        beatPulse *= Float(exp(-dt / EnvelopeConfig.beatDecaySeconds))
        if let size = beat.size {
            beatPulse = max(beatPulse, size)
            lastBeatStrengthForTesting = size
        }
        if beat.fired {
            lastBeatAudioTime = audioTime
            beatCount += 1
            lastBeatAudioTimeForTesting = audioTime
        }
    }

    private func updateGate(level: Float, dt: TimeInterval, now: TimeInterval) {
        if gateOpen {
            if level < EnvelopeConfig.gateCloseLevel {
                belowGateTime += dt
                if belowGateTime >= EnvelopeConfig.gateCloseHold { closeGate(now: now) }
            } else {
                belowGateTime = 0
            }
        } else if level > EnvelopeConfig.gateOpenLevel {
            gateOpen = true
            belowGateTime = 0
            quietSince = nil
            // Sound starting after real silence is an onset in its own right; at the very start
            // of a session (music already playing) it isn't.
            resumeOnsetPending = gateHasOpened
            gateHasOpened = true
        }
    }

    private func closeGate(now: TimeInterval) {
        guard gateOpen || quietSince == nil else { return }
        gateOpen = false
        belowGateTime = 0
        quietSince = quietSince ?? now
        resumeOnsetPending = false
        // The next sound is judged against silence, not the old track's spectrum and flux.
        clearOnsetHistory()
    }

    /// Envelopes and the beat pulse fall away in wall-clock time while no audio is analyzed.
    private func decayIdle(dt: TimeInterval) {
        guard dt > 0 else { return }
        _ = bassEnvelope.update(target: 0, dt: dt)
        _ = midEnvelope.update(target: 0, dt: dt)
        _ = trebleEnvelope.update(target: 0, dt: dt)
        _ = leftEnvelope.update(target: 0, dt: dt)
        _ = rightEnvelope.update(target: 0, dt: dt)
        beatPulse *= Float(exp(-dt / EnvelopeConfig.beatDecaySeconds))
        relaxRanges(dt: Float(dt))
    }

    private func relaxRanges(dt: Float) {
        bassRange.relax(dt: dt)
        midRange.relax(dt: dt)
        trebleRange.relax(dt: dt)
    }

    /// Sum of both channels' windowed power spectra into `power`.
    private func computePowerSpectrum() {
        let n = vDSP_Length(FFTConfig.windowSize)
        let half = vDSP_Length(halfSize)
        for channel in 0..<2 {
            let source = channel == 0 ? leftSamples : rightSamples
            source.withUnsafeBufferPointer { samples in
                window.withUnsafeBufferPointer { win in
                    windowed.withUnsafeMutableBufferPointer { out in
                        vDSP_vmul(samples.baseAddress!, 1, win.baseAddress!, 1, out.baseAddress!, 1, n)
                    }
                }
            }
            windowed.withUnsafeBufferPointer { samples in
                realPart.withUnsafeMutableBufferPointer { real in
                    imagPart.withUnsafeMutableBufferPointer { imag in
                        var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                        samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, half)
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, FFTConfig.log2Size, FFTRadix(FFT_FORWARD))
                        // The left channel's power goes straight into the total; the right's is
                        // added below.
                        if channel == 0 {
                            power.withUnsafeMutableBufferPointer { total in
                                vDSP_zvmags(&split, 1, total.baseAddress!, 1, half)
                            }
                        } else {
                            channelPower.withUnsafeMutableBufferPointer { out in
                                vDSP_zvmags(&split, 1, out.baseAddress!, 1, half)
                            }
                        }
                    }
                }
            }
        }
        channelPower.withUnsafeBufferPointer { right in
            power.withUnsafeMutableBufferPointer { total in
                vDSP_vadd(total.baseAddress!, 1, right.baseAddress!, 1, total.baseAddress!, 1, half)
            }
        }
    }

    /// Onset strength on log magnitudes (the SuperFlux idea): how much each bin rose compared with
    /// the previous hop's *neighboring* bins (a ±1-bin max filter, so vibrato and slowly beating
    /// partials don't count), after removing the median change across all bins (so a crescendo,
    /// a fade or a level jump — which moves every bin together — doesn't count either). Averaged
    /// separately over the kick band and the full band, each with its own adaptive threshold.
    /// Returns whether a beat fires on this hop, and the beat's size when it grew on this hop.
    private func detectBeat(audioTime: TimeInterval, loudestBandCeilingDb: Float) -> (fired: Bool, size: Float?) {
        let count = fluxBins.count
        let n = vDSP_Length(count)
        var meanMagnitude: Float = 0
        power.withUnsafeBufferPointer { p in
            logMagnitude.withUnsafeMutableBufferPointer { m in
                var elements = Int32(count)
                vvsqrtf(m.baseAddress!, p.baseAddress! + fluxBins.lowerBound, &elements)
                vDSP_meanv(m.baseAddress!, 1, &meanMagnitude, n)
                var floor = max(meanMagnitude * EnvelopeConfig.onsetLogFloor, 1e-12)
                vDSP_vsadd(m.baseAddress!, 1, &floor, m.baseAddress!, 1, n)
                vvlogf(m.baseAddress!, m.baseAddress!, &elements)
            }
        }
        // Digital silence inside an open gate: nothing meaningful to compare.
        guard meanMagnitude > 0 else { return (false, nil) }

        let sinceLastBeat = audioTime - lastBeatAudioTime
        let refractoryOver = sinceLastBeat > EnvelopeConfig.refractoryPeriod
        var fired = false
        var size: Float?
        if resumeOnsetPending {
            resumeOnsetPending = false
            fired = refractoryOver
            if fired {
                lastBeatWasFullOnly = false
                // Sound starting after silence has no recent hits to be sized against.
                size = 1
            }
        } else if hasPreviousShape {
            let fullStrength = fullOnsetStrength(count: count)
            let kickStrength = kickOnsetStrength(count: count)
            let kickPower = bandPower((fluxBins.lowerBound + kickOffsets.lowerBound)..<(fluxBins.lowerBound + kickOffsets.upperBound))
            let kickShareDb = 10 * log10f(max(kickPower, 1e-20) / max(bandPower(fluxBins), 1e-20))
            let kickMedian = kickOnsets.median()
            let kick = kickOnsets.exceeds(kickStrength, median: kickMedian) && kickShareDb >= EnvelopeConfig.kickMinimumShareDb
            let full = fullOnsets.exceeds(fullStrength, median: fullOnsets.median())
            if refractoryOver {
                fired = kick || full
                if fired { lastBeatWasFullOnly = !kick }
            } else if kick && lastBeatWasFullOnly && sinceLastBeat <= EnvelopeConfig.kickUpgradeWindow {
                // The same hit's transient crossed the full-band threshold a hop or two before
                // its kick band did: it's sized as the kick it is rather than losing the kick.
                fired = true
                lastBeatWasFullOnly = false
            }
            if fired { beatSizer.beginHit(loudestBandCeilingDb: loudestBandCeilingDb) }
            size = beatSizer.update(
                kickBandDb: 10 * log10f(max(kickPower, 1e-12)),
                kickRise: kickStrength - (kickMedian ?? kickStrength),
                dt: Float(FFTConfig.hopDuration)
            )
            kickOnsets.append(kickStrength)
            fullOnsets.append(fullStrength)
        }
        // Rotate history: older ← previous ← current (the old `older` becomes scratch).
        swap(&olderLogMagnitude, &previousLogMagnitude)
        swap(&previousLogMagnitude, &logMagnitude)
        hasOlderShape = hasPreviousShape
        hasPreviousShape = true
        return (fired, size)
    }

    /// Full-band onset strength against the previous hop, after removing the median change
    /// across all bins.
    private func fullOnsetStrength(count: Int) -> Float {
        var strength: Float = 0
        logMagnitude.withUnsafeBufferPointer { current in
            previousLogMagnitude.withUnsafeBufferPointer { previous in
                rise.withUnsafeMutableBufferPointer { out in
                    medianScratch.withUnsafeMutableBufferPointer { scratch in
                        let gain = Self.medianChange(current.baseAddress!, previous.baseAddress!, count: count, scratch: scratch)
                        Self.maxFilteredRise(current.baseAddress!, previous.baseAddress!, range: 0..<count, count: count, gain: gain, into: out.baseAddress!)
                        vDSP_meanv(out.baseAddress!, 1, &strength, vDSP_Length(count))
                    }
                }
            }
        }
        return strength
    }

    /// Kick-band onset strength. Compared with the frame two hops back, because consecutive
    /// windows overlap by 75% and split one kick's rise over several hops; and with the gain
    /// reference taken only from bins below 2kHz and never negative, so a hat or snare decaying
    /// in the treble can't make a steady kick band look like it rose. (Real kicks under bass
    /// lines and hats came out far weaker than the full-band formula assumes.)
    private func kickOnsetStrength(count: Int) -> Float {
        let binWidth = AudioEngineConfig.targetSampleRate / Double(FFTConfig.windowSize)
        let lowCount = max(1, min(count, Int(2_000 / binWidth)))
        var strength: Float = 0
        let reference = hasOlderShape ? olderLogMagnitude : previousLogMagnitude
        logMagnitude.withUnsafeBufferPointer { current in
            reference.withUnsafeBufferPointer { older in
                rise.withUnsafeMutableBufferPointer { out in
                    medianScratch.withUnsafeMutableBufferPointer { scratch in
                        let gain = max(Self.medianChange(current.baseAddress!, older.baseAddress!, count: lowCount, scratch: scratch), 0)
                        Self.maxFilteredRise(current.baseAddress!, older.baseAddress!, range: kickOffsets, count: count, gain: gain, into: out.baseAddress!)
                        vDSP_meanv(out.baseAddress! + kickOffsets.lowerBound, 1, &strength, vDSP_Length(kickOffsets.count))
                    }
                }
            }
        }
        return strength
    }

    /// Median of `current - reference` over the first `count` bins: the window's overall gain
    /// change, which a crescendo or level jump applies to every bin alike.
    private static func medianChange(
        _ current: UnsafePointer<Float>, _ reference: UnsafePointer<Float>, count: Int, scratch: UnsafeMutableBufferPointer<Float>
    ) -> Float {
        vDSP_vsub(reference, 1, current, 1, scratch.baseAddress!, 1, vDSP_Length(count))
        return Median.reordering(UnsafeMutableBufferPointer(rebasing: scratch[0..<count]))
    }

    /// For each bin in `range`: how far it rose above the reference frame's ±1-bin neighborhood
    /// (so vibrato and slowly beating partials don't count), minus `gain`, floored at 0. `range`
    /// must lie within `0..<count`.
    private static func maxFilteredRise(
        _ current: UnsafePointer<Float>, _ reference: UnsafePointer<Float>,
        range: Range<Int>, count: Int, gain: Float, into out: UnsafeMutablePointer<Float>
    ) {
        guard !range.isEmpty else { return }
        let low = range.lowerBound
        let high = range.upperBound
        // Neighborhood max in `out`: each bin with the one above it (the top bin has none), then
        // with the one below it (the bottom bin has none).
        let pairedAbove = min(high, count - 1) - low
        if pairedAbove > 0 {
            vDSP_vmax(reference + low, 1, reference + low + 1, 1, out + low, 1, vDSP_Length(pairedAbove))
        }
        if high == count { out[count - 1] = reference[count - 1] }
        let firstWithBelow = max(low, 1)
        if high > firstWithBelow {
            vDSP_vmax(out + firstWithBelow, 1, reference + firstWithBelow - 1, 1, out + firstWithBelow, 1, vDSP_Length(high - firstWithBelow))
        }
        // current - neighborhood - gain, floored at 0.
        let n = vDSP_Length(high - low)
        var negativeGain = -gain
        var zero: Float = 0
        vDSP_vsub(out + low, 1, current + low, 1, out + low, 1, n)
        vDSP_vsadd(out + low, 1, &negativeGain, out + low, 1, n)
        vDSP_vthr(out + low, 1, &zero, out + low, 1, n)
    }

    private func clearOnsetHistory() {
        kickOnsets.clear()
        fullOnsets.clear()
        beatSizer.reset()
        hasPreviousShape = false
        hasOlderShape = false
        lastBeatWasFullOnly = false
    }

    private func bandPower(_ bins: Range<Int>) -> Float {
        var sum: Float = 0
        power.withUnsafeBufferPointer { p in
            vDSP_sve(p.baseAddress! + bins.lowerBound, 1, &sum, vDSP_Length(bins.count))
        }
        return sum
    }

    private static func decibels(_ power: Float) -> Float {
        10 * log10f(max(power, 1e-12))
    }

    private func publish(_ state: AudioAnalysisState) {
        published.withLock { $0 = state }
    }

    private static func binRange(for band: ClosedRange<Double>, binCount: Int) -> Range<Int> {
        let binWidth = AudioEngineConfig.targetSampleRate / Double(FFTConfig.windowSize)
        let low = max(1, Int(band.lowerBound / binWidth))
        let high = min(binCount, Int(band.upperBound / binWidth))
        return low..<max(low + 1, high)
    }
}
