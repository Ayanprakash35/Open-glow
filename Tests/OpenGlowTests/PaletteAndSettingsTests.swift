import AppKit
import Foundation
import Testing
@testable import OpenGlow

@Suite("Palette gradient stops")
struct PaletteStopTests {
    private let red = PaletteColor(red: 1, green: 0, blue: 0)
    private let blue = PaletteColor(red: 0, green: 0, blue: 1)

    @Test(arguments: [0.0, 0.001, 0.2, 0.35, 0.5, 0.65, 0.8, 0.999, 1.0])
    func stopsAreWellFormed(balance: Double) {
        let stops = GlowPalette(primary: red, secondary: blue, balance: balance).conicStops()
        #expect(stops.count == GlowPalette.conicStopCount)
        #expect(stops.first?.location == 0)
        #expect(stops.last?.location == 1)
        // Monotonic, so Core Animation never sees stops out of order.
        #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location <= $1.location })
        // Seamless: the circle starts and ends on the same color.
        #expect(stops.first?.color == stops.last?.color)
    }

    @Test func primaryCoversItsBalanceShare() {
        for balance in [0.3, 0.5, 0.7] {
            let stops = GlowPalette(primary: red, secondary: blue, balance: balance).conicStops(transition: 0)
            // With a hard transition, primary spans [0, b/2] and [1 - b/2, 1].
            let primaryShare = stops[1].location + (1 - stops[4].location)
            #expect(abs(primaryShare - balance) < 1e-9)
        }
    }

    @Test func singleColorPalettesStaySolid() {
        let same = GlowPalette(primary: red, secondary: red, balance: 0.5).conicStops()
        #expect(same.allSatisfy { $0.color == red })
        let primaryOnly = GlowPalette(primary: red, secondary: blue, balance: 1).conicStops()
        #expect(primaryOnly.allSatisfy { $0.color == red })
        let secondaryOnly = GlowPalette(primary: red, secondary: blue, balance: 0).conicStops()
        #expect(secondaryOnly.allSatisfy { $0.color == blue })
    }

    @Test func colorsConvertThroughSRGB() throws {
        let p3Red = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        let converted = try #require(PaletteColor(p3Red))
        // Display P3's red lies outside sRGB; conversion must clamp rather than overflow.
        #expect(converted.red <= 1 && converted.green >= 0 && converted.blue >= 0)
        let gray = try #require(PaletteColor(NSColor(white: 0.5, alpha: 1)))
        #expect(abs(gray.red - gray.green) < 0.01 && abs(gray.green - gray.blue) < 0.01)
    }

    @Test func presetsResolveAndFallBack() {
        #expect(PalettePresets.preset(withID: "ember").id == "ember")
        #expect(PalettePresets.preset(withID: "no-such-preset").id == PalettePresets.all[0].id)
        #expect(Set(PalettePresets.all.map(\.id)).count == PalettePresets.all.count)
    }
}

@Suite("Settings persistence")
@MainActor
struct SettingsPersistenceTests {
    private func freshDefaults() -> UserDefaults {
        let name = "OpenGlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsMatchTheTunedValues() {
        let settings = Settings(defaults: freshDefaults())
        #expect(settings.isEnabled)
        #expect(settings.animationMode == .musicSync)
        #expect(settings.colorMode == .albumArt)
        #expect(settings.brightness == Double(GlowDefaults.brightness))
        #expect(settings.thickness == Double(GlowDefaults.thickness))
        #expect(settings.softness == Double(GlowDefaults.softness))
        #expect(settings.reactivity == 0.5)
        #expect(settings.flowSpeed == 1)
        #expect(settings.manualPalette == .fallback)
    }

    @Test func valuesSurviveARelaunch() {
        let defaults = freshDefaults()
        let first = Settings(defaults: defaults)
        first.colorMode = .manual
        first.manualPalette = GlowPalette(primary: PaletteColor(red: 1, green: 0.5, blue: 0), secondary: PaletteColor(red: 0, green: 1, blue: 1), balance: 0.3)
        first.presetID = "aurora"
        first.thickness = 30
        first.reactivity = 0.9
        first.flowSpeed = 2
        first.setDisplayEnabled(false, uuid: "DISPLAY-A")

        let second = Settings(defaults: defaults)
        #expect(second.colorMode == .manual)
        #expect(second.manualPalette == first.manualPalette)
        #expect(second.presetID == "aurora")
        #expect(second.thickness == 30)
        #expect(second.reactivity == 0.9)
        #expect(second.flowSpeed == 2)
        #expect(!second.isDisplayEnabled(uuid: "DISPLAY-A"))
        #expect(second.isDisplayEnabled(uuid: "DISPLAY-B"))
    }

    @Test func outOfRangeStoredValuesAreClamped() {
        let defaults = freshDefaults()
        defaults.set(500.0, forKey: "edgeThickness")
        defaults.set(-3.0, forKey: "edgeBrightness")
        defaults.set(Double.nan, forKey: "edgeSoftness")
        defaults.set("gone", forKey: "presetID")
        let settings = Settings(defaults: defaults)
        #expect(settings.thickness == SettingsRange.thickness.upperBound)
        #expect(settings.brightness == SettingsRange.brightness.lowerBound)
        #expect(settings.softness == Double(GlowDefaults.softness))
        #expect(settings.presetID == PalettePresets.defaultID)
    }

    @Test func changesAreReportedOnceAndOnlyWhenTheValueChanges() {
        let settings = Settings(defaults: freshDefaults())
        var changes: [Settings.Change] = []
        settings.onChange = { changes.append($0) }
        settings.thickness = settings.thickness
        settings.colorMode = .albumArt
        #expect(changes.isEmpty)
        settings.thickness = 20
        settings.colorMode = .preset
        settings.presetID = "lagoon"
        settings.manualPalette.balance = 0.4
        settings.flowSpeed = 1.5
        #expect(changes == [.shape, .colorMode, .preset, .manualPalette, .flowSpeed])
    }

    @Test func chosenPaletteFollowsTheMode() {
        let settings = Settings(defaults: freshDefaults())
        settings.presetID = "ember"
        settings.colorMode = .preset
        #expect(settings.chosenPalette == PalettePresets.preset(withID: "ember").palette)
        settings.colorMode = .manual
        #expect(settings.chosenPalette == settings.manualPalette)
    }

    @Test func preferencesCarryOverFromGlowbarOnce() {
        let legacy = freshDefaults()
        legacy.set("flow", forKey: "animationMode")
        legacy.set(25.0, forKey: "edgeThickness")
        legacy.set(0.3, forKey: "edgeBrightness")
        let current = freshDefaults()
        current.set(0.9, forKey: "edgeBrightness")

        Settings.migrateFromGlowbar(into: current, from: legacy)
        let settings = Settings(defaults: current)
        #expect(settings.animationMode == .flow)
        #expect(settings.thickness == 25)
        #expect(settings.brightness == 0.9, "a value already set under the new name wins")
        #expect(!settings.hasCompletedOnboarding, "the tour still shows after the rename")

        // Only ever once.
        current.removeObject(forKey: "animationMode")
        Settings.migrateFromGlowbar(into: current, from: legacy)
        #expect(current.string(forKey: "animationMode") == nil)
    }
}
