import AppKit

/// Runs a closure as a menu item's action, so menus built in code (the right-click menu, the
/// Timer submenu) don't need an `@objc` method per item.
@MainActor
final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func runAction(_ sender: Any?) {
        run()
    }
}

extension NSMenuItem {
    /// An item that runs `action` when chosen.
    @MainActor
    convenience init(title: String, keyEquivalent: String = "", run action: @escaping () -> Void) {
        let handler = MenuAction(action)
        self.init(title: title, action: #selector(MenuAction.runAction(_:)), keyEquivalent: keyEquivalent)
        target = handler
        // `target` is weak; the item keeps its handler alive through this.
        representedObject = handler
    }
}
