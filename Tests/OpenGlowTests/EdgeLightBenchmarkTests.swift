import AppKit
import Testing
@testable import OpenGlow

/// Per-frame cost of the edge light on a 1710×1112 pt notched screen: `GlowMotion.step` and
/// `EdgeLightRasterizer.render`, as median and p95 over a few hundred frames, with the frame rate
/// the motion asks for and the cells drawn per frame.
/// Only runs when OPENGLOW_BENCH is set; meant for release builds:
/// `OPENGLOW_BENCH=1 ./Scripts/test.sh -c release -Xswiftc -enable-testing --filter EdgeLightBenchmark`.
/// OPENGLOW_BENCH_PACE=<fps> sleeps between frames like a display link would, so the core clocks
/// down between frames as it does in the app (run under `taskpolicy -c background` to stay on the
/// efficiency cores).
@Suite("Edge light benchmark", .serialized)
@MainActor
struct EdgeLightBenchmarkTests {
    nonisolated private static let enabled = ProcessInfo.processInfo.environment["OPENGLOW_BENCH"] != nil
    nonisolated private static let pace = ProcessInfo.processInfo.environment["OPENGLOW_BENCH_PACE"].flatMap(Double.init)
    private let size = CGSize(width: 1710, height: 1112)
    private let notch = NotchGeometry(leftEdgeX: 755, rightEdgeX: 955, bottomY: 1080)

    /// The same 92 BPM groove as the preview.
    private func groove(at time: Double) -> AudioAnalysisState {
        var state = AudioAnalysisState()
        state.hasAudio = true
        state.isSilent = false
        let beat = 60.0 / 92
        let index = Int(time / beat)
        let since = time - Double(index) * beat
        state.beatPulse = (index % 2 == 0 ? 1 : 0.22) * Float(exp(-since / 0.22))
        state.bass = 0.55 + 0.35 * Float(max(0, cos(2 * .pi * time / (beat * 4))))
        state.leftEnergy = 0.8
        state.rightEnergy = 0.8
        return state
    }

    private func measure(_ name: String, settings: GlowMotionSettings, fps: Double, music: Bool) {
        let rasterizer = EdgeLightRasterizer()
        let motion = GlowMotion(palette: PalettePresets.preset(withID: "ember").palette)
        let shape = EdgeLightRasterizer.Shape(
            size: size, notch: notch, falloff: GlowDefaults.thickness, softness: Float(GlowDefaults.softness),
            maximumWidth: 1 + GlowMotionConfig.musicWidthGain
        )
        rasterizer.configure(shape, cells: motion.count)
        motion.perimeterPoints = Double(EdgeGeometry(size: size, notch: notch).perimeter)
        let brightness = Float(GlowDefaults.brightness)
        var steps: [Double] = []
        var renders: [Double] = []
        var rates: [Double] = []
        var cells = 0
        var drawn = 0
        let frames = 600, warmup = 60
        var time = 0.0
        for frame in 0..<(frames + warmup) {
            let frameStart = DispatchTime.now().uptimeNanoseconds
            motion.step(dt: 1 / fps, audio: music ? groove(at: time) : nil, settings: settings)
            let stepped = DispatchTime.now().uptimeNanoseconds
            let surfaces = rasterizer.render(motion, brightness: brightness)
            let rendered = DispatchTime.now().uptimeNanoseconds
            time += 1 / fps
            if frame >= warmup {
                steps.append(Double(stepped - frameStart) / 1e6)
                renders.append(Double(rendered - stepped) / 1e6)
                rates.append(motion.frameRate(settings, audioActive: music))
                if surfaces != nil {
                    drawn += 1
                    cells += rasterizer.lastCellCount
                }
            }
            if let pace = Self.pace {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1e9
                Thread.sleep(forTimeInterval: max(1 / pace - elapsed, 0))
            }
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.3f ms, p95 %.3f ms", sorted[sorted.count / 2], sorted[sorted.count * 95 / 100])
        }
        let totals = zip(steps, renders).map(+)
        let rate = rates.sorted()[rates.count / 2]
        print("BENCH \(name): step \(stats(steps)); render \(stats(renders)); total \(stats(totals)); asks \(Int(rate)) fps (median), drew \(drawn)/\(frames) frames, \(cells / max(drawn, 1)) cells each")
    }

    @Test(.enabled(if: enabled))
    func idleFlow() {
        measure("flow", settings: GlowMotionSettings(animation: .flow), fps: 20, music: false)
    }

    /// How much the light at the edge changes from one frame to the next in the idle flow, at a
    /// few frame rates: the largest and 99th-percentile step of any color channel, in 8-bit levels.
    @Test(.enabled(if: enabled))
    func flowStepSizes() {
        for fps in [30.0, 20, 15] {
            let motion = GlowMotion(palette: GlowPalette(
                primary: PaletteColor(red: 0.95, green: 0.25, blue: 0.35),
                secondary: PaletteColor(red: 0.2, green: 0.9, blue: 0.45),
                balance: 0.55
            ))
            let settings = GlowMotionSettings(animation: .flow)
            let brightness = Float(GlowDefaults.brightness)
            func levels() -> [Float] {
                (0..<motion.count).flatMap { i in
                    [motion.red[i], motion.green[i], motion.blue[i]].map { $0 * motion.amplitude[i] * brightness * 255 }
                }
            }
            motion.step(dt: 0, audio: nil, settings: settings)
            var previous = levels()
            var steps: [Float] = []
            for _ in 0..<Int(30 * fps) {
                motion.step(dt: 1 / fps, audio: nil, settings: settings)
                let current = levels()
                steps.append(contentsOf: zip(current, previous).map { abs($0 - $1) })
                previous = current
            }
            steps.sort()
            print(String(format: "BENCH flow steps at %.0f fps: max %.1f levels, p99 %.1f", fps, steps.last ?? 0, steps[steps.count * 99 / 100]))
        }
    }

    @Test(.enabled(if: enabled))
    func music() {
        measure("music", settings: GlowMotionSettings(animation: .musicSync), fps: 60, music: true)
    }
}
