import AppKit
import ApplicationServices

/// Drives macOS's window tiling by pressing an app's own menu item.
///
/// The menu is the source of truth rather than the keyboard shortcut, and reading a
/// real menu is what settled it. Only Center reports a key equivalent at all; Fill, the
/// halves and all four quarters report none, so a keystroke implementation would have
/// covered one position out of eleven. The menu also works when the user has turned the
/// tiling shortcuts off, and — the part that matters for honest feedback — pressing a
/// menu item reports whether it worked, where posting a keystroke only reports that the
/// event left the building.
///
/// Setting the window's frame ourselves was the other option and is rejected on
/// purpose: it produces a window that merely happens to be half-screen-sized, with no
/// tiling group, no margins setting and nothing for Return to Previous Size to undo.
public enum WindowTiler {

    /// The one localized string this depends on.
    ///
    /// The Window menu is deliberately *not* matched by name — that title is localized
    /// too, and it doesn't need to be: the menu holding a "Move & Resize" item is the
    /// Window menu, whatever it calls itself. One string instead of two.
    private static let submenuTitle = "Move & Resize"

    /// Bounded so a pathological or cyclic menu tree cannot occupy the dispatcher's
    /// queue indefinitely. Real menu bars are a dozen or so wide.
    private static let maxTopLevelMenus = 32

    /// Returns whether the window actually moved, as far as that is knowable.
    public static func apply(
        _ tile: WindowTile,
        in pid: pid_t?,
        sendKey: (CGKeyCode, ModifierSet) -> Bool
    ) -> Bool {
        if let pid, let item = menuItem(tile.menuTitle, at: tile.location, in: pid) {
            // A disabled item is the honest answer to "tile what?" — no window, or one
            // that refuses to be resized. Press reports that as failure, which is
            // exactly what should reach the HUD.
            return AX.perform(item, kAXPressAction as String)
        }
        guard let shortcut = tile.shortcut else { return false }
        return sendKey(shortcut.key, shortcut.modifiers)
    }

    /// Whether this window has a previous size to go back to — i.e. whether it is
    /// currently tiled or zoomed.
    ///
    /// macOS already tracks this and shows it: Return to Previous Size is greyed out
    /// for an ordinary window and live for a tiled one. Reading that is better than any
    /// geometry test we could invent, because it is the same answer the system will act
    /// on a moment later. Comparing the frame against the screen would have to guess at
    /// margins, menu bar, Dock and multi-display layout, and would still disagree with
    /// macOS at the edges.
    public static func isRestorable(in pid: pid_t?) -> Bool {
        guard let pid,
              let item = menuItem(WindowTile.restore.menuTitle, at: .moveAndResize, in: pid)
        else { return false }
        return AX.bool(item, kAXEnabledAttribute as String) ?? false
    }

    /// Finds a tiling menu item in `pid`'s menu bar.
    private static func menuItem(
        _ title: String,
        at location: WindowTile.Location,
        in pid: pid_t
    ) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        guard let menuBar = AX.child(axApp, kAXMenuBarAttribute as String) else { return nil }

        for topLevel in AX.children(menuBar).prefix(maxTopLevelMenus) {
            // A menu bar item holds one child: the menu itself.
            guard let menu = AX.children(topLevel).first else { continue }
            let items = AX.children(menu)

            // Both cases hinge on finding Move & Resize — for one it is the container,
            // for the other it is only the marker identifying which menu we are in.
            guard let container = items.first(where: { titled($0) == submenuTitle })
            else { continue }

            switch location {
            case .windowMenu:
                return items.first { titled($0) == title }
            case .moveAndResize:
                guard let submenu = AX.children(container).first else { return nil }
                return AX.children(submenu).first { titled($0) == title }
            }
        }
        return nil
    }

    private static func titled(_ element: AXUIElement) -> String? {
        AX.string(element, kAXTitleAttribute as String)
    }
}
