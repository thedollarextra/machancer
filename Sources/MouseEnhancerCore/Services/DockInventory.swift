import AppKit
import ApplicationServices

/// Reads the Dock's app tiles: title, bundle identifier, icon, and frame.
///
/// The Dock exposes its tiles through Accessibility but not their bundle identifiers, so
/// each title has to be resolved back to an application. That resolution is the expensive
/// part and the reason results are cached: enumerating costs an AX round trip per tile
/// per attribute, roughly eighty on an ordinary Dock, and the settings list would
/// otherwise redo all of it on every SwiftUI redraw.
public enum DockInventory {

    public struct Item: Identifiable, Equatable {
        public let title: String
        public let bundleID: String
        public let url: URL
        /// Loaded once when the Dock is enumerated, not on demand.
        ///
        /// This was a computed property, which meant `NSWorkspace.icon(forFile:)`
        /// allocated a fresh `NSImage` on every SwiftUI redraw of every row — forty
        /// apps' worth of icon decoding for something that changes only when the Dock
        /// does. Storing it costs one image per app and nothing per frame.
        public let icon: NSImage

        public var id: String { bundleID }

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.bundleID == rhs.bundleID && lhs.title == rhs.title
        }
    }

    /// Every app tile currently in the Dock, in Dock order.
    ///
    /// Running apps resolve directly through their process; the rest go through a
    /// filesystem lookup by name. Tiles that resolve to nothing — Trash, folder stacks,
    /// minimised-window tiles — are dropped, since there is no app to send a command to.
    public static func items() -> [Item] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var found: [Item] = []
        var seen = Set<String>()

        for list in AX.children(dockElement) {
            for tile in AX.children(list) {
                guard AX.role(tile) == "AXDockItem",
                      let title = AX.string(tile, kAXTitleAttribute as String),
                      !title.isEmpty,
                      let url = applicationURL(named: title),
                      let bundleID = Bundle(url: url)?.bundleIdentifier,
                      seen.insert(bundleID).inserted
                else { continue }
                found.append(Item(title: title, bundleID: bundleID, url: url,
                                  icon: NSWorkspace.shared.icon(forFile: url.path)))
            }
        }
        return found
    }

    /// Resolves a Dock tile title to a bundle URL.
    ///
    /// Running applications are authoritative — the tile title is the localized app name,
    /// which is exactly what `localizedName` reports. Anything not running falls back to
    /// a scan of the usual install locations.
    public static func applicationURL(named name: String) -> URL? {
        let needle = name.lowercased()

        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == needle
        }), let url = running.bundleURL {
            return url
        }

        let searchPaths = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for path in searchPaths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
