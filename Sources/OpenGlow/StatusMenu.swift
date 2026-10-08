import AppKit

/// Right-click menu tunables.
enum StatusMenuConfig {
    /// Size of the color swatch beside each preset in the Colors submenu, in points. Sane range:
    /// 16×8 to 28×14; taller than about 14 makes the rows taller than plain ones.
    static let swatchSize = NSSize(width: 22, height: 10)
}

/// The status item's right-click menu: the popover's settings and the app's features as menu
/// items, plus whatever needs the user's attention. Settings are read and written straight
/// through `Settings`, as the popover does, so the two always agree; everything else goes
/// through `Actions`.
@MainActor
enum StatusMenu {
    /// What the menu shows besides the settings themselves.
    struct State {
        var displays: [DisplayInfo]
        var musicSync: MusicSyncStatus
        /// Whether any overlay is drawn: Open Glow on and at least one display checked. A preview
        /// glow has nowhere to play otherwise.
        var glowVisible: Bool
        var launchAtLogin: LaunchAtLogin.State
    }

    /// What the items that aren't plain settings do; `AppDelegate` supplies them.
    struct Actions {
        var openSettings: () -> Void
        var grantScreenRecording: () -> Void
        var relaunch: () -> Void
        /// Plays the tool's session glow now.
        var previewCodingSession: (CodingSessionMonitor.Tool) -> Void
        var setLaunchAtLogin: (Bool) -> Void
        var openLoginItems: () -> Void
        var openTour: () -> Void
        var quit: () -> Void
    }

    /// The whole menu. `timerItem` is `TimerPresenter`'s Timer submenu.
    static func make(settings: Settings, state: State, timerItem: NSMenuItem, actions: Actions) -> NSMenu {
        let menu = menu([
            NSMenuItem(title: settings.isEnabled ? "Turn Off" : "Turn On") { settings.isEnabled.toggle() },
            NSMenuItem(title: "Settings…", keyEquivalent: ",", run: actions.openSettings),
            .separator(),
            animationItem(settings),
            colorsItem(settings, actions: actions),
            stereoItem(settings),
            displaysItem(settings, displays: state.displays),
            notchItem(settings),
            .separator(),
            timerItem,
            codingSessionsItem(settings, glowVisible: state.glowVisible, actions: actions),
        ])
        let attention = attentionItems(for: state.musicSync, actions: actions)
        if !attention.isEmpty {
            menu.addItem(.separator())
            attention.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        launchAtLoginItems(state.launchAtLogin, actions: actions).forEach(menu.addItem)
        menu.addItem(NSMenuItem(title: "Welcome Tour…", run: actions.openTour))
        menu.addItem(NSMenuItem(title: "Quit Open Glow", keyEquivalent: "q", run: actions.quit))
        return menu
    }

    // MARK: Look

    private static func animationItem(_ settings: Settings) -> NSMenuItem {
        submenu("Animation", [("Music Sync", AnimationMode.musicSync), ("Flow", .flow), ("Steady", .steady)].map { title, mode in
            check(title, on: settings.animationMode == mode) { settings.animationMode = mode }
        })
    }

    /// The color source; every preset by name, ticked only while presets are the source; which
    /// players album colors follow; and a way to the gradient's color wells.
    static func colorsItem(_ settings: Settings, actions: Actions) -> NSMenuItem {
        var items = [("Album Art", ColorMode.albumArt), ("Gradient", .manual), ("Presets", .preset)].map { title, mode in
            check(title, on: settings.colorMode == mode) { settings.colorMode = mode }
        }
        items.append(.separator())
        for preset in PalettePresets.all {
            let item = check(preset.name, on: settings.colorMode == .preset && settings.presetID == preset.id) {
                // The preset first: switching the mode then fades straight to it, not to the
                // previously chosen preset and on.
                settings.presetID = preset.id
                settings.colorMode = .preset
            }
            item.image = swatch(preset.palette)
            items.append(item)
        }
        items.append(.separator())
        items.append(.sectionHeader(title: "Album Art From"))
        items.append(check("Apple Music", on: settings.followAppleMusic) { settings.followAppleMusic.toggle() })
        items.append(check("Spotify", on: settings.followSpotify) { settings.followSpotify.toggle() })
        items.append(.separator())
        // The popover only shows the color wells while the gradient is the source, so editing it
        // makes it the source.
        items.append(NSMenuItem(title: "Edit Gradient…") {
            settings.colorMode = .manual
            actions.openSettings()
        })
        return submenu("Colors", items)
    }

    private static func stereoItem(_ settings: Settings) -> NSMenuItem {
        check("Stereo Mode", on: settings.stereoModeEnabled) { settings.stereoModeEnabled.toggle() }
    }

    private static func displaysItem(_ settings: Settings, displays: [DisplayInfo]) -> NSMenuItem {
        submenu("Displays", displays.map { display in
            check(display.name, on: settings.isDisplayEnabled(uuid: display.uuid)) {
                settings.setDisplayEnabled(!settings.isDisplayEnabled(uuid: display.uuid), uuid: display.uuid)
            }
        })
    }

    private static func notchItem(_ settings: Settings) -> NSMenuItem {
        submenu("Notch", [("Curve Around", NotchMode.curveAround), ("Ignore", .ignore)].map { title, mode in
            check(title, on: settings.notchMode == mode) { settings.notchMode = mode }
        })
    }

    // MARK: Features

    /// The session glow on or off, which tools get it, and a preview of each tool's colors.
    static func codingSessionsItem(_ settings: Settings, glowVisible: Bool, actions: Actions) -> NSMenuItem {
        typealias Tool = CodingSessionMonitor.Tool
        var items: [NSMenuItem] = [
            check("Glow When a Session Starts", on: settings.codingSessionGlow) { settings.codingSessionGlow.toggle() },
            .separator(),
        ]
        for tool in Tool.allCases {
            let item = check(tool.displayName, on: settings.codingSessionTools.contains(tool)) {
                settings.setCodingSessionGlow(!settings.codingSessionTools.contains(tool), for: tool)
            }
            item.isEnabled = settings.codingSessionGlow
            items.append(item)
        }
        items.append(.separator())
        for tool in Tool.allCases {
            let item = NSMenuItem(title: "Preview \(tool.displayName) Glow") { actions.previewCodingSession(tool) }
            item.isEnabled = glowVisible
            if !glowVisible { item.toolTip = "Turn Open Glow and a display on to see the preview." }
            items.append(item)
        }
        return submenu("Coding Sessions", items)
    }

    /// Shown whenever Music Sync can't work — never fail silently: what's wrong, then what helps.
    static func attentionItems(for status: MusicSyncStatus, actions: Actions) -> [NSMenuItem] {
        let relaunch = NSMenuItem(title: "Relaunch Open Glow", run: actions.relaunch)
        switch status {
        case .needsPermission:
            return [
                warning("Music Sync needs Screen Recording access", status: status),
                NSMenuItem(title: "Grant Screen Recording Access…", run: actions.grantScreenRecording),
                relaunch,
            ]
        case .captureFailed:
            // Not a permission problem (that's `.needsPermission`): a fresh capture is the only
            // thing worth offering.
            return [warning("Music Sync can't capture audio", status: status), relaunch]
        case .captureUnreadable:
            return [warning("Music Sync can't read the captured audio", status: status), relaunch]
        case .off, .steady, .starting, .listening:
            return []
        }
    }

    /// Launch at Login reads as on while registered, approved or not, as the popover's toggle
    /// does; choosing it again turns it off. While macOS waits for approval, an item leads there.
    static func launchAtLoginItems(_ state: LaunchAtLogin.State, actions: Actions) -> [NSMenuItem] {
        let isOn = state != .disabled
        let item = check("Launch at Login", on: isOn) { actions.setLaunchAtLogin(!isOn) }
        guard state == .requiresApproval else { return [item] }
        let allow = NSMenuItem(title: "Allow in Login Items…", run: actions.openLoginItems)
        allow.indentationLevel = 1
        allow.toolTip = "macOS needs you to allow Open Glow in Login Items."
        return [item, allow]
    }

    // MARK: Pieces

    /// A small capsule of `palette`'s colors, drawn as the popover's swatches are.
    static func swatch(_ palette: GlowPalette) -> NSImage {
        // Drawn whenever the menu needs it, in its own appearance, so the rim follows dark mode.
        NSImage(size: StatusMenuConfig.swatchSize, flipped: false) { rect in
            let primary = palette.primary.nsColor
            let secondary = palette.secondary.nsColor
            let share = min(max(palette.balance, 0), 1)
            let shape = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: shape, xRadius: shape.height / 2, yRadius: shape.height / 2)
            let gradient = NSGradient(
                colors: [primary, primary, secondary, secondary],
                atLocations: [0, share * 0.5, share + (1 - share) * 0.5, 1],
                colorSpace: .sRGB
            )
            gradient?.draw(in: path, angle: 0)
            // A faint rim keeps pale presets visible on a light menu.
            NSColor.labelColor.withAlphaComponent(0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    private static func check(_ title: String, on: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, run: action)
        item.state = on ? .on : .off
        return item
    }

    /// A disabled line naming the problem, with the warning glyph and the icon's full tooltip.
    private static func warning(_ title: String, status: MusicSyncStatus) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = NSImage(systemSymbolName: StatusIcon.warningSymbol, accessibilityDescription: "Warning")
        // Only the warning statuses reach here, and their text doesn't depend on the switch.
        item.toolTip = StatusIcon(status: status, glowEnabled: true).description
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu(items)
        return item
    }

    /// Items keep the enabled state they're given: the menu doesn't validate them.
    private static func menu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }
}
