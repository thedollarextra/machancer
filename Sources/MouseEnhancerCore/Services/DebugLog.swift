import Foundation

/// Appends diagnostic lines to a file.
///
/// `NSLog` from this bundled agent does not reach the unified log on this system —
/// `log show --predicate 'process == "MouseEnhancer"'` returns nothing even while the
/// app is demonstrably running and executing the logging call. Rather than keep
/// diagnosing through a channel that silently drops everything, write somewhere whose
/// success can be confirmed by looking at it.
///
/// Cheap and off by default: enable with
///     defaults write com.mouseenhancer.MouseEnhancer debugLog -bool YES
public enum DebugLog {
    public static let path = NSHomeDirectory() + "/Library/Logs/MouseEnhancer.log"

    /// Read once. Flipping this at runtime is not worth a lock on a diagnostic path.
    private static let isEnabled: Bool =
        UserDefaults.standard.bool(forKey: "debugLog")

    private static let queue = DispatchQueue(label: "com.mouseenhancer.debuglog", qos: .utility)

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
