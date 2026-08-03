import CoreGraphics
import Foundation

/// One position in macOS's own window tiling — the entries under **Window ▸ Move &
/// Resize**.
///
/// This deliberately drives *macOS's* tiling rather than setting the window's frame
/// ourselves. Doing the geometry directly is easy and would even look similar, but it
/// produces a window that merely happens to be half-screen-sized: no tiling group, no
/// margins setting, no "Return to Previous Size" to undo it. Going through the menu
/// means a window tiled from here is indistinguishable from one tiled by dragging it to
/// the screen edge.
public enum WindowTile: String, CaseIterable, Sendable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case fill, center, restore

    /// Which menu the item is actually in.
    ///
    /// Not a guess. Every published summary of macOS tiling lists Fill and Center
    /// alongside the halves, and they are not there — reading a real menu with
    /// `AXMenuItem` showed Fill and Center sitting directly in the Window menu, one
    /// level above Move & Resize, which holds only the eight positions and the restore.
    public enum Location {
        case windowMenu
        case moveAndResize
    }

    public var location: Location {
        switch self {
        case .fill, .center: return .windowMenu
        default:             return .moveAndResize
        }
    }

    /// The menu item's title, which is how it is found.
    public var menuTitle: String {
        switch self {
        case .left:         return "Left"
        case .right:        return "Right"
        case .top:          return "Top"
        case .bottom:       return "Bottom"
        case .topLeft:      return "Top Left"
        case .topRight:     return "Top Right"
        case .bottomLeft:   return "Bottom Left"
        case .bottomRight:  return "Bottom Right"
        case .fill:         return "Fill"
        case .center:       return "Center"
        case .restore:      return "Return to Previous Size"
        }
    }

    /// A last-resort keystroke, used only when the menu cannot be read at all.
    ///
    /// Best-effort and nothing more. Reading the real menu's `AXMenuItemCmdChar` found
    /// a key equivalent on Center alone — Fill, the halves and the quarters all reported
    /// none. So these are what Apple documents rather than what this Mac exposes, they
    /// may match nothing, and the menu is the route that actually works. They stay
    /// because the menu walk matches English titles and this is all that is left on a
    /// system that isn't in English.
    ///
    /// Every one carries Fn as well as Control; see `ActionDispatcher.key`.
    public var shortcut: (key: CGKeyCode, modifiers: ModifierSet)? {
        switch self {
        case .left:   return (0x7B, .control)
        case .right:  return (0x7C, .control)
        case .bottom: return (0x7D, .control)
        case .top:    return (0x7E, .control)
        case .fill:   return (0x03, .control)   // F
        case .center: return (0x08, .control)   // C
        case .topLeft, .topRight, .bottomLeft, .bottomRight, .restore: return nil
        }
    }

    /// The action a binding names, mapped to the position it means.
    public init?(_ kind: ActionKind) {
        switch kind {
        case .tileLeft:        self = .left
        case .tileRight:       self = .right
        case .tileTop:         self = .top
        case .tileBottom:      self = .bottom
        case .tileTopLeft:     self = .topLeft
        case .tileTopRight:    self = .topRight
        case .tileBottomLeft:  self = .bottomLeft
        case .tileBottomRight: self = .bottomRight
        case .tileFill:        self = .fill
        case .tileCenter:      self = .center
        case .tileRestore:     self = .restore
        default: return nil
        }
    }
}
