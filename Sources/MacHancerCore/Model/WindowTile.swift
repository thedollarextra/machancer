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

    /// macOS ships a key equivalent for **Center only**.
    ///
    /// Read off a real menu with `AXMenuItemCmdChar`: Fill, all four halves and all four
    /// quarters report none. Kept as a recorded measurement rather than a mechanism —
    /// there is no keystroke path any more, because posting a shortcut that does not
    /// exist earns a system beep and, for the halves, collides with space switching.
    public var hasSystemShortcut: Bool { self == .center }

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
