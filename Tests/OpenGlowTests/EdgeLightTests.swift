import AppKit
import Testing
@testable import OpenGlow

@Suite("Edge geometry")
struct EdgeGeometryTests {
    let geometry = EdgeGeometry(size: CGSize(width: 1500, height: 1000), notch: nil)

    @Test func distanceGrowsInwardFromEachEdge() {
        // Middle of each edge, moving inward.
        let starts: [(CGPoint, CGVector)] = [
            (CGPoint(x: 750, y: 1000), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: 1500, y: 500), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: 750, y: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: 0, y: 500), CGVector(dx: 1, dy: 0)),
        ]
        for (start, inward) in starts {
            var previous: CGFloat = -1
            for step in stride(from: 0.0, through: 200, by: 10) {
                let d = geometry.point(at: CGPoint(x: start.x + inward.dx * step, y: start.y + inward.dy * step)).distance
                #expect(d > previous)
                #expect(abs(d - step) < 2, "far from corners the distance is the plain distance to the edge")
                previous = d
            }
        }
    }

    @Test func positionRunsClockwiseFromTopLeft() {
        let top = geometry.point(at: CGPoint(x: 750, y: 990)).position
        let right = geometry.point(at: CGPoint(x: 1490, y: 500)).position
        let bottom = geometry.point(at: CGPoint(x: 750, y: 10)).position
        let left = geometry.point(at: CGPoint(x: 10, y: 500)).position
        #expect(abs(top - 0.15) < 0.01)
        #expect(top < right && right < bottom && bottom < left)
    }

    @Test func cornersBendWithoutACrease() {
        // Along the diagonal into the top-right corner, distance and position change smoothly.
        var previous: EdgePoint?
        for step in stride(from: 1.0, through: 120, by: 1) {
            let point = geometry.point(at: CGPoint(x: 1500 - step, y: 1000 - step))
            if let previous {
                #expect(abs(point.distance - previous.distance) < 1.5)
                #expect(abs(point.position - previous.position) < 0.002)
            }
            previous = point
        }
    }

    @Test func lightWrapsTheNotch() {
        let notched = EdgeGeometry(
            size: CGSize(width: 1500, height: 1000),
            notch: NotchGeometry(leftEdgeX: 650, rightEdgeX: 850, bottomY: 968)
        )
        // Just under the notch the nearest edge is the notch's bottom, not the screen's top.
        let underNotch = notched.point(at: CGPoint(x: 750, y: 958)).distance
        #expect(underNotch < 12)
        #expect(geometry.point(at: CGPoint(x: 750, y: 958)).distance > 40)
        #expect(notched.notchDepth == 32)
    }
}

@Suite("Edge light")
@MainActor
struct EdgeLightTests {
    private func render(_ motion: GlowMotion, size: CGSize = CGSize(width: 1200, height: 800)) -> (EdgeLightRasterizer, [CGImage?]) {
        let rasterizer = EdgeLightRasterizer()
        rasterizer.configure(.init(size: size, notch: nil, falloff: 11, softness: 0.3, maximumWidth: 2.1), cells: motion.count)
        return (rasterizer, rasterizer.render(motion, brightness: 1))
    }

    private func alphaColumn(_ image: CGImage, column: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        return (0..<image.height).map { data[$0 * image.bytesPerRow + column * 4 + 3] }
    }

    @Test func brightestAtTheEdgeAndFadingInward() throws {
        let motion = GlowMotion()
        motion.step(dt: 0, audio: nil, settings: GlowMotionSettings(animation: .steady))
        let (rasterizer, images) = render(motion)
        let bottom = try #require(images[1])
        // Bottom strip: image row 0 is its top (innermost), the last row is the screen edge.
        let alphas = alphaColumn(bottom, column: bottom.width / 2).reversed()
        let values = Array(alphas)
        #expect(values[0] > 200, "the edge itself is near full brightness")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 >= $1 }, "never brighter further in")
        #expect(values.last == 0, "the strip's inner edge is fully faded")
        #expect(rasterizer.strips.count == 4)
    }

    @Test func middleOfTheScreenIsNeverLit() {
        let motion = GlowMotion()
        motion.step(dt: 0, audio: nil, settings: GlowMotionSettings(animation: .steady))
        let (rasterizer, _) = render(motion)
        let size = CGSize(width: 1200, height: 800)
        let center = CGRect(x: 0, y: 0, width: size.width, height: size.height).insetBy(dx: 300, dy: 300)
        for strip in rasterizer.strips {
            #expect(!strip.frame.intersects(center))
        }
    }

    @Test func steadyHoldsStill() {
        let motion = GlowMotion(palette: PalettePresets.preset(withID: "ember").palette)
        let settings = GlowMotionSettings(animation: .steady)
        motion.step(dt: 0, audio: nil, settings: settings)
        let before = motion.red
        for _ in 0..<60 { motion.step(dt: 1.0 / 30, audio: nil, settings: settings) }
        #expect(motion.red == before)
        #expect(!motion.needsFrames(settings, audioActive: false))
    }

    @Test func colorsFlowCounterClockwise() {
        let motion = GlowMotion(palette: PalettePresets.preset(withID: "ember").palette)
        let settings = GlowMotionSettings(animation: .flow)
        motion.step(dt: 0, audio: nil, settings: settings)
        let before = motion.green
        motion.step(dt: 0.5, audio: nil, settings: settings)
        let after = motion.green
        // The shift s that best satisfies after[i − s] ≈ before[i]: a feature at i moved to i − s,
        // so a positive s means it moved to lower positions — counter-clockwise.
        func error(shift: Int) -> Float {
            (0..<motion.count).reduce(0) { sum, i in
                let j = (i - shift + motion.count) % motion.count
                return sum + abs(after[j] - before[i])
            }
        }
        let best = (-20...20).min { error(shift: $0) < error(shift: $1) } ?? 0
        #expect(best > 0)
        #expect(motion.needsFrames(settings, audioActive: false))
    }

    @Test func paletteBalanceSetsEachColorsShare() {
        let red = PaletteColor(red: 1, green: 0, blue: 0)
        let blue = PaletteColor(red: 0, green: 0, blue: 1)
        for balance in [0.3, 0.5, 0.7] {
            let motion = GlowMotion(palette: GlowPalette(primary: red, secondary: blue, balance: balance))
            motion.step(dt: 0, audio: nil, settings: GlowMotionSettings(animation: .steady))
            let share = Double(motion.red.filter { $0 > 0.5 }.count) / Double(motion.count)
            #expect(abs(share - balance) < 0.12, "primary covers about \(balance), got \(share)")
        }
    }

    @Test func musicSwellsRiseSmoothlyAndTravel() {
        let motion = GlowMotion()
        motion.perimeterPoints = 4000
        let settings = GlowMotionSettings(animation: .musicSync)
        var quiet = AudioAnalysisState()
        quiet.hasAudio = true
        quiet.isSilent = false
        // Settle into music with no beats.
        for _ in 0..<90 { motion.step(dt: 1.0 / 60, audio: quiet, settings: settings) }
        let originCell = Int(GlowMotionConfig.swellOrigins[0] * Double(motion.count))
        let farCell = (originCell + motion.count / 4) % motion.count
        let restingOrigin = motion.amplitude[originCell]

        var beat = quiet
        beat.beatPulse = 1
        var originTrace: [Float] = []
        var farTrace: [Float] = []
        for frame in 0..<60 {
            // One big hit, decaying like the detector's pulse.
            beat.beatPulse = Float(exp(-Double(frame) / 60 / 0.22))
            motion.step(dt: 1.0 / 60, audio: beat, settings: settings)
            originTrace.append(motion.amplitude[(originCell - 2 + motion.count) % motion.count...(originCell + 2) % motion.count].max() ?? 0)
            farTrace.append(motion.amplitude[farCell])
        }
        let originPeak = originTrace.indices.max { originTrace[$0] < originTrace[$1] } ?? 0
        let farPeak = farTrace.indices.max { farTrace[$0] < farTrace[$1] } ?? 0
        #expect(originTrace.max()! > restingOrigin + 0.3, "a big hit makes a clear swell")
        #expect(farPeak > originPeak, "the swell reaches the far side later")
        // Smooth: no frame-to-frame jump bigger than a fifth of full brightness.
        #expect(zip(originTrace, originTrace.dropFirst()).allSatisfy { abs($0 - $1) < 0.2 })
    }

    @Test func openingSweepRisesFromTheBottomAndSettles() {
        let motion = GlowMotion()
        motion.introOrigin = 0.625
        let settings = GlowMotionSettings(animation: .steady)
        motion.startIntro()
        motion.step(dt: 0.4, audio: nil, settings: settings)
        let origin = Int(0.625 * Double(motion.count))
        let top = Int(0.125 * Double(motion.count))
        #expect(motion.amplitude[origin] > 0.5, "lit where it starts")
        #expect(motion.amplitude[top] < 0.05, "still dark where the fronts haven't reached")
        #expect(motion.needsFrames(settings, audioActive: false), "keeps animating while it plays")
        for _ in 0..<120 { motion.step(dt: 1.0 / 30, audio: nil, settings: settings) }
        #expect(motion.amplitude.allSatisfy { abs($0 - 1) < 0.001 }, "settles into the plain glow")
        #expect(!motion.needsFrames(settings, audioActive: false), "and then stops asking for frames")
    }
}
