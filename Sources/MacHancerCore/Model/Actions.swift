import Foundation

/// Everything a binding can do. Payload-carrying kinds read their extra data from
/// `ActionSpec` rather than from associated values, which keeps the enum usable as a
/// `Picker` tag and trivially codable.
public enum ActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none

    /// Deliver the physical button to the OS untouched. macOS already maps buttons 4
    /// and 5 to back/forward system-wide, and apps that use them natively (browsers,
    /// editors, games) do their own thing with them — which a `⌘[` translation cannot
    /// reproduce. See `ActionSpec.mouseButtonNumber` for the button sent.
    case mouseButton

    // Navigation
    case navigateBack
    case navigateForward

    // Spaces & window management
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight

    // macOS window tiling — the entries under Window ▸ Move & Resize
    case tileLeft
    case tileRight
    case tileTop
    case tileBottom
    case tileTopLeft
    case tileTopRight
    case tileBottomLeft
    case tileBottomRight
    case tileFill
    case tileCenter
    case tileRestore
    case tileRestoreOrMinimize

    // Windows under the cursor
    case closeWindow
    case minimizeWindow
    case quitApp

    // Media & volume
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute

    // Capture
    case screenshot
    case screenshotArea

    // Payload-carrying
    case customKeystroke
    case launchApplication
    case runShortcut
    case macro

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none:              return "None"
        case .mouseButton:       return "Mouse Button…"
        case .navigateBack:      return "Navigate Back (⌘[)"
        case .navigateForward:   return "Navigate Forward (⌘])"
        case .missionControl:    return "Mission Control"
        case .appExpose:         return "App Exposé"
        case .showDesktop:       return "Show Desktop"
        case .launchpad:         return "Launchpad"
        case .spaceLeft:         return "Space Left"
        case .spaceRight:        return "Space Right"
        case .tileLeft:          return "Tile Left"
        case .tileRight:         return "Tile Right"
        case .tileTop:           return "Tile Top"
        case .tileBottom:        return "Tile Bottom"
        case .tileTopLeft:       return "Tile Top Left"
        case .tileTopRight:      return "Tile Top Right"
        case .tileBottomLeft:    return "Tile Bottom Left"
        case .tileBottomRight:   return "Tile Bottom Right"
        case .tileFill:          return "Fill Screen"
        case .tileCenter:        return "Center Window"
        case .tileRestore:       return "Return to Previous Size"
        case .tileRestoreOrMinimize: return "Restore, or Minimize"
        case .closeWindow:       return "Close Window under Cursor"
        case .minimizeWindow:    return "Minimize Window under Cursor"
        case .quitApp:           return "Quit App under Cursor"
        case .playPause:         return "Play / Pause"
        case .nextTrack:         return "Next Track"
        case .previousTrack:     return "Previous Track"
        case .volumeUp:          return "Volume Up"
        case .volumeDown:        return "Volume Down"
        case .mute:              return "Mute"
        case .screenshot:        return "Screenshot (Full Screen)"
        case .screenshotArea:    return "Screenshot (Selection)"
        case .customKeystroke:   return "Custom Keystroke…"
        case .launchApplication: return "Launch Application…"
        case .runShortcut:       return "Run Shortcut…"
        case .macro:             return "Macro…"
        }
    }

    public var group: String {
        switch self {
        case .none: return ""
        case .mouseButton: return "Mouse"
        case .navigateBack, .navigateForward: return "Navigation"
        case .missionControl, .appExpose, .showDesktop, .launchpad, .spaceLeft, .spaceRight:
            return "Spaces"
        case .tileLeft, .tileRight, .tileTop, .tileBottom,
             .tileTopLeft, .tileTopRight, .tileBottomLeft, .tileBottomRight,
             .tileFill, .tileCenter, .tileRestore, .tileRestoreOrMinimize:
            return "Tiling"
        case .closeWindow, .minimizeWindow, .quitApp: return "Windows"
        case .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute:
            return "Media"
        case .screenshot, .screenshotArea: return "Capture"
        case .customKeystroke, .launchApplication, .runShortcut, .macro: return "Custom"
        }
    }

    public static let groupOrder = ["Mouse", "Navigation", "Spaces", "Tiling", "Windows", "Media", "Capture", "Custom"]

    /// Precomputed for the action picker. Filtering `allCases` per group inside a
    /// SwiftUI body would redo that work for every visible binding row on every
    /// redraw.
    public static let grouped: [(group: String, kinds: [ActionKind])] = groupOrder.map { group in
        (group, allCases.filter { $0.group == group })
    }

    /// Kinds that need extra configuration before they can run.
    public var requiresPayload: Bool {
        switch self {
        case .customKeystroke, .launchApplication, .runShortcut, .mouseButton, .macro: return true
        default: return false
        }
    }

    /// Kinds a macro step may invoke: anything that runs standalone with no payload.
    /// Macros are excluded (no recursion) and payload kinds have their own step types.
    public static let macroInvocable: [ActionKind] = allCases.filter {
        $0 != .none && $0 != .macro && !$0.requiresPayload
    }

    /// Destructive actions get an extra confirmation option in the UI.
    public var isDestructive: Bool {
        switch self {
        case .closeWindow, .quitApp: return true
        default: return false
        }
    }
}

/// One step of a `.macro` action.
///
/// A flat enum-of-payloads rather than nested `ActionSpec`s: it keeps the model
/// non-recursive (no macro-in-macro), trivially codable, and each step type gets
/// exactly the editor it needs in the UI.
public struct MacroStep: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case keystroke
        case mouseClick
        case action
        case delay

        public var title: String {
            switch self {
            case .keystroke:  return "Keystroke"
            case .mouseClick: return "Mouse Click"
            case .action:     return "Action"
            case .delay:      return "Wait"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// `.keystroke`: what to press.
    public var keystroke: Keystroke?
    /// `.mouseClick`: `CGEvent` button number (0 = left, 1 = right, 2 = middle…).
    public var mouseButton: Int?
    /// `.action`: a payload-free built-in, from `ActionKind.macroInvocable`.
    public var actionKind: ActionKind?
    /// `.delay`: seconds to wait before the next step.
    public var delaySec: Double?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        keystroke: Keystroke? = nil,
        mouseButton: Int? = nil,
        actionKind: ActionKind? = nil,
        delaySec: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.keystroke = keystroke
        self.mouseButton = mouseButton
        self.actionKind = actionKind
        self.delaySec = delaySec
    }

    /// A step that is fully configured and will actually do something.
    public var isConfigured: Bool {
        switch kind {
        case .keystroke:  return keystroke != nil
        case .mouseClick: return mouseButton != nil
        case .action:     return actionKind != nil && actionKind != Optional(.none)
        case .delay:      return (delaySec ?? 0) > 0
        }
    }

    public var summary: String {
        switch kind {
        case .keystroke:  return keystroke.map { "Press \($0.display)" } ?? "Keystroke (not set)"
        case .mouseClick: return mouseButton.map { "Click \(MouseButton.label($0))" } ?? "Click (not set)"
        case .action:     return actionKind?.title ?? "Action (not set)"
        case .delay:      return String(format: "Wait %.2fs", delaySec ?? 0)
        }
    }
}

/// An action plus whatever payload its kind requires.
public struct ActionSpec: Codable, Hashable, Sendable {
    public var kind: ActionKind
    public var keystroke: Keystroke?
    public var applicationPath: String?
    public var shortcutName: String?
    /// For `.mouseButton`: which `CGEvent` button number to deliver. `nil` means "the
    /// same button the binding fired on", which is the common case — Button 4 staying
    /// Button 4 — and keeps the payload valid if the binding's button is later changed.
    public var mouseButtonNumber: Int?
    /// For `.macro`: the steps to run, in order.
    public var macroSteps: [MacroStep]?

    public init(
        kind: ActionKind = .none,
        keystroke: Keystroke? = nil,
        applicationPath: String? = nil,
        shortcutName: String? = nil,
        mouseButtonNumber: Int? = nil,
        macroSteps: [MacroStep]? = nil
    ) {
        self.kind = kind
        self.keystroke = keystroke
        self.applicationPath = applicationPath
        self.shortcutName = shortcutName
        self.mouseButtonNumber = mouseButtonNumber
        self.macroSteps = macroSteps
    }

    /// True when this is a plain "be the button you already are" pass-through, which
    /// the engine can satisfy by simply not suppressing the event.
    public func isNativePassthrough(for button: Int) -> Bool {
        kind == .mouseButton && (mouseButtonNumber ?? button) == button
    }

    public static let none = ActionSpec()

    /// True when the action can actually run — a `.customKeystroke` with no recorded
    /// key is configured but inert, and the UI flags it.
    public var isRunnable: Bool {
        switch kind {
        case .none: return false
        case .mouseButton: return true   // nil payload is meaningful: "stay yourself"
        case .customKeystroke: return keystroke != nil
        case .launchApplication: return applicationPath != nil
        case .runShortcut: return !(shortcutName ?? "").isEmpty
        case .macro: return (macroSteps ?? []).contains { $0.isConfigured }
        default: return true
        }
    }

    public var displayName: String {
        switch kind {
        case .mouseButton:
            guard let number = mouseButtonNumber else { return "Native Mouse Button" }
            return "Native " + MouseButton.label(number)

        case .customKeystroke:
            return keystroke.map { "Keystroke \($0.display)" } ?? "Custom Keystroke (not set)"
        case .launchApplication:
            guard let path = applicationPath else { return "Launch Application (not set)" }
            return "Launch " + (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
        case .runShortcut:
            let name = shortcutName ?? ""
            return name.isEmpty ? "Run Shortcut (not set)" : "Run Shortcut “\(name)”"

        case .macro:
            let count = (macroSteps ?? []).count
            return count == 0 ? "Macro (empty)" : "Macro (\(count) step\(count == 1 ? "" : "s"))"
        default:
            return kind.title
        }
    }
}
