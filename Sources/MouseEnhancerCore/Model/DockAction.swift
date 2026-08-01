import AppKit
import Foundation

/// What middle-clicking an app's Dock tile does.
///
/// Most of these are a keystroke sent *into* the app after activating it, because that
/// is how you ask a Mac application for a new window — there is no API for "open another
/// window of this app", only the command the app already publishes in its own File menu.
public enum DockAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case newWindow
    case newTab
    case newInstance
    case activate
    case hide
    case quit
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newWindow:   return "New Window (⌘N)"
        case .newTab:      return "New Tab (⌘T)"
        case .newInstance: return "New Instance (second copy)"
        case .activate:    return "Bring to Front"
        case .hide:        return "Hide"
        case .quit:        return "Quit"
        case .none:        return "Do Nothing"
        }
    }

    /// Short form for the summary column.
    public var shortTitle: String {
        switch self {
        case .newWindow:   return "New Window"
        case .newTab:      return "New Tab"
        case .newInstance: return "New Instance"
        case .activate:    return "Bring to Front"
        case .hide:        return "Hide"
        case .quit:        return "Quit"
        case .none:        return "Nothing"
        }
    }

    /// The keystroke this action sends, if any. `nil` means it is performed through
    /// `NSRunningApplication` instead of by synthesizing input.
    public var keystroke: (keyCode: CGKeyCode, modifiers: ModifierSet)? {
        switch self {
        case .newWindow: return (0x2D, [.command])   // N
        case .newTab:    return (0x11, [.command])   // T
        default:         return nil
        }
    }

    /// The sensible default for every app.
    ///
    /// Deliberately *not* `.newInstance`, which is what this feature used to do
    /// unconditionally. A second copy of an app is a strange thing to want — most apps
    /// refuse it, and the ones that allow it end up with two Dock tiles and two sets of
    /// unsaved state. "Another window of the app I already have" is the thing people
    /// actually mean, and that is ⌘N.
    public static let fallback: DockAction = .newWindow
}

/// Per-app middle-click behaviour, keyed by bundle identifier.
///
/// Keyed by bundle ID rather than by Dock position or tile name, so a setting survives
/// the app being dragged elsewhere in the Dock, renamed, or temporarily removed. Only
/// apps that differ from the default are stored — a Dock of forty apps left alone costs
/// nothing, and adding an app later picks up the default rather than a stale blank.
public struct DockActionMap: Codable, Equatable, Sendable {
    private var overrides: [String: DockAction]

    public init(overrides: [String: DockAction] = [:]) {
        self.overrides = overrides
    }

    public func action(for bundleID: String) -> DockAction {
        overrides[bundleID] ?? DockAction.fallback
    }

    public mutating func set(_ action: DockAction, for bundleID: String) {
        if action == DockAction.fallback {
            overrides.removeValue(forKey: bundleID)
        } else {
            overrides[bundleID] = action
        }
    }

    public var customizedCount: Int { overrides.count }

    public mutating func resetAll() { overrides.removeAll() }
}
