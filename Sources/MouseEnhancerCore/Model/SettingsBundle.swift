import Foundation

/// Everything the user has configured, in one codable document.
///
/// Exists so a setup can be backed up and carried to another Mac. All the per-binding
/// tuning in this app lives in `UserDefaults`, which is invisible, easy to lose to a
/// clean install, and awkward to copy between machines.
///
/// Every field is optional on the way in: an export from an older build must still
/// import, filling anything it predates from the current defaults rather than failing.
public struct SettingsBundle: Codable {
    /// Bumped only when a change would be *misread* by an older build, which has not
    /// happened yet — new fields are additive and older exports decode fine.
    public static let currentFormat = 1

    public var format: Int?
    public var exportedBy: String?
    public var bindings: [ActionBinding]?
    public var globalScope: AppScope?
    public var dockActions: DockActionMap?

    public var holdThresholdSec: Double?
    public var dragThresholdPx: Double?
    public var doubleClickIntervalSec: Double?
    public var spaceSwitchGapSec: Double?
    public var swipeDistanceXPx: Double?
    public var swipeDistanceYPx: Double?
    public var swipeAxisLockPx: Double?
    public var nativeDownSwipe: Bool?
    public var showActionFeedback: Bool?
    public var closeIgnoresDesktop: Bool?
    public var dockMiddleClickEnabled: Bool?

    public init() {}

    /// Pretty-printed with sorted keys: an exported file is something a person may well
    /// open, diff, or keep under version control.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> SettingsBundle {
        try JSONDecoder().decode(SettingsBundle.self, from: data)
    }
}

public extension UserPreferences {
    /// Snapshot of everything configurable.
    func exportSettings() -> SettingsBundle {
        var bundle = SettingsBundle()
        bundle.format = SettingsBundle.currentFormat
        bundle.exportedBy = AppInfo.versionString
        bundle.bindings = bindings
        bundle.globalScope = globalScope
        bundle.dockActions = dockActions
        bundle.holdThresholdSec = holdThresholdSec
        bundle.dragThresholdPx = dragThresholdPx
        bundle.doubleClickIntervalSec = doubleClickIntervalSec
        bundle.spaceSwitchGapSec = spaceSwitchGapSec
        bundle.swipeDistanceXPx = swipeDistanceXPx
        bundle.swipeDistanceYPx = swipeDistanceYPx
        bundle.swipeAxisLockPx = swipeAxisLockPx
        bundle.nativeDownSwipe = nativeDownSwipe
        bundle.showActionFeedback = showActionFeedback
        bundle.closeIgnoresDesktop = closeIgnoresDesktop
        bundle.dockMiddleClickEnabled = dockNewInstanceEnabled
        return bundle
    }

    /// Applies an imported bundle. Absent fields are left as they are, so importing a
    /// file that predates a setting doesn't silently reset it.
    ///
    /// Every scalar goes through its own property, which means each one is clamped on
    /// the way in — a hand-edited file cannot install a hold delay of zero or a swipe
    /// sensitivity that makes the gesture impossible to trigger.
    func importSettings(_ bundle: SettingsBundle) {
        if let value = bundle.bindings { bindings = value }
        if let value = bundle.globalScope { globalScope = value }
        if let value = bundle.dockActions { dockActions = value }
        if let value = bundle.holdThresholdSec { holdThresholdSec = value }
        if let value = bundle.dragThresholdPx { dragThresholdPx = value }
        if let value = bundle.doubleClickIntervalSec { doubleClickIntervalSec = value }
        if let value = bundle.spaceSwitchGapSec { spaceSwitchGapSec = value }
        if let value = bundle.swipeDistanceXPx { swipeDistanceXPx = value }
        if let value = bundle.swipeDistanceYPx { swipeDistanceYPx = value }
        if let value = bundle.swipeAxisLockPx { swipeAxisLockPx = value }
        if let value = bundle.nativeDownSwipe { nativeDownSwipe = value }
        if let value = bundle.showActionFeedback { showActionFeedback = value }
        if let value = bundle.closeIgnoresDesktop { closeIgnoresDesktop = value }
        if let value = bundle.dockMiddleClickEnabled { dockNewInstanceEnabled = value }
    }
}
