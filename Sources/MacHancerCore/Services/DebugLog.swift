import Foundation

/// Appends diagnostic lines to a file.
///
/// `NSLog` from this bundled agent does not reach the unified log on this system —
/// `log show --predicate 'process == "MacHancer"'` returns nothing even while the
/// app is demonstrably running and executing the logging call. Rather than keep
/// diagnosing through a channel that silently drops everything, write somewhere whose
/// success can be confirmed by looking at it.
///
/// Cheap and off by default: enable with
///     defaults write com.machancer.MacHancer debugLog -bool YES
public enum DebugLog {
    public static let path = NSHomeDirectory() + "/Library/Logs/MacHancer.log"

    /// Public so the hot paths can skip building a message at all: these call sites
    /// interpolate strings on every mouse event, and `@autoclosure` defers the work but
    /// still costs a call.
    ///
    /// Re-read on preference change rather than once at launch, so turning the log on
    /// takes effect immediately — the settings window is a separate process now, and
    /// "change it, then relaunch the agent" is a poor way to start diagnosing.
    public private(set) static var isEnabled = readEnabled()

    /// How long one grant of key-name logging lasts.
    public static let keyNameWindow: TimeInterval = 3600

    /// When the current grant runs out, as seconds since 1970. Zero means never granted.
    private static var keyNamesUntil = readKeyNamesUntil()

    /// Whether the log may name *which* key was pressed.
    ///
    /// Keyboard keys ride the same engine as mouse buttons, so every keystroke on the
    /// system reaches `record`, and naming them turns a plain-text file in
    /// `~/Library/Logs` into a transcript of everything typed. So this is not a switch
    /// that can be left on: it is a *grant*, stamped with an expiry, and it lapses an
    /// hour later whether or not anyone remembers to go back and turn it off. Diagnosing
    /// a key binding takes a minute; the risk is forgetting, not the minute.
    ///
    /// Read against the clock on each call rather than latched at grant time, so it stops
    /// mid-session exactly when it should instead of at the next relaunch.
    public static var recordsKeyNames: Bool {
        keyNamesUntil > Date().timeIntervalSince1970
    }

    /// Seconds left on the grant, or `nil` once it has lapsed. For the settings window,
    /// which should say how long is left rather than just "on".
    public static var keyNameGrantRemaining: TimeInterval? {
        let remaining = keyNamesUntil - Date().timeIntervalSince1970
        return remaining > 0 ? remaining : nil
    }

    /// Picks up a change made in the settings process.
    public static func refreshSettings() {
        isEnabled = readEnabled()
        keyNamesUntil = readKeyNamesUntil()
    }

    private static func readEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "debugLog")
    }

    /// The old `debugLogKeys` boolean is deliberately not migrated. It had no expiry, so
    /// anyone who set it once is still exposed by it; letting it lapse into redaction is
    /// the safe direction to fail.
    private static func readKeyNamesUntil() -> TimeInterval {
        UserDefaults.standard.double(forKey: "debugLogKeyNamesUntil")
    }

    /// A button's name for the log, with key identity withheld unless granted.
    ///
    /// Redacted rather than dropped: which key it was is the private part, but *that* a
    /// key was pressed and what the engine decided to do with it is the whole reason to
    /// read this file, and losing those lines would leave a gap exactly where a bound
    /// key misbehaves.
    public static func label(for button: Int) -> String {
        guard MouseButton.isKey(button) else { return MouseButton.label(button) }
        return recordsKeyNames ? MouseButton.label(button) : "⌨ key"
    }

    private static let queue = DispatchQueue(label: "com.machancer.debuglog", qos: .utility)

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func write(_ message: @autoclosure @escaping () -> String) {
        guard isEnabled else { return }
        queue.async {
            let line = "\(formatter.string(from: Date()))  \(message())\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    // Diagnostics must never take the app down; a failed write is a
                    // missing line, nothing more.
                }

            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
