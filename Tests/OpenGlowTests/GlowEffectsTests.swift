import Testing
@testable import OpenGlow

/// Accents (the coding-session sweep), the timer ring and the timer-finished pulses.
@Suite("Glow effects")
@MainActor
struct GlowEffectsTests {
    private let base = GlowPalette(
        primary: PaletteColor(red: 1, green: 0, blue: 0), secondary: PaletteColor(red: 0, green: 0, blue: 1), balance: 0.5
    )
    private let green = GlowPalette(
        primary: PaletteColor(red: 0, green: 1, blue: 0), secondary: PaletteColor(red: 0, green: 0.8, blue: 0.2), balance: 0.5
    )
    private let fps = 30.0

    private func motion(palette: GlowPalette? = nil) -> GlowMotion {
        let motion = GlowMotion(palette: palette ?? base)
        motion.perimeterPoints = 5644
        motion.introOrigin = 0.625
        motion.ringOrigin = 0.15
        return motion
    }

    private func run(_ motions: [GlowMotion], seconds: Double, settings: GlowMotionSettings, audio: AudioAnalysisState? = nil) {
        for _ in 0..<Int((seconds * fps).rounded()) {
            for motion in motions { motion.step(dt: 1 / fps, audio: audio, settings: settings) }
        }
    }

    private func cell(_ motion: GlowMotion, at position: Double) -> Int {
        let wrapped = position - position.rounded(.down)
        return Int(wrapped * Double(motion.count)) % motion.count
    }

    private var accentSeconds: Double {
        GlowMotionConfig.accentSweepSeconds + GlowMotionConfig.accentHoldSeconds + GlowMotionConfig.accentFadeSeconds
    }

    // MARK: - Accent

    @Test func accentSweepsUpFromTheBottomThenFadesBackToTheCurrentPalette() {
        let settings = GlowMotionSettings(animation: .flow)
        let accented = motion(), plain = motion()
        accented.playAccent(green)
        run([accented, plain], seconds: 0.35, settings: settings)
        let bottom = cell(accented, at: 0.625), top = cell(accented, at: 0.125)
        #expect(accented.green[bottom] > 0.7, "the accent has arrived at the bottom center")
        #expect(accented.green[top] < 0.05, "but not yet at the top")
        #expect(accented.width.max() ?? 0 > (plain.width.max() ?? 0) + 0.2, "a bright, wider head leads the sweep")

        run([accented, plain], seconds: GlowMotionConfig.accentSweepSeconds + 1, settings: settings)
        #expect(accented.green.allSatisfy { $0 > 0.75 }, "the accent covers the whole edge while it holds")
        #expect(accented.amplitude == plain.amplitude, "and the light itself flows on as before")

        // The palette changes while the accent shows; the fade goes back to the new one.
        let next = PalettePresets.preset(withID: "ember").palette
        accented.setPalette(next, animated: true)
        plain.setPalette(next, animated: true)
        run([accented, plain], seconds: accentSeconds, settings: settings)
        #expect(accented.red == plain.red && accented.green == plain.green && accented.blue == plain.blue)
        #expect(accented.width == plain.width)
    }

    @Test func accentFadesBackSmoothly() {
        let settings = GlowMotionSettings(animation: .steady)
        let accented = motion()
        accented.playAccent(green)
        run([accented], seconds: GlowMotionConfig.accentSweepSeconds + GlowMotionConfig.accentHoldSeconds - 0.5, settings: settings)
        var previous: [Float]?
        var biggestStep: Float = 0
        for _ in 0..<Int((GlowMotionConfig.accentFadeSeconds + 1) * fps) {
            accented.step(dt: 1 / fps, audio: nil, settings: settings)
            if let previous { biggestStep = max(biggestStep, zip(previous, accented.green).map { abs($0 - $1) }.max() ?? 0) }
            previous = accented.green
        }
        #expect(biggestStep < 0.2, "no cell jumps in color from one frame to the next")
    }

    @Test func retriggeringRestartsWithoutAPop() {
        let settings = GlowMotionSettings(animation: .flow)
        let accented = motion()
        accented.playAccent(green)
        run([accented], seconds: 3, settings: settings)
        let before = accented.green
        accented.playAccent(green)
        run([accented], seconds: 1 / fps, settings: settings)
        #expect(zip(before, accented.green).allSatisfy { abs($0 - $1) < 0.1 }, "what showed stays")
        // It runs for the full length again from the retrigger.
        run([accented], seconds: accentSeconds - 0.5, settings: settings)
        #expect(accented.green.allSatisfy { $0 > 0.05 }, "still showing past the first accent's end")
        run([accented], seconds: 1, settings: settings)
        #expect(accented.green.allSatisfy { $0 < 0.001 })
    }

    @Test func accentInSteadyIsOneShot() {
        let settings = GlowMotionSettings(animation: .steady)
        let accented = motion()
        accented.step(dt: 0, audio: nil, settings: settings)
        #expect(!accented.needsFrames(settings, audioActive: false))
        accented.playAccent(green)
        run([accented], seconds: 0.5, settings: settings)
        #expect(accented.frameRate(settings, audioActive: false) == 60, "the sweep gets full frame rate")
        run([accented], seconds: GlowMotionConfig.accentSweepSeconds + 1.5, settings: settings)
        #expect(accented.frameRate(settings, audioActive: false) <= 2, "holding still costs next to nothing")
        run([accented], seconds: accentSeconds, settings: settings)
        #expect(!accented.needsFrames(settings, audioActive: false), "frames stop afterwards")
        #expect(accented.amplitude.allSatisfy { $0 == 1 } && accented.width.allSatisfy { $0 == 1 })
    }

    @Test func accentWithReduceMotionIsAPlainCrossFade() {
        let settings = GlowMotionSettings(animation: .flow, reduceMotion: true)
        let accented = motion(), plain = motion()
        accented.playAccent(green)
        run([accented, plain], seconds: 0.5, settings: settings)
        #expect(accented.amplitude == plain.amplitude && accented.width == plain.width, "no sweep head")
        let shares = accented.green
        #expect((shares.max() ?? 0) - (shares.min() ?? 0) < 0.25, "every cell fades in together")
        #expect((shares.min() ?? 0) > 0.05)
        run([accented, plain], seconds: accentSeconds, settings: settings)
        #expect(accented.green == plain.green)
    }

    @Test func musicSwellsCarryOnUnderTheAccent() {
        let settings = GlowMotionSettings(animation: .musicSync)
        var audio = AudioAnalysisState()
        audio.hasAudio = true
        audio.isSilent = false
        audio.beatPulse = 0.8
        let accented = motion(), plain = motion()
        accented.playAccent(green)
        run([accented, plain], seconds: GlowMotionConfig.accentSweepSeconds + 1, settings: settings, audio: audio)
        #expect(accented.amplitude == plain.amplitude)
        #expect(accented.width == plain.width)
    }

    // MARK: - Timer ring

    @Test func ringLightsTheRemainingShareClockwiseFromTopCenter() {
        let settings = GlowMotionSettings(animation: .steady)
        let ringed = motion()
        ringed.setTimerRing(1)
        ringed.step(dt: 0, audio: nil, settings: settings)
        #expect(ringed.amplitude.allSatisfy { $0 == 1 }, "a full timer lights the whole edge")
        #expect(!ringed.needsFrames(settings, audioActive: false))

        ringed.setTimerRing(0.4)
        run([ringed], seconds: 15, settings: settings)
        #expect(ringed.shownTimerRing == 0.4)
        let lit = Double(ringed.amplitude.filter { $0 > 0.5 }.count) / Double(ringed.count)
        #expect(abs(lit - 0.4) < 0.01, "lit share \(lit)")
        #expect(ringed.amplitude[cell(ringed, at: 0.15 + 0.05)] > 0.99, "lit clockwise of the top center")
        #expect(ringed.amplitude[cell(ringed, at: 0.15 + 0.35)] > 0.99)
        #expect(ringed.amplitude[cell(ringed, at: 0.15 + 0.45)] < 0.01, "dark past the remaining share")
        #expect(ringed.amplitude[cell(ringed, at: 0.15 - 0.05)] < 0.01, "and counter-clockwise of the top center")
        // A slightly brighter (wider) head where the ring recedes.
        let head = (0..<ringed.count).max { ringed.width[$0] < ringed.width[$1] } ?? 0
        #expect(abs(Double(head) / Double(ringed.count) - (0.15 + 0.4 - 0.02)) < 0.03)
        #expect(!ringed.needsFrames(settings, audioActive: false), "caught up, it holds still")
    }

    @Test func ringRecedesSmoothlyAndCheaplyBetweenUpdates() {
        let settings = GlowMotionSettings(animation: .steady)
        let ringed = motion()
        // A 25-minute timer, updated once a second.
        let total = 25.0 * 60
        ringed.setTimerRing(1)
        var shown: [Double] = []
        var rates: [Double] = []
        for second in 1...20 {
            ringed.setTimerRing(1 - Double(second) / total)
            for _ in 0..<Int(fps) {
                ringed.step(dt: 1 / fps, audio: nil, settings: settings)
                shown.append(ringed.shownTimerRing ?? 1)
                rates.append(ringed.frameRate(settings, audioActive: false))
            }
        }
        let steps = zip(shown, shown.dropFirst()).map { ($0 - $1) * 5644 }
        #expect(steps.allSatisfy { $0 >= 0 && $0 < 0.5 }, "moves a fraction of a point per frame, never back")
        #expect(rates.suffix(Int(10 * fps)).allSatisfy { $0 > 0 && $0 <= 6 }, "a few frames a second, not 60")
        #expect(abs((shown.last ?? 0) - (1 - 20 / total)) * 5644 < 3, "keeps up with the timer")
        // In Flow the ring rides along at the flow's own rate.
        #expect(ringed.frameRate(GlowMotionSettings(animation: .flow), audioActive: false) == GlowMotionConfig.flowFrameRate)
    }

    @Test func clearingTheRingRestoresTheNormalGlow() {
        let settings = GlowMotionSettings(animation: .flow)
        let ringed = motion(), plain = motion()
        ringed.setTimerRing(0.3)
        run([ringed, plain], seconds: 5, settings: settings)
        #expect(ringed.amplitude != plain.amplitude)
        ringed.setTimerRing(nil)
        run([ringed, plain], seconds: 0.3, settings: settings)
        #expect(ringed.shownTimerRing != nil, "refills first")
        run([ringed, plain], seconds: 5, settings: settings)
        #expect(ringed.shownTimerRing == nil)
        #expect(ringed.amplitude == plain.amplitude && ringed.width == plain.width)
    }

    @Test func finishPulsesThenStops() {
        let settings = GlowMotionSettings(animation: .steady)
        let ringed = motion()
        ringed.setTimerRing(0)
        run([ringed], seconds: 15, settings: settings)
        #expect(ringed.amplitude.allSatisfy { $0 < 0.001 }, "a finished timer's ring is empty")
        ringed.playTimerFinished()
        var widths: [Float] = []
        while ringed.needsFrames(settings, audioActive: false), widths.count < 300 {
            ringed.step(dt: 1 / fps, audio: nil, settings: settings)
            widths.append(ringed.width[0])
        }
        let seconds = Double(widths.count) / fps
        #expect(seconds > 2 && seconds < 3, "about 2.5 s, took \(seconds)")
        let peaks = widths.indices.dropFirst().dropLast().filter { widths[$0] > widths[$0 - 1] && widths[$0] >= widths[$0 + 1] && widths[$0] > 1.2 }
        #expect(peaks.count == 3, "three pulses")
        #expect(ringed.shownTimerRing == nil)
        #expect(ringed.amplitude.allSatisfy { $0 == 1 } && ringed.width.allSatisfy { $0 == 1 }, "back to the plain glow")
    }

    @Test func aNewTimerDuringThePulsesStartsFull() {
        let settings = GlowMotionSettings(animation: .steady)
        let ringed = motion()
        ringed.setTimerRing(0)
        run([ringed], seconds: 8, settings: settings)
        ringed.playTimerFinished()
        run([ringed], seconds: 1, settings: settings)
        ringed.setTimerRing(1)
        run([ringed], seconds: 3, settings: settings)
        #expect(ringed.shownTimerRing == 1)
        #expect(ringed.amplitude.allSatisfy { $0 == 1 })
    }
}
