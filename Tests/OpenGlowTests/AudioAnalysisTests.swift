import Foundation
import Testing
import os
@testable import OpenGlow

/// Deterministic noise so the tests are reproducible run to run.
private struct NoiseGenerator {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24) * 2 - 1
    }
}

private enum Synth {
    static let rate = AudioEngineConfig.targetSampleRate

    struct DrumLoop {
        var samples: [Float]
        var kickTimes: [Double]
        var hatTimes: [Double]
        /// Each kick's gain relative to `kickLevel`, parallel to `kickTimes`.
        var kickGains: [Float] = []
    }

    /// A kick drum every beat (decaying 60Hz sine) plus a short noise hi-hat on every off-beat.
    /// `kickGains` cycles over the kicks, for accented patterns.
    static func drumLoop(seconds: Double, bpm: Double = 120, kickLevel: Float = 0.8, hatLevel: Float = 0.08, start: Double = 0.25, kickGains: [Float] = [1]) -> DrumLoop {
        let count = Int(seconds * rate)
        var out = [Float](repeating: 0, count: count)
        var noise = NoiseGenerator(state: 42)
        let beat = 60 / bpm
        var loop = DrumLoop(samples: [], kickTimes: [], hatTimes: [])
        var t = start
        while t < seconds {
            let gain = kickGains[loop.kickTimes.count % kickGains.count]
            loop.kickTimes.append(t)
            loop.kickGains.append(gain)
            let kickStart = Int(t * rate)
            for i in 0..<Int(0.3 * rate) where kickStart + i < count {
                let dt = Double(i) / rate
                out[kickStart + i] += gain * kickLevel * Float(sin(2 * .pi * 60 * dt) * exp(-dt / 0.1))
            }
            let hat = t + beat / 2
            if hat < seconds, hatLevel > 0 {
                loop.hatTimes.append(hat)
                let hatStart = Int(hat * rate)
                for i in 0..<Int(0.03 * rate) where hatStart + i < count {
                    let dt = Double(i) / rate
                    out[hatStart + i] += hatLevel * noise.next() * Float(exp(-dt / 0.01))
                }
            }
            t += beat
        }
        loop.samples = out
        return loop
    }

    /// Bright noise hi-hats (a second difference keeps them in the treble, like real ones) every
    /// `interval` seconds, with no low end at all.
    static func hats(seconds: Double, interval: Double, level: Float = 0.1, seed: UInt64 = 5) -> [Float] {
        var noise = NoiseGenerator(state: seed)
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        var t = 0.1
        while t < seconds {
            let start = Int(t * rate)
            var previous: Float = 0
            var previous2: Float = 0
            for i in 0..<Int(0.04 * rate) where start + i < out.count {
                let white = noise.next()
                out[start + i] = level * (white - 2 * previous + previous2) * Float(exp(-Double(i) / rate / 0.012))
                previous2 = previous
                previous = white
            }
            t += interval
        }
        return out
    }

    static func noise(seconds: Double, rms: Float, seed: UInt64 = 7) -> [Float] {
        var generator = NoiseGenerator(state: seed)
        // Uniform noise in [-1, 1] has RMS 1/sqrt(3).
        let scale = rms * sqrt(3)
        return (0..<Int(seconds * rate)).map { _ in generator.next() * scale }
    }

    /// Sum of sines of equal amplitude scaled to the requested RMS.
    static func tones(_ frequencies: [Double], seconds: Double, rms: Float, amplitudeWobble: (Double) -> Double = { _ in 1 }) -> [Float] {
        let amplitude = Double(rms) / sqrt(Double(frequencies.count) / 2)
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            let sum = frequencies.reduce(0) { $0 + sin(2 * .pi * $1 * t) }
            return Float(amplitude * sum * amplitudeWobble(t))
        }
    }

    /// A slowly breathing pad: detuned pairs with gentle amplitude motion.
    static func pad(seconds: Double, rms: Float) -> [Float] {
        tones([200, 201.3, 300, 302.1, 400, 398.4], seconds: seconds, rms: rms) { t in 1 + 0.25 * sin(2 * .pi * 0.5 * t) }
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map { $0 + $1 }
    }

    static func scaled(_ samples: [Float], by gain: Float) -> [Float] {
        samples.map { $0 * gain }
    }
}

/// Feeds audio into a real ring buffer the way ScreenCaptureKit does — fixed-size chunks at real
/// time pace, with some delivery jitter — while ticking a real `BeatDetector` on simulated time:
/// on a fixed timer, or (`ticksOnDelivery`) right after each delivery, as the app does while
/// music plays.
private final class AnalysisHarness {
    let ring = AudioRingBuffer(capacity: AudioEngineConfig.ringBufferCapacity)
    let detector: BeatDetector
    let chunk: Int
    let tickInterval: Double
    let ticksOnDelivery: Bool
    private var jitter = NoiseGenerator(state: 99)
    private(set) var time: Double = 0
    private(set) var frames: [(time: Double, state: AudioAnalysisState)] = []
    /// Audio time (seconds of audio written so far) — beats are matched against this, so tick and
    /// chunk timing can't blur the comparison.
    private(set) var audioClock: Double = 0
    private(set) var beatAudioTimes: [Double] = []
    /// Size of each beat (0...1), as it stands after the hops it may still grow over.
    private(set) var beatStrengths: [Float] = []
    private var lastBeatCount = 0

    init(chunk: Int = 1024, tickInterval: Double = FFTConfig.hopDuration, ticksOnDelivery: Bool = false) {
        self.chunk = chunk
        self.tickInterval = tickInterval
        self.ticksOnDelivery = ticksOnDelivery
        detector = BeatDetector(ringBuffer: ring)
        detector.beginSession(now: 0)
    }

    /// Plays a segment and returns the audio time at which it starts.
    @discardableResult
    func play(_ left: [Float], right: [Float]? = nil) -> Double {
        let segmentStart = audioClock
        audioClock += Double(left.count) / Synth.rate
        let right = right ?? left
        precondition(left.count == right.count)
        let start = time
        var fed = 0
        if ticksOnDelivery {
            while fed < left.count {
                let n = min(chunk, left.count - fed)
                time = max(time, start + Double(fed + n) / Synth.rate + Double(jitter.next()) * 0.004)
                write(left, right, from: fed, count: n)
                fed += n
                tick()
            }
            return segmentStart
        }
        var nextArrival = start + Double(min(chunk, left.count)) / Synth.rate + Double(jitter.next()) * 0.004
        while fed < left.count {
            time += tickInterval + Double(jitter.next()) * 0.002
            while fed < left.count && nextArrival <= time {
                let n = min(chunk, left.count - fed)
                write(left, right, from: fed, count: n)
                fed += n
                let upcoming = min(chunk, left.count - fed)
                nextArrival = start + Double(fed + upcoming) / Synth.rate + Double(jitter.next()) * 0.004
            }
            tick()
        }
        return segmentStart
    }

    private func write(_ left: [Float], _ right: [Float], from: Int, count: Int) {
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                ring.write(left: l.baseAddress! + from, right: r.baseAddress! + from, count: count)
            }
        }
    }

    /// Advances time with no new audio at all, as when capture stalls or stops delivering.
    func stall(seconds: Double) {
        let end = time + seconds
        while time < end {
            time += tickInterval
            tick()
        }
    }

    private func tick() {
        detector.process(now: time)
        frames.append((time, detector.snapshot()))
        if detector.beatCount != lastBeatCount {
            lastBeatCount = detector.beatCount
            beatAudioTimes.append(detector.lastBeatAudioTimeForTesting)
            beatStrengths.append(detector.lastBeatStrengthForTesting)
        } else if !beatStrengths.isEmpty {
            // A beat keeps growing for a few hops after it fires, possibly into the next ticks.
            beatStrengths[beatStrengths.count - 1] = detector.lastBeatStrengthForTesting
        }
    }

    /// Size of the largest beat detected for each event (nil when none matched), so a kick that
    /// upgraded an earlier full-band beat counts once, at the size it ended up showing.
    func sizes(of events: [Double], offset: Double = 0) -> [Float?] {
        events.map { event in
            zip(beatAudioTimes, beatStrengths).filter { matchWindow.contains($0.0 - (event + offset)) }.map(\.1).max()
        }
    }

    func states(from: Double, to: Double) -> [AudioAnalysisState] {
        frames.filter { $0.time >= from && $0.time < to }.map(\.state)
    }

    /// Beats whose audio time falls in `from..<to` (audio seconds).
    func beats(from: Double, to: Double) -> [Double] {
        beatAudioTimes.filter { $0 >= from && $0 < to }
    }
}

/// Allowed gap, in audio time, between an event and the end of the analysis window that detects
/// it: the attack has to be inside the 43ms window, plus a hop or two of rise.
private let matchWindow: ClosedRange<Double> = -0.005...0.07

private func matched(_ events: [Double], in beats: [Double], offset: Double = 0) -> [Double] {
    events.filter { event in beats.contains { matchWindow.contains($0 - (event + offset)) } }
}

private let chunkSizes = [480, 960, 1024, 2048]

@Suite("Audio ring buffer")
struct AudioRingBufferTests {
    @Test func keepsChannelsPairedAcrossWrapAround() {
        let ring = AudioRingBuffer(capacity: 8)
        let left: [Float] = (0..<11).map(Float.init)
        let right = left.map { -$0 }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                ring.write(left: l.baseAddress!, right: r.baseAddress!, count: 5)
                ring.write(left: l.baseAddress! + 5, right: r.baseAddress! + 5, count: 6)
            }
        }
        var outLeft = [Float](repeating: .nan, count: 6)
        var outRight = [Float](repeating: .nan, count: 6)
        let (available, sequence) = outLeft.withUnsafeMutableBufferPointer { l in
            outRight.withUnsafeMutableBufferPointer { r in
                ring.read(left: l.baseAddress!, right: r.baseAddress!, count: 6)
            }
        }
        #expect(available == 6)
        #expect(sequence == 11)
        #expect(outLeft == [5, 6, 7, 8, 9, 10])
        #expect(outRight == [-5, -6, -7, -8, -9, -10])
    }

    @Test func readsAWindowEndingAtAPosition() {
        let ring = AudioRingBuffer(capacity: 8)
        let samples: [Float] = (0..<11).map(Float.init)
        samples.withUnsafeBufferPointer { s in ring.write(left: s.baseAddress!, right: s.baseAddress!, count: 11) }
        var out = [Float](repeating: .nan, count: 4)
        var outRight = out
        let ok = out.withUnsafeMutableBufferPointer { o in
            outRight.withUnsafeMutableBufferPointer { r in ring.read(left: o.baseAddress!, right: r.baseAddress!, count: 4, endingAt: 9) }
        }
        #expect(ok)
        #expect(out == [5, 6, 7, 8])
        // Frames 0-2 were overwritten (capacity 8 of 11 written), and 12 doesn't exist yet.
        let tooOld = out.withUnsafeMutableBufferPointer { o in
            outRight.withUnsafeMutableBufferPointer { r in ring.read(left: o.baseAddress!, right: r.baseAddress!, count: 4, endingAt: 6) }
        }
        let tooNew = out.withUnsafeMutableBufferPointer { o in
            outRight.withUnsafeMutableBufferPointer { r in ring.read(left: o.baseAddress!, right: r.baseAddress!, count: 4, endingAt: 12) }
        }
        #expect(!tooOld)
        #expect(!tooNew)
    }

    @Test func oversizedWriteKeepsNewestFrames() {
        let ring = AudioRingBuffer(capacity: 4)
        let left: [Float] = (0..<10).map(Float.init)
        left.withUnsafeBufferPointer { l in ring.write(left: l.baseAddress!, right: l.baseAddress!, count: 10) }
        var out = [Float](repeating: .nan, count: 4)
        var outRight = out
        let (available, _) = out.withUnsafeMutableBufferPointer { o in
            outRight.withUnsafeMutableBufferPointer { r in ring.read(left: o.baseAddress!, right: r.baseAddress!, count: 4) }
        }
        #expect(available == 4)
        #expect(out == [6, 7, 8, 9])
    }

    /// The observer is signalled once per `minimumFrames` written (not per write), never once
    /// removed, and a reset starts the count over.
    @Test func signalsTheWriteObserver() async throws {
        let ring = AudioRingBuffer(capacity: 4096)
        let queue = DispatchQueue(label: "test.ring.observer")
        let signals = OSAllocatedUnfairLock(initialState: 0)
        let observer = DispatchSource.makeUserDataAddSource(queue: queue)
        observer.setEventHandler { signals.withLock { $0 += Int(observer.data) } }
        observer.resume()
        defer { observer.cancel() }
        let samples = [Float](repeating: 0.5, count: 1024)
        func write(_ count: Int) {
            samples.withUnsafeBufferPointer { s in ring.write(left: s.baseAddress!, right: s.baseAddress!, count: count) }
        }
        func settledSignals() async throws -> Int {
            try await Task.sleep(for: .milliseconds(100))
            return queue.sync { signals.withLock { $0 } }
        }

        write(1024)  // no observer yet
        ring.setWriteObserver(observer, minimumFrames: 512)
        write(1024)  // signal
        write(300)
        write(300)  // 600 since the last signal: signal
        write(300)
        ring.reset()
        write(300)  // 300 since the reset
        #expect(try await settledSignals() == 2)
        ring.setWriteObserver(nil)
        write(1024)
        #expect(try await settledSignals() == 2)
    }

    @Test func resetEmptiesButSequenceKeepsCounting() {
        let ring = AudioRingBuffer(capacity: 16)
        let samples = [Float](repeating: 1, count: 10)
        samples.withUnsafeBufferPointer { s in ring.write(left: s.baseAddress!, right: s.baseAddress!, count: 10) }
        ring.reset()
        let (available, sequence) = ring.status()
        #expect(available == 0)
        #expect(sequence == 10)
    }
}

@Suite("Beat detector")
struct BeatDetectorTests {
    @Test(arguments: chunkSizes)
    func kicksAreDetectedAsBeats(chunk: Int) {
        let harness = AnalysisHarness(chunk: chunk)
        let loop = Synth.drumLoop(seconds: 8)
        harness.play(loop.samples)

        // Skip the first second: the adaptive threshold needs some history.
        let kicks = loop.kickTimes.filter { $0 > 1 }
        let beats = harness.beats(from: 1, to: 8)
        let found = matched(kicks, in: beats)
        let unexplained = beats.filter { beat in !(loop.kickTimes + loop.hatTimes).contains { matchWindow.contains(beat - $0) } }
        #expect(Double(found.count) >= Double(kicks.count) * 0.9, "chunk \(chunk): \(found.count) of \(kicks.count) kicks")
        #expect(unexplained.isEmpty, "chunk \(chunk): beats not near any kick or hat: \(unexplained)")

        // Equal kicks of a steady loop should all read as large beats, not the subtle move reserved
        // for small ones.
        let largeKicks = kicks.filter { kick in
            zip(harness.beatAudioTimes, harness.beatStrengths).contains { matchWindow.contains($0.0 - kick) && $0.1 >= 0.8 }
        }
        #expect(Double(largeKicks.count) >= Double(kicks.count) * 0.8, "chunk \(chunk): only \(largeKicks.count) of \(kicks.count) kicks read as large beats")
    }

    @Test(arguments: chunkSizes)
    func steadyMaterialDoesNotStrobe(chunk: Int) {
        let materials: [(String, [Float])] = [
            ("white noise", Synth.noise(seconds: 12, rms: 0.1)),
            ("held chord", Synth.tones([220, 277.2, 329.6], seconds: 12, rms: 0.1)),
            ("pad", Synth.pad(seconds: 12, rms: 0.1)),
        ]
        for (name, samples) in materials {
            let harness = AnalysisHarness(chunk: chunk)
            harness.play(samples)
            let beats = harness.beats(from: 2, to: 12)
            #expect(beats.count <= 1, "chunk \(chunk): \(name) fired \(beats.count) beats in 10 s")
        }
    }

    @Test(arguments: chunkSizes)
    func kicksUnderAPadStillRegister(chunk: Int) {
        let harness = AnalysisHarness(chunk: chunk)
        let drums = Synth.drumLoop(seconds: 10, kickLevel: 0.3, hatLevel: 0.04)
        harness.play(Synth.mix(drums.samples, Synth.pad(seconds: 10, rms: 0.15)))
        let kicks = drums.kickTimes.filter { $0 > 1.5 }
        let found = matched(kicks, in: harness.beats(from: 1.5, to: 10))
        #expect(Double(found.count) >= Double(kicks.count) * 0.7, "chunk \(chunk): \(found.count) of \(kicks.count) kicks under the pad")
    }

    @Test(arguments: chunkSizes)
    func fadesAndLevelJumpsDoNotStrobe(chunk: Int) {
        // Silence, then noise fading in over 2 s.
        let fadeIn = Synth.noise(seconds: 4, rms: 0.1).enumerated().map { index, sample in
            sample * Float(min(Double(index) / Synth.rate / 2, 1))
        }
        let fading = AnalysisHarness(chunk: chunk)
        fading.play([Float](repeating: 0, count: Int(2 * Synth.rate)))
        fading.play(fadeIn)
        #expect(fading.beats(from: 2, to: 6).count <= 2, "chunk \(chunk): fade-in fired \(fading.beats(from: 2, to: 6))")

        // Steady noise that jumps up 20 dB.
        let jumping = AnalysisHarness(chunk: chunk)
        jumping.play(Synth.noise(seconds: 4, rms: 0.02))
        jumping.play(Synth.noise(seconds: 4, rms: 0.2, seed: 11))
        #expect(jumping.beats(from: 2, to: 8).count <= 1, "chunk \(chunk): level jump fired \(jumping.beats(from: 2, to: 8))")
    }

    @Test(arguments: chunkSizes)
    func beatsSurviveALevelDrop(chunk: Int) {
        let harness = AnalysisHarness(chunk: chunk)
        harness.play(Synth.drumLoop(seconds: 4).samples)
        let quiet = Synth.drumLoop(seconds: 4, kickLevel: 0.08, hatLevel: 0.008)
        let dropStart = harness.play(quiet.samples)
        let kicks = quiet.kickTimes.filter { $0 < 2.2 }
        let found = matched(kicks, in: harness.beatAudioTimes, offset: dropStart)
        #expect(Double(found.count) >= Double(kicks.count) * 0.75, "chunk \(chunk): \(found.count) of \(kicks.count) kicks right after a 20 dB drop")
    }

    @Test(arguments: chunkSizes)
    func beatsResumeAfterAStalledStream(chunk: Int) {
        let harness = AnalysisHarness(chunk: chunk)
        harness.play(Synth.drumLoop(seconds: 3).samples)
        harness.stall(seconds: 2)
        let quieter = Synth.drumLoop(seconds: 3, kickLevel: 0.16, hatLevel: 0.016)
        let resume = harness.play(quieter.samples)
        let kicks = quieter.kickTimes.filter { $0 < 2.2 }
        let found = matched(kicks, in: harness.beatAudioTimes, offset: resume)
        #expect(found.count >= kicks.count - 1, "chunk \(chunk): \(found.count) of \(kicks.count) kicks after the stall")
    }

    @Test func beatResumesAfterAGap() {
        let harness = AnalysisHarness()
        harness.play(Synth.drumLoop(seconds: 3).samples)
        harness.play([Float](repeating: 0, count: Int(1 * Synth.rate)))
        let loop = Synth.drumLoop(seconds: 2)
        let resume = harness.play(loop.samples)
        #expect(!matched([loop.kickTimes[0]], in: harness.beatAudioTimes, offset: resume).isEmpty, "the first kick after a gap should register")
    }

    @Test func bassSwingsWithTheKick() {
        let harness = AnalysisHarness()
        let loop = Synth.drumLoop(seconds: 6)
        harness.play(loop.samples)

        let steady = harness.frames.filter { $0.time > 2 }
        let nearKick = steady.filter { frame in loop.kickTimes.contains { frame.time >= $0 + 0.03 && frame.time <= $0 + 0.09 } }
        let betweenKicks = steady.filter { frame in loop.kickTimes.contains { frame.time >= $0 + 0.4 && frame.time <= $0 + 0.48 } }
        let peak = nearKick.map(\.state.bass).max() ?? 0
        let trough = betweenKicks.map(\.state.bass).min() ?? 1
        // The trough is set by EnvelopeConfig.releaseSeconds (150ms); what matters visually is a
        // large swing, not an arbitrary floor.
        #expect(peak > 0.8, "bass near kicks peaked at \(peak)")
        #expect(peak - trough > 0.45, "bass swing was only \(peak - trough) (peak \(peak), trough \(trough))")
        #expect(steady.allSatisfy { !$0.state.isSilent && $0.state.hasAudio })
    }

    @Test func outOfPhaseStereoIsNotSilence() {
        let harness = AnalysisHarness()
        let loop = Synth.drumLoop(seconds: 6)
        harness.play(loop.samples, right: Synth.scaled(loop.samples, by: -1))
        let states = harness.states(from: 2, to: 6)
        #expect(states.allSatisfy { !$0.isSilent })
        #expect((states.map(\.bass).max() ?? 0) > 0.8)
        #expect(!harness.beats(from: 2, to: 6).isEmpty)
    }

    @Test func hiHatsAloneDoNotThrobTheBass() {
        let harness = AnalysisHarness()
        var hats = [Float](repeating: 0, count: Int(10 * Synth.rate))
        var t = 0.1
        while t < 10 {
            let start = Int(t * Synth.rate)
            for i in 0..<Int(0.03 * Synth.rate) where start + i < hats.count {
                let dt = Double(i) / Synth.rate
                hats[start + i] = Float(0.2 * sin(2 * .pi * 6_000 * dt) * exp(-dt / 0.01))
            }
            t += 0.25
        }
        harness.play(hats)
        let peakBass = harness.states(from: 2, to: 10).map(\.bass).max() ?? 1
        #expect(peakBass < 0.2, "bass reached \(peakBass) with no bass content")
    }

    /// Hi-hats with a little low-frequency room rumble under them, 25 dB down — the case that made
    /// real hat loops throb the bass and fire full-strength "kick" pulses.
    @Test func hiHatsWithLowFrequencyBleedStaySmall() {
        let harness = AnalysisHarness()
        let seconds = 10.0
        var noise = NoiseGenerator(state: 5)
        var hats = [Float](repeating: 0, count: Int(seconds * Synth.rate))
        var t = 0.1
        while t < seconds {
            let start = Int(t * Synth.rate)
            var previous: Float = 0
            var previous2: Float = 0
            for i in 0..<Int(0.04 * Synth.rate) where start + i < hats.count {
                let white = noise.next()
                // Second difference: a crude high-pass that keeps hats in the treble like real ones.
                let bright = white - 2 * previous + previous2
                previous2 = previous
                previous = white
                hats[start + i] = 0.1 * bright * Float(exp(-Double(i) / Synth.rate / 0.012))
            }
            t += 0.125
        }
        // 25 dB below the hats' level as the detector sees it: the loudest 2048-sample window.
        let windowLevels = stride(from: 0, to: hats.count - 2048, by: 512).map { start in
            sqrt(hats[start..<(start + 2048)].reduce(0) { $0 + $1 * $1 } / 2048)
        }
        let bleedLevel = (windowLevels.max() ?? 0) * Float(pow(10, -25.0 / 20))
        let bleed = Synth.tones([55], seconds: seconds, rms: bleedLevel)
        harness.play(Synth.mix(hats, bleed))
        let peakBass = harness.states(from: 2, to: seconds).map(\.bass).max() ?? 1
        let large = zip(harness.beatAudioTimes, harness.beatStrengths).filter { $0.0 > 2 && $0.1 >= 0.8 }.count
        #expect(peakBass < 0.3, "bass reached \(peakBass) from rumble 25 dB under the hats")
        #expect(large <= 2, "\(large) large beats from a hat-only loop")
    }

    @Test func levelHoveringAtTheGateDoesNotFlicker() {
        let harness = AnalysisHarness()
        // A chord whose RMS wobbles ±30% around the old single threshold (0.003).
        harness.play(Synth.tones([220, 277.2, 329.6], seconds: 9, rms: 0.003) { t in 1 + 0.3 * sin(2 * .pi * 2 * t) })
        #expect(harness.beats(from: 0, to: 9).count <= 1)
        // With hysteresis the gate either stays shut or opens once and stays open; what must not
        // happen is bass pumping between zero and full scale at the wobble rate.
        let bass = harness.states(from: 2, to: 9).map(\.bass)
        let swing = (bass.max() ?? 0) - (bass.min() ?? 0)
        #expect(swing < 0.3, "bass pumped by \(swing)")
    }

    @Test func noAudioIsDistinctFromSilence() {
        let harness = AnalysisHarness()
        harness.stall(seconds: 4)
        #expect(harness.frames.allSatisfy { !$0.state.hasAudio && $0.state.isSilent })
    }

    @Test func silenceTimesOutToIdle() {
        let harness = AnalysisHarness()
        harness.play(Synth.drumLoop(seconds: 2).samples)
        let silenceStart = harness.time
        harness.play([Float](repeating: 0, count: Int(4.5 * Synth.rate)))

        // The gate closes after its 0.25 s hold; the idle glow follows 3 s after that.
        let beforeTimeout = harness.states(from: silenceStart + 0.5, to: silenceStart + 2.5)
        let afterTimeout = harness.states(from: silenceStart + 3.5, to: silenceStart + 4.5)
        #expect(beforeTimeout.allSatisfy { !$0.isSilent })
        #expect(beforeTimeout.last.map { $0.bass < 0.05 && $0.beatPulse < 0.05 } == true, "envelopes should have decayed during the silence")
        #expect(!afterTimeout.isEmpty && afterTimeout.allSatisfy { $0.isSilent })
    }

    @Test func stalledCaptureDoesNotFreezeTheGlow() {
        let harness = AnalysisHarness()
        harness.play(Synth.drumLoop(seconds: 3).samples)
        let stallStart = harness.time
        let beatsBeforeStall = harness.beatAudioTimes.count
        harness.stall(seconds: 4)

        let settled = harness.states(from: stallStart + 1, to: stallStart + 1.2)
        #expect(settled.allSatisfy { $0.bass < 0.05 }, "bass should fall away once no new audio arrives")
        #expect(harness.states(from: stallStart + 3.5, to: stallStart + 4).allSatisfy { $0.isSilent })
        #expect(harness.beatAudioTimes.count == beatsBeforeStall, "no beats may fire from a stale window")
    }

    @Test func hardPannedAudioFavorsOneSide() {
        let harness = AnalysisHarness()
        let loop = Synth.drumLoop(seconds: 4).samples
        harness.play(loop, right: Synth.scaled(loop, by: 0.1))
        let states = harness.states(from: 2, to: 4)
        let peakLeft = states.map(\.leftEnergy).max() ?? 0
        let peakRight = states.map(\.rightEnergy).max() ?? 1
        #expect(peakLeft > 0.8, "left peaked at \(peakLeft)")
        #expect(peakRight < 0.2, "right peaked at \(peakRight)")
    }

    @Test func quietNoiseFloorDoesNotMove() {
        let harness = AnalysisHarness()
        harness.play(Synth.noise(seconds: 5, rms: 0.001))
        #expect(harness.states(from: 1, to: 5).allSatisfy { $0.bass == 0 && $0.beatPulse == 0 }, "noise below the gate must not animate the glow")
        #expect(harness.states(from: 3.2, to: 5).allSatisfy { $0.isSilent })
    }

    @Test func realTimerStartsAndStopsCleanly() async throws {
        let ring = AudioRingBuffer(capacity: AudioEngineConfig.ringBufferCapacity)
        let detector = BeatDetector(ringBuffer: ring)
        detector.start()
        let loop = Synth.drumLoop(seconds: 0.6)
        var fed = 0
        while fed < loop.samples.count {
            let n = min(1024, loop.samples.count - fed)
            loop.samples.withUnsafeBufferPointer { s in ring.write(left: s.baseAddress! + fed, right: s.baseAddress! + fed, count: n) }
            fed += n
            try await Task.sleep(for: .milliseconds(21))
        }
        #expect(detector.snapshot().hasAudio)
        detector.stop()
        try await Task.sleep(for: .milliseconds(150))
        #expect(detector.snapshot() == AudioAnalysisState())
        loop.samples.withUnsafeBufferPointer { s in ring.write(left: s.baseAddress!, right: s.baseAddress!, count: 4096) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(detector.snapshot() == AudioAnalysisState(), "no tick may run after stop()")
    }
}

@Suite("Beat sizing")
struct BeatSizingTests {
    /// Analysis is per hop, so ticking once per delivery (as the app does while music plays)
    /// fires the same beats at the same sizes, and ends in the same state, as ticking every hop.
    @Test(arguments: chunkSizes)
    func deliveryTicksMatchHopTicks(chunk: Int) {
        let loop = Synth.drumLoop(seconds: 8, kickGains: [1, 0.25, 0.6])
        let audio = Synth.mix(loop.samples, Synth.pad(seconds: 8, rms: 0.05))
        let byHop = AnalysisHarness(chunk: chunk)
        let byDelivery = AnalysisHarness(chunk: chunk, ticksOnDelivery: true)
        for harness in [byHop, byDelivery] {
            harness.play(audio)
            harness.play(Synth.scaled(audio, by: 0.3))
        }
        let kicks = loop.kickTimes + loop.kickTimes.map { $0 + 8 }
        #expect(byDelivery.detector.beatCount == byHop.detector.beatCount)
        #expect(byDelivery.sizes(of: kicks) == byHop.sizes(of: kicks))
        #expect(byDelivery.detector.snapshot() == byHop.detector.snapshot())
    }

    /// Alternating accented and ghost kicks (12 dB apart) at a steady tempo: the accents burst,
    /// the ghost kicks only nudge the glow.
    @Test func accentedKicksAreGraded() {
        let harness = AnalysisHarness()
        let loop = Synth.drumLoop(seconds: 10, kickGains: [1, 0.25])
        harness.play(loop.samples)
        let steady = loop.kickTimes.indices.filter { loop.kickTimes[$0] > 2 }
        let sizes = harness.sizes(of: steady.map { loop.kickTimes[$0] })
        let loud = zip(steady, sizes).filter { loop.kickGains[$0.0] == 1 }.map(\.1)
        let soft = zip(steady, sizes).filter { loop.kickGains[$0.0] < 1 }.map(\.1)
        #expect(loud.allSatisfy { ($0 ?? 0) >= 0.8 }, "accented kicks: \(loud)")
        #expect(Double(soft.compactMap { $0 }.count) >= Double(soft.count) * 0.8, "ghost kicks should still be beats: \(soft)")
        #expect(soft.compactMap { $0 }.allSatisfy { $0 <= 0.35 }, "ghost kicks: \(soft)")
    }

    @Test func hiHatsAloneStaySmall() {
        let harness = AnalysisHarness()
        harness.play(Synth.hats(seconds: 10, interval: 0.25))
        let sizes = zip(harness.beatAudioTimes, harness.beatStrengths).filter { $0.0 > 2 }.map(\.1)
        let mean = sizes.reduce(0, +) / Float(max(sizes.count, 1))
        #expect(sizes.count >= 10, "hats should still register as (small) beats: \(sizes.count)")
        #expect(mean <= 0.3, "hat-only beats averaged \(mean): \(sizes)")
    }

    /// A breakdown 12 dB down after a loud intro, then the full-level drop: the drop's first kicks
    /// burst, while the breakdown's read clearly smaller (they grow back as the reference relaxes).
    @Test func loudSectionAfterAQuietOneBursts() {
        let harness = AnalysisHarness()
        harness.play(Synth.drumLoop(seconds: 4).samples)
        let quiet = Synth.drumLoop(seconds: 5, kickLevel: 0.2, hatLevel: 0.02)
        let quietStart = harness.play(quiet.samples)
        let loud = Synth.drumLoop(seconds: 4)
        let loudStart = harness.play(loud.samples)

        let quietSizes = harness.sizes(of: quiet.kickTimes, offset: quietStart).compactMap { $0 }
        let dropSizes = harness.sizes(of: Array(loud.kickTimes.prefix(3)), offset: loudStart).map { $0 ?? 0 }
        let quietMean = quietSizes.reduce(0, +) / Float(max(quietSizes.count, 1))
        let dropMean = dropSizes.reduce(0, +) / Float(dropSizes.count)
        #expect(quietSizes.count >= quiet.kickTimes.count - 2, "quiet kicks should still be beats: \(quietSizes)")
        #expect(quietMean <= 0.5, "quiet section averaged \(quietMean): \(quietSizes)")
        #expect(dropSizes.allSatisfy { $0 >= 0.8 }, "first kicks of the loud section: \(dropSizes)")
        #expect(dropMean >= quietMean + 0.4, "drop \(dropMean) vs quiet section \(quietMean)")
    }

    /// Sizes come from per-hop analysis alone, so however capture chunks its delivery, each beat
    /// ends up the same size.
    @Test func sizesDoNotDependOnChunkSize() {
        let loop = Synth.drumLoop(seconds: 8, kickGains: [1, 0.25, 0.5])
        let kicks = loop.kickTimes.filter { $0 > 1.5 }
        let runs = chunkSizes.map { chunk in
            let harness = AnalysisHarness(chunk: chunk)
            harness.play(loop.samples)
            return harness.sizes(of: kicks)
        }
        for (chunk, sizes) in zip(chunkSizes, runs).dropFirst() {
            for (kick, (size, reference)) in zip(kicks, zip(sizes, runs[0])) {
                let matches = switch (size, reference) {
                case let (size?, reference?): abs(size - reference) <= 0.02
                case (nil, nil): true
                default: false
                }
                #expect(matches, "chunk \(chunk), kick at \(kick): \(String(describing: size)) vs \(String(describing: reference)) with chunk \(chunkSizes[0])")
            }
        }
    }
}
