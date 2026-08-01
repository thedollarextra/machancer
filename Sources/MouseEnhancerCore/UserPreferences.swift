import SwiftUI
import Combine
import CoreGraphics

/// Single source of truth for configuration.
///
/// Note on `@AppStorage`: that wrapper only drives redraws when it lives inside a
/// `View`. Declared on an `ObservableObject` it silently fails to publish, so the
/// event tap would keep reading stale values. These are plain `UserDefaults`-backed
/// computed properties that call `objectWillChange` instead.
public final class UserPreferences: ObservableObject {
    public static let shared = UserPreferences()

    /// Factory calibration. Named so the Calibration tab's "Use Default" button and
    /// `resetToDefaults()` can't drift apart from the values used at first launch.
    public static let defaultHoldThresholdSec = 0.35
    public static let defaultDragThresholdPx = 15.0
    public static let defaultDoubleClickIntervalSec = 0.30
    /// Roughly the stock space-transition animation. Enough that a queued repeat lands
    /// rather than being swallowed, without feeling held back.
    public static let defaultSpaceSwitchGapSec = 0.32
    /// Mouse travel that equals one full trackpad swipe, per axis. Vertical is longer
    /// by default: spaces are a flick you repeat, Mission Control is one deliberate pull.
    public static let defaultSwipeDistanceXPx = 180.0
    public static let defaultSwipeDistanceYPx = 220.0
    /// Movement needed before a swipe commits to horizontal or vertical.
    public static let defaultSwipeAxisLockPx = 6.0

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cachedBindings = Self.loadBindings(from: defaults) ?? ActionBinding.defaults

        // Scalars are cached in memory rather than read through `UserDefaults` on
        // demand: `dragThresholdPx` is consulted on *every* drag event, and a
        // CFPreferences lookup plus dynamic cast in that path is pure waste.
        func number(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }

        _holdThresholdSec = number(Keys.holdThreshold, Self.defaultHoldThresholdSec)
        _dragThresholdPx = number(Keys.dragThreshold, Self.defaultDragThresholdPx)
        _doubleClickIntervalSec = number(Keys.doubleClickInterval, Self.defaultDoubleClickIntervalSec)
        _spaceSwitchGapSec = number(Keys.spaceSwitchGap, Self.defaultSpaceSwitchGapSec)
        // Migration: a single swipe distance used to cover both axes. If it was set,
        // adopt it for both rather than silently changing the feel on upgrade.
        let legacySwipe = defaults.object(forKey: Keys.swipeDistance) as? Double
        _swipeDistanceXPx = number(Keys.swipeDistanceX, legacySwipe ?? Self.defaultSwipeDistanceXPx)
        _swipeDistanceYPx = number(Keys.swipeDistanceY, legacySwipe ?? Self.defaultSwipeDistanceYPx)
        _swipeAxisLockPx = number(Keys.swipeAxisLock, Self.defaultSwipeAxisLockPx)
        _nativeDownSwipe = flag(Keys.nativeDownSwipe, false)
        _showActionFeedback = flag(Keys.showFeedback, true)
        _closeIgnoresDesktop = flag(Keys.closeIgnoresDesktop, true)
        _dockNewInstanceEnabled = flag(Keys.dockNewInstance, true)
        if let data = defaults.data(forKey: Keys.dockActions),
           let map = try? JSONDecoder().decode(DockActionMap.self, from: data) {
            _dockActions = map
        } else {
            _dockActions = DockActionMap()
        }
        // Prefer the scope object; fall back to the old exclusions array, which means
        // exactly the same thing expressed as a blacklist.
        if let data = defaults.data(forKey: Keys.globalScope),
           let scope = try? JSONDecoder().decode(AppScope.self, from: data) {
            _globalScope = scope
        } else {
            _globalScope = AppScope(
                mode: .exceptIn,
                bundleIDs: defaults.stringArray(forKey: Keys.exclusions) ?? []
            )
        }
    }

    // MARK: - Bindings

    /// Decoded once and held in memory: the event tap reads this on every mouse
    /// event, and re-parsing JSON in the hot path would be indefensible.
    private var cachedBindings: [ActionBinding]

    public var bindings: [ActionBinding] {
        get { cachedBindings }
        set {
            objectWillChange.send()
            cachedBindings = newValue
            indexIsStale = true
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.bindings)
            }
        }
    }

    // MARK: - Fast lookup index
    //
    // Rebuilt only when bindings change. Lookups happen several times per gesture on
    // the event-tap thread, so they resolve through a dictionary rather than a
    // predicate scan over the whole list.

    private var indexIsStale = true

    /// The rules in force for one frontmost app, after scope filtering.
    private struct EffectiveIndex {
        var byKey: [Int: ActionBinding] = [:]
        var chords: [ActionBinding] = []
        /// (button, modifiers) for anything bound at all, including chord partners.
        var boundCombos: Set<Int> = []
        /// (button, modifiers) whose click is a native pass-through.
        var passthroughClickCombos: Set<Int> = []
        /// (button, modifiers) with something other than a plain click riding on them —
        /// a hold, a drag, a double click, or a chord. Those must claim the press.
        var combosNeedingPress: Set<Int> = []
    }

    /// Bindings that survived `isActive`, most specific scope first, so laying them into
    /// the per-app index in order lets a scoped rule overwrite a broader one.
    private var rankedBindings: [ActionBinding] = []

    /// The per-app view is cached rather than rebuilt per event: the frontmost app
    /// changes a few times a minute, mouse events arrive hundreds of times a second.
    private var effectiveCache: EffectiveIndex?
    private var effectiveCacheApp: String??

    /// Packs a lookup into one Int: button (bits 8+), modifiers (bits 4-7), trigger (bits 0-3).
    @inline(__always)
    private static func key(_ button: Int, _ modifiers: ModifierSet, _ trigger: TriggerKind) -> Int {
        (button << 8) | (modifiers.rawValue << 4) | trigger.code
    }

    @inline(__always)
    private static func combo(_ button: Int, _ modifiers: ModifierSet) -> Int {
        (button << 8) | (modifiers.rawValue << 4)
    }

    private func rebuildIndexIfNeeded() {
        guard indexIsStale else { return }
        indexIsStale = false

        effectiveCache = nil
        effectiveCacheApp = nil
        _hasKeyboardBindings = false

        let active = cachedBindings.filter(\.isActive)
        _hasKeyboardBindings = active.contains { MouseButton.isKey($0.button) }

        // Broadest first: laying them into the per-app index in this order lets a more
        // specific scope overwrite a broader rule on the same input. `enumerated` keeps
        // the sort stable, so among equally specific rules the first still wins.
        rankedBindings = active.enumerated()
            .sorted { ($0.element.scopeSpecificity, $1.offset) < ($1.element.scopeSpecificity, $0.offset) }
            .map(\.element)
    }

    /// Extracts (button, modifiers) from a packed lookup key by dropping the trigger bits.
    @inline(__always)
    private static func comboOf(key: Int) -> Int { key & ~0xF }

    private func effectiveIndex(for app: String?) -> EffectiveIndex {
        rebuildIndexIfNeeded()
        if let cached = effectiveCache, effectiveCacheApp == .some(app) { return cached }

        var merged = EffectiveIndex()

        // The app-wide scope gates everything: outside it, this app has no bindings at
        // all and every button behaves natively.
        if globalScope.allows(app) {
            for binding in rankedBindings where binding.applies(to: app) {
                let key = Self.key(binding.button, binding.modifiers, binding.trigger)
                merged.byKey[key] = binding
                if binding.trigger == .chord { merged.chords.insert(binding, at: 0) }
            }
        }

        for (key, binding) in merged.byKey {
            let combo = Self.comboOf(key: key)
            merged.boundCombos.insert(combo)
            if binding.trigger == .click {
                if binding.action.isNativePassthrough(for: binding.button) {
                    merged.passthroughClickCombos.insert(combo)
                }
            } else {
                merged.combosNeedingPress.insert(combo)
            }
        }
        // Chord partners must count as bound too, or their press passes through and
        // the chord can never complete.
        for chord in merged.chords {
            if let partner = chord.chordPartner {
                let partnerCombo = Self.combo(partner, chord.modifiers)
                merged.boundCombos.insert(partnerCombo)
                merged.combosNeedingPress.insert(partnerCombo)
            }
        }

        effectiveCache = merged
        effectiveCacheApp = .some(app)
        return merged
    }

    /// True when this press can be left entirely alone: its click is a native
    /// pass-through and nothing else on the same button+modifiers needs the press held
    /// back to disambiguate. Letting the real event through beats re-posting a synthetic
    /// one — no latency, and the click state / timestamps stay authentic.
    public func isNativePassthrough(button: Int, modifiers: ModifierSet, app: String? = nil) -> Bool {
        let index = effectiveIndex(for: app)
        let combo = Self.combo(button, modifiers)
        return index.passthroughClickCombos.contains(combo) && !index.combosNeedingPress.contains(combo)
    }

    public func binding(
        button: Int, modifiers: ModifierSet, trigger: TriggerKind, app: String? = nil
    ) -> ActionBinding? {
        effectiveIndex(for: app).byKey[Self.key(button, modifiers, trigger)]
    }

    /// Any rule at all for this button + modifier combination — decides suppression at
    /// mouse-down, before we know which gesture the user is making.
    public func hasBinding(button: Int, modifiers: ModifierSet, app: String? = nil) -> Bool {
        effectiveIndex(for: app).boundCombos.contains(Self.combo(button, modifiers))
    }

    public func chordBinding(_ a: Int, _ b: Int, modifiers: ModifierSet, app: String? = nil) -> ActionBinding? {
        let chords = effectiveIndex(for: app).chords
        guard !chords.isEmpty else { return nil }
        return chords.first { $0.matchesChord(a, b, modifiers: modifiers) }
    }

    public func hasDoubleClickBinding(button: Int, modifiers: ModifierSet, app: String? = nil) -> Bool {
        binding(button: button, modifiers: modifiers, trigger: .doubleClick, app: app) != nil
    }

    private var _hasKeyboardBindings = false

    // MARK: - Conflicts

    /// IDs of bindings that can never fire because an earlier rule already claims the
    /// same input in an overlapping scope.
    ///
    /// Order is meaningful — the first match wins — but nothing in the UI said so, which
    /// made a shadowed rule look broken rather than outranked. Computed on demand from
    /// the settings window only; this is never consulted on the event path.
    public var shadowedBindingIDs: Set<UUID> {
        var shadowed: Set<UUID> = []
        var claimed: [Int: [ActionBinding]] = [:]

        for binding in cachedBindings where binding.isActive {
            let key = Self.key(binding.button, binding.modifiers, binding.trigger)
            let earlier = claimed[key] ?? []
            // Shadowed only if an earlier rule's scope covers everywhere this one applies.
            if earlier.contains(where: { $0.scopeCovers(binding) }) {
                shadowed.insert(binding.id)
            }
            claimed[key] = earlier + [binding]
        }
        return shadowed
    }

    /// Does any binding at all target a keyboard key? Checked by the tap manager on
    /// every keystroke system-wide, so it's a flag stamped at rebuild, not a scan.
    public var hasKeyboardBindings: Bool {
        rebuildIndexIfNeeded()
        return _hasKeyboardBindings
    }

    // MARK: - Dock

    /// Per-app middle-click behaviour. Only apps that differ from the default are
    /// stored, so this stays small however large the Dock is.
    private var _dockActions: DockActionMap
    public var dockActions: DockActionMap {
        get { _dockActions }
        set {
            objectWillChange.send()
            _dockActions = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.dockActions)
            }
        }
    }

    /// Hot path: read on every middle click, so it avoids copying the whole map.
    public func dockAction(for bundleID: String) -> DockAction {
        _dockActions.action(for: bundleID)
    }

    private var _dockNewInstanceEnabled: Bool
    public var dockNewInstanceEnabled: Bool {
        get { _dockNewInstanceEnabled }
        set { _dockNewInstanceEnabled = newValue; write(Keys.dockNewInstance, newValue) }
    }

    // MARK: - Gesture calibration

    /// Clamped: the Calibration tab now accepts a typed value, and a 0 or negative hold
    /// delay would fire the hold action on every press before the click could resolve.
    private var _holdThresholdSec: Double
    public var holdThresholdSec: Double {
        get { _holdThresholdSec }
        set {
            let clamped = min(max(newValue.isFinite ? newValue : Self.defaultHoldThresholdSec, 0.10), 2.0)
            _holdThresholdSec = clamped
            write(Keys.holdThreshold, clamped)
        }
    }

    private var _dragThresholdPx: Double
    public var dragThresholdPx: Double {
        get { _dragThresholdPx }
        set { _dragThresholdPx = newValue; write(Keys.dragThreshold, newValue) }
    }

    private var _doubleClickIntervalSec: Double
    public var doubleClickIntervalSec: Double {
        get { _doubleClickIntervalSec }
        set { _doubleClickIntervalSec = newValue; write(Keys.doubleClickInterval, newValue) }
    }

    /// Horizontal travel equal to one full swipe. Lower is more sensitive.
    private var _swipeDistanceXPx: Double
    public var swipeDistanceXPx: Double {
        get { _swipeDistanceXPx }
        set {
            let clamped = min(max(newValue.isFinite ? newValue : Self.defaultSwipeDistanceXPx, 40), 600)
            _swipeDistanceXPx = clamped
            write(Keys.swipeDistanceX, clamped)
        }
    }

    /// Vertical travel equal to one full swipe. Lower is more sensitive.
    private var _swipeDistanceYPx: Double
    public var swipeDistanceYPx: Double {
        get { _swipeDistanceYPx }
        set {
            let clamped = min(max(newValue.isFinite ? newValue : Self.defaultSwipeDistanceYPx, 40), 600)
            _swipeDistanceYPx = clamped
            write(Keys.swipeDistanceY, clamped)
        }
    }

    /// Travel before a swipe commits to horizontal or vertical.
    private var _swipeAxisLockPx: Double
    public var swipeAxisLockPx: Double {
        get { _swipeAxisLockPx }
        set {
            let clamped = min(max(newValue.isFinite ? newValue : Self.defaultSwipeAxisLockPx, 1), 40)
            _swipeAxisLockPx = clamped
            write(Keys.swipeAxisLock, clamped)
        }
    }

    /// Drive downward swipes as a live transition rather than triggering App Exposé on
    /// release.
    ///
    /// Whether this works is a property of the machine, not the code. On this system a
    /// downward dock swipe animates and then refuses to commit, so the reliable route is
    /// to measure the gesture and invoke Exposé outright — correct, but not continuous.
    /// Elsewhere, or on another macOS build, the native transition may commit fine and be
    /// noticeably smoother. Off by default because "works" beats "smooth"; turn it on to
    /// find out which kind of machine this is.
    private var _nativeDownSwipe: Bool
    public var nativeDownSwipe: Bool {
        get { _nativeDownSwipe }
        set { _nativeDownSwipe = newValue; write(Keys.nativeDownSwipe, newValue) }
    }

    /// How long a space switch waits behind the previous one. Clamped: a negative value
    /// is meaningless and anything above a second makes held repeats feel broken.
    private var _spaceSwitchGapSec: Double
    public var spaceSwitchGapSec: Double {
        get { _spaceSwitchGapSec }
        set {
            let clamped = min(max(newValue.isFinite ? newValue : Self.defaultSpaceSwitchGapSec, 0), 1.0)
            _spaceSwitchGapSec = clamped
            write(Keys.spaceSwitchGap, clamped)
        }
    }

    // MARK: - Feedback & safety

    private var _showActionFeedback: Bool
    public var showActionFeedback: Bool {
        get { _showActionFeedback }
        set { _showActionFeedback = newValue; write(Keys.showFeedback, newValue) }
    }

    /// Stops a stray click on empty desktop from closing whatever is behind it.
    private var _closeIgnoresDesktop: Bool
    public var closeIgnoresDesktop: Bool {
        get { _closeIgnoresDesktop }
        set { _closeIgnoresDesktop = newValue; write(Keys.closeIgnoresDesktop, newValue) }
    }

    // MARK: - Per-app exclusions

    private var _globalScope: AppScope

    /// Gates every binding. Defaults to a blacklist, which is what the old
    /// exclusions list was — so an existing setup keeps behaving identically while
    /// gaining the option to invert into a whitelist.
    public var globalScope: AppScope {
        get { _globalScope }
        set {
            objectWillChange.send()
            _globalScope = newValue
            invalidateScopeCache()
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.globalScope)
            }
            // Mirror into the legacy key so a downgrade doesn't silently drop the list.
            defaults.set(newValue.bundleIDs, forKey: Keys.exclusions)
        }
    }

    /// The app-wide list, whatever the mode is. Kept as the name the UI already uses.
    public var excludedBundleIDs: [String] {
        get { _globalScope.bundleIDs }
        set { globalScope = AppScope(mode: _globalScope.mode, bundleIDs: newValue) }
    }

    /// True when this app is shut out entirely by the app-wide scope.
    public func isExcluded(bundleID: String?) -> Bool {
        !_globalScope.allows(bundleID)
    }

    /// The per-app merge is derived from the scope, so changing it must drop the cache.
    private func invalidateScopeCache() {
        effectiveCache = nil
        effectiveCacheApp = nil
    }

    // MARK: - Storage plumbing

    private enum Keys {
        static let bindings = "bindings"
        static let dockNewInstance = "dockMiddleClickNewInstance"
        static let dockActions = "dockActions"
        static let holdThreshold = "holdThresholdSec"
        static let dragThreshold = "dragThresholdPx"
        static let doubleClickInterval = "doubleClickIntervalSec"
        static let spaceSwitchGap = "spaceSwitchGapSec"
        static let swipeDistance = "swipeDistancePx"      // legacy, migrated on load
        static let swipeDistanceX = "swipeDistanceXPx"
        static let swipeDistanceY = "swipeDistanceYPx"
        static let swipeAxisLock = "swipeAxisLockPx"
        static let nativeDownSwipe = "nativeDownSwipe"
        static let showFeedback = "showActionFeedback"
        static let closeIgnoresDesktop = "closeIgnoresDesktop"
        static let exclusions = "excludedBundleIDs"
        static let globalScope = "globalAppScope"
    }

    private static func loadBindings(from defaults: UserDefaults) -> [ActionBinding]? {
        guard let data = defaults.data(forKey: Keys.bindings) else { return nil }
        return try? JSONDecoder().decode([ActionBinding].self, from: data)
    }

    public func resetToDefaults() {
        bindings = ActionBinding.defaults
        holdThresholdSec = Self.defaultHoldThresholdSec
        dragThresholdPx = Self.defaultDragThresholdPx
        doubleClickIntervalSec = Self.defaultDoubleClickIntervalSec
        spaceSwitchGapSec = Self.defaultSpaceSwitchGapSec
        swipeDistanceXPx = Self.defaultSwipeDistanceXPx
        swipeDistanceYPx = Self.defaultSwipeDistanceYPx
        swipeAxisLockPx = Self.defaultSwipeAxisLockPx
        nativeDownSwipe = false
        showActionFeedback = true
        closeIgnoresDesktop = true
        dockNewInstanceEnabled = true
        dockActions = DockActionMap()
        globalScope = .everywhere
    }

    private func read<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    private func write<T>(_ key: String, _ value: T) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }
}
