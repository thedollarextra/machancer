import Foundation
import ServiceManagement

/// Launch-at-login, via `SMAppService` (macOS 13+).
///
/// The registration lives in the system's login-item database, not in our defaults,
/// so `isEnabled` always reports the real state — including a user turning it off in
/// System Settings behind our back.
public enum LoginItem {

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a human-readable reason it failed.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // Re-registering an already-registered app throws; treat as success.
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return describe(error)
        }
    }

    /// `SMAppService` surfaces most problems as bare OSStatus values.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case 1:
            return "Blocked — approve “MacHancer” in System Settings → General → Login Items."
        case 2:
            return "Not found — move the app to /Applications and try again."
        default:
            return nsError.localizedDescription
        }
    }

    /// Login items are matched by bundle path; running from a temporary or
    /// synced location makes the registration unreliable.
    public static var isInStableLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
