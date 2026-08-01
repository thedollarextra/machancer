import CoreGraphics
import Foundation

/// What the user did with the button.
public enum TriggerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case click
    case doubleClick
    case hold
    case dragUp
    case dragDown
    case dragLeft
    case dragRight
    case chord
    /// Hold the button and move: emits a live trackpad-style dock swipe that tracks the
    /// drag. One binding covers all four directions, because the window server decides
    /// what a swipe means — up is Mission Control, down App Exposé, left/right spaces.
    case swipe

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .click:       return "Click"
        case .doubleClick: return "Double Click"
        case .hold:        return "Press & Hold"
        case .dragUp:      return "Drag Up"
        case .dragDown:    return "Drag Down"
        case .dragLeft:    return "Drag Left"
        case .dragRight:   return "Drag Right"
        case .chord:       return "Chord (with another button)"
        case .swipe:       return "Hold & Swipe (trackpad-style)"
        }
    }

    /// Stable small integer for packing into the preference lookup key.
    /// Explicit rather than derived from `allCases`, which would be a linear search.
    var code: Int {
        switch self {
        case .click:       return 0
        case .doubleClick: return 1
        case .hold:        return 2
        case .dragUp:      return 3
        case .dragDown:    return 4
        case .dragLeft:    return 5
        case .dragRight:   return 6
        case .chord:       return 7
        case .swipe:       return 8
        }
    }

    public var isDrag: Bool {
        switch self {
        case .dragUp, .dragDown, .dragLeft, .dragRight: return true
        default: return false
        }
    }
}

/// Mouse buttons, as `CGEvent` button numbers. Buttons 0/1 (left/right) are
/// deliberately unbindable — remapping them is how you lock yourself out of a Mac.
///
/// Keyboard keys share this namespace, offset by `keyNamespace`: the gesture engine
/// tracks presses by integer identity and doesn't care whether the integer began life
/// as a mouse button or a key code, which is what lets keys inherit click, double-click
/// and hold behaviour without a parallel state machine.
public enum MouseButton {
    public static let middle = 2
    public static let button4 = 3
    public static let button5 = 4

    /// Everything the UI offers. `CGEvent` supports up to 31.
    public static let bindable = Array(2...15)

    /// Key codes live above any possible mouse button number.
    public static let keyNamespace = 0x1000

    public static func keyButton(_ keyCode: UInt16) -> Int { keyNamespace + Int(keyCode) }
    public static func isKey(_ number: Int) -> Bool { number >= keyNamespace }
    public static func keyCode(_ number: Int) -> UInt16? {
        isKey(number) ? UInt16(number - keyNamespace) : nil
    }

    public static func label(_ number: Int) -> String {
        if let code = keyCode(number) { return "⌨ " + KeyNames.name(for: code) }
        switch number {
        case 0: return "Left Click"
        case 1: return "Right Click"
        case 2: return "Middle Click"
        case 3: return "Button 4"
        case 4: return "Button 5"
        default: return "Button \(number + 1)"
        }
    }
}

/// One user-configured rule: button + exact modifier combination + trigger → action.
public struct ActionBinding: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var button: Int
    public var modifiers: ModifierSet
    public var trigger: TriggerKind
    /// Only meaningful when `trigger == .chord`: the button that must be held with it.
    public var chordPartner: Int?
    public var action: ActionSpec
    public var isEnabled: Bool
    /// Ask before running. Offered for destructive actions like close/quit.
    public var requiresConfirmation: Bool

    // Per-binding timing overrides. `nil` means "inherit the Calibration default", which
    // is what every binding does until the user unticks Global on that row. Optional and
    // synthesized-Codable, so bindings saved before these existed still decode.
    /// Seconds to hold before `.hold` fires.
    public var holdDelay: Double?
    /// Pixels of travel before a drag trigger fires.
    public var dragDistance: Double?
    /// Seconds allowed between the two clicks of `.doubleClick`.
    public var doubleClickInterval: Double?

    // Swipe sensitivity, per axis, because horizontal and vertical want different
    // travel: spaces are a flick you repeat, Mission Control is one deliberate pull.
    // Separate from `dragDistance` — a drag threshold is "how far before it counts",
    // a swipe distance is "how far equals a full swipe", and tuning one shouldn't
    // disturb the other.
    /// Pixels of horizontal travel equal to one full swipe.
    public var swipeDistanceX: Double?
    /// Pixels of vertical travel equal to one full swipe.
    public var swipeDistanceY: Double?

    /// Where this binding applies. `nil` means everywhere.
    ///
    /// A binding scoped to an app overrides an unscoped one on the same input while
    /// that app is frontmost; outside its scope it simply doesn't exist, and whatever
    /// broader rule sits underneath takes over.
    public var scope: AppScope?

    /// Superseded by `scope`, kept so bindings saved with the single-app field still
    /// load. Read through `effectiveScope`, never directly.
    public var appScope: String?

    /// The scope actually in force, migrating the old single-app field on the fly.
    public var effectiveScope: AppScope {
        if let scope { return scope }
        if let appScope { return AppScope(mode: .onlyIn, bundleIDs: [appScope]) }
        return .everywhere
    }

    /// Is this binding live while `bundleID` is frontmost?
    public func applies(to bundleID: String?) -> Bool {
        effectiveScope.allows(bundleID)
    }

    /// Scoped rules beat unscoped ones on the same input. Ranked so the index can lay
    /// the more specific rule over the broader one.
    public var scopeSpecificity: Int {
        switch effectiveScope.mode {
        case .onlyIn:     return 2
        case .exceptIn:   return 1
        case .everywhere: return 0
        }
    }

    public init(
        id: UUID = UUID(),
        button: Int,
        modifiers: ModifierSet = [],
        trigger: TriggerKind = .click,
        chordPartner: Int? = nil,
        action: ActionSpec,
        isEnabled: Bool = true,
        requiresConfirmation: Bool = false,
        holdDelay: Double? = nil,
        dragDistance: Double? = nil,
        doubleClickInterval: Double? = nil,
        swipeDistanceX: Double? = nil,
        swipeDistanceY: Double? = nil,
        scope: AppScope? = nil,
        appScope: String? = nil
    ) {
        self.id = id
        self.button = button
        self.modifiers = modifiers
        self.trigger = trigger
        self.chordPartner = chordPartner
        self.action = action
        self.isEnabled = isEnabled
        self.requiresConfirmation = requiresConfirmation
        self.holdDelay = holdDelay
        self.dragDistance = dragDistance
        self.doubleClickInterval = doubleClickInterval
        self.swipeDistanceX = swipeDistanceX
        self.swipeDistanceY = swipeDistanceY
        self.scope = scope
        self.appScope = appScope
    }

    /// Travel equal to one full swipe on the given axis.
    ///
    /// Falls back through the per-binding axis override, then `dragDistance` (which is
    /// where swipe distance lived before the axes were split, so an existing swipe
    /// binding keeps its feel), then the global default for that axis.
    public func swipeDistance(horizontal: Bool, globalX: Double, globalY: Double) -> Double {
        let axisOverride = horizontal ? swipeDistanceX : swipeDistanceY
        return max(axisOverride ?? dragDistance ?? (horizontal ? globalX : globalY), 1)
    }

    /// Would this rule apply everywhere `other` does, and so shadow it entirely?
    ///
    /// Conservative on purpose: a partial overlap is not a conflict worth warning about,
    /// because "⌘4 in Safari" and "⌘4 everywhere" are a perfectly ordinary pair — the
    /// specific one is *meant* to win in its app. Only a rule whose reach is a superset
    /// makes the later one dead everywhere.
    public func scopeCovers(_ other: ActionBinding) -> Bool {
        let mine = effectiveScope
        let theirs = other.effectiveScope

        switch (mine.mode, theirs.mode) {
        case (.everywhere, _):
            return true
        case (.onlyIn, .onlyIn):
            return Set(theirs.bundleIDs).isSubset(of: Set(mine.bundleIDs))
        case (.exceptIn, .exceptIn):
            // Excluding fewer apps means applying in more of them.
            return Set(mine.bundleIDs).isSubset(of: Set(theirs.bundleIDs))
        case (.exceptIn, .onlyIn):
            return Set(theirs.bundleIDs).isDisjoint(with: Set(mine.bundleIDs))
        default:
            return false
        }
    }

    /// Triggers that make sense for this binding's input. Keys have no cursor, so the
    /// drag family is out; chords stay mouse-side where the pairing UI lives.
    /// A key has no cursor, so drag and swipe are meaningless for it; chords stay
    /// mouse-side where the pairing UI lives.
    public var availableTriggers: [TriggerKind] {
        MouseButton.isKey(button) ? [.click, .doubleClick, .hold] : TriggerKind.allCases
    }

    /// Which timing knob, if any, this binding's trigger actually uses. Click and chord
    /// have nothing to tune, so their rows show no control at all.
    public enum TimingKnob { case hold, dragDistance, doubleClick, swipeDistance }

    public var timingKnob: TimingKnob? {
        switch trigger {
        case .hold:                                     return .hold
        case .doubleClick:                              return .doubleClick
        case .dragUp, .dragDown, .dragLeft, .dragRight: return .dragDistance
        case .swipe:                                    return .swipeDistance
        case .click, .chord:                            return nil
        }
    }

    /// True when this rule is live: enabled, and its action can actually run.
    ///
    /// A swipe carries no action — the gesture itself is the whole behaviour, and what
    /// it does is the window server's decision — so it is live on being enabled alone.
    public var isActive: Bool { isEnabled && (trigger == .swipe || action.isRunnable) }

    /// Does this rule apply to a press of `button` with exactly `modifiers` held?
    ///
    /// Exact match, not a subset: ⌘+Button 4 must not also fire the plain Button 4
    /// binding, or every modified click would trigger two actions.
    public func matches(button: Int, modifiers: ModifierSet) -> Bool {
        self.button == button && self.modifiers == modifiers
    }

    /// Order-insensitive chord match — pressing 4-then-5 is the same gesture as 5-then-4.
    public func matchesChord(_ a: Int, _ b: Int, modifiers: ModifierSet) -> Bool {
        guard trigger == .chord, let partner = chordPartner, self.modifiers == modifiers
        else { return false }
        return (button == a && partner == b) || (button == b && partner == a)
    }

    public var summary: String {
        var parts: [String] = []
        if !modifiers.isEmpty { parts.append(modifiers.symbols) }
        parts.append(MouseButton.label(button))
        if trigger == .chord, let partner = chordPartner {
            parts.append("+ \(MouseButton.label(partner))")
        } else {
            parts.append("· \(trigger.title)")
        }
        return parts.joined(separator: " ")
    }

    /// The bindings a fresh install starts with — the behaviour the original spec
    /// described, expressed in the general model.
    public static var defaults: [ActionBinding] {
        [
            // Plain 4/5 stay native. macOS already routes them to back/forward, and apps
            // that handle them directly keep working — translating to ⌘[ / ⌘] only ever
            // matched a subset of what the button already did.
            ActionBinding(button: MouseButton.button4, action: ActionSpec(kind: .mouseButton)),
            ActionBinding(button: MouseButton.button5, action: ActionSpec(kind: .mouseButton)),
            ActionBinding(button: MouseButton.button5, trigger: .hold, action: ActionSpec(kind: .appExpose)),
            ActionBinding(button: MouseButton.button5, trigger: .dragUp, action: ActionSpec(kind: .missionControl)),
            ActionBinding(button: MouseButton.button5, trigger: .dragDown, action: ActionSpec(kind: .appExpose)),
            // The spec's Ctrl+Option+Cmd+middle-click close chord is just another binding now.
            ActionBinding(
                button: MouseButton.middle,
                modifiers: [.control, .option, .command],
                action: ActionSpec(kind: .closeWindow)
            ),
        ]
    }
}
