import AppKit
import Foundation

/// What sort of thing a Dock tile is.
///
/// The Dock reports this directly as the tile's Accessibility subrole, and it has to be
/// carried around because the useful middle-click actions differ completely per kind: an
/// application can be asked for a new window, a folder cannot, and Trash has no parent
/// folder to be revealed in.
public enum DockItemKind: String, Codable, Sendable {
    case application
    case folder
    /// A pinned document — anything in the right-hand section that isn't a folder.
    case file
    /// A pinned web link.
    case webURL
    case trash
}

/// What middle-clicking a Dock tile does.
///
/// The application cases are mostly a keystroke sent *into* the app after activating it,
/// because that is how you ask a Mac application for a new window — there is no API for
/// "open another window of this app", only the command the app already publishes in its
/// own File menu. The file cases go through `NSWorkspace` instead, which needs no
/// cooperation from anything.
public enum DockAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case newWindow
    case newTab
    case newInstance
    case activate
    case hide
    case quit
    /// Opens the tile's own item: a folder or Trash in Finder, a document in whatever
    /// owns it, a link in the browser.
    case open
    /// Selects the item in its enclosing folder rather than opening it.
    case revealInFinder
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newWindow:      return "New Window (⌘N)"
        case .newTab:         return "New Tab (⌘T)"
        case .newInstance:    return "New Instance (second copy)"
        case .activate:       return "Bring to Front"
        case .hide:           return "Hide"
        case .quit:           return "Quit"
        case .open:           return "Open in Finder"
        case .revealInFinder: return "Reveal in Finder"
        case .none:           return "Do Nothing"
        }
    }

    /// `.open` means something different for each kind of tile, and a picker that reads
    /// "Open in Finder" next to a pinned web link is simply wrong.
    public func title(for kind: DockItemKind) -> String {
        switch (self, kind) {
        case (.open, .folder), (.open, .trash): return "Open in Finder"
        case (.open, .webURL):                  return "Open Link"
        case (.open, _):                        return "Open"
        default:                                return title
        }
    }

    /// Short form for the summary column and the feedback HUD.
    public var shortTitle: String {
        switch self {
        case .newWindow:      return "New Window"
        case .newTab:         return "New Tab"
        case .newInstance:    return "New Instance"
        case .activate:       return "Bring to Front"
        case .hide:           return "Hide"
        case .quit:           return "Quit"
        case .open:           return "Open"
        case .revealInFinder: return "Reveal"
        case .none:           return "Nothing"
        }
    }

    /// The keystroke this action sends, if any. `nil` means it is performed through
    /// `NSRunningApplication` or `NSWorkspace` instead of by synthesizing input.
    public var keystroke: (keyCode: CGKeyCode, modifiers: ModifierSet)? {
        switch self {
        case .newWindow: return (0x2D, [.command])   // N
        case .newTab:    return (0x11, [.command])   // T
        default:         return nil
        }
    }

    /// The choices worth offering for a given kind of tile, in menu order.
    ///
    /// Deliberately not `allCases` filtered by what happens to work: quitting a folder is
    /// not a thing to leave in a picker greyed out, it is a thing to leave out.
    public static func options(for kind: DockItemKind) -> [DockAction] {
        switch kind {
        case .application:
            return [.newWindow, .newTab, .newInstance, .activate, .hide, .quit,
                    .revealInFinder, .none]
        case .folder, .file:
            return [.open, .revealInFinder, .none]
        // Trash's parent folder is hidden, so revealing it lands you in a home folder
        // with nothing selected. A pinned link has no folder at all.
        case .trash, .webURL:
            return [.open, .none]
        }
    }

    /// The sensible default for each kind.
    ///
    /// For applications this is deliberately *not* `.newInstance`, which is what this
    /// feature used to do unconditionally. A second copy of an app is a strange thing to
    /// want — most apps refuse it, and the ones that allow it end up with two Dock tiles
    /// and two sets of unsaved state. "Another window of the app I already have" is the
    /// thing people actually mean, and that is ⌘N. For everything else the obvious
    /// default is the thing the tile already represents: open it.
    public static func fallback(for kind: DockItemKind) -> DockAction {
        kind == .application ? .newWindow : .open
    }
}

/// Per-tile middle-click behaviour, keyed by a stable identifier.
///
/// The key is a bundle identifier for applications and a path (or link URL) for
/// everything else, so a setting survives the tile being dragged elsewhere in the Dock,
/// renamed, or temporarily removed. Only tiles that differ from their kind's default are
/// stored — a Dock of forty apps left alone costs nothing, and adding one later picks up
/// the default rather than a stale blank.
///
/// Storage is a flat `[String: DockAction]` and always has been, so maps written before
/// folders and Trash were understood still decode and still resolve.
public struct DockActionMap: Codable, Equatable, Sendable {
    private var overrides: [String: DockAction]

    public init(overrides: [String: DockAction] = [:]) {
        self.overrides = overrides
    }

    public func action(for key: String, kind: DockItemKind = .application) -> DockAction {
        overrides[key] ?? DockAction.fallback(for: kind)
    }

    public mutating func set(_ action: DockAction, for key: String,
                             kind: DockItemKind = .application) {
        if action == DockAction.fallback(for: kind) {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = action
        }
    }

    public var customizedCount: Int { overrides.count }

    public mutating func resetAll() { overrides.removeAll() }
}
