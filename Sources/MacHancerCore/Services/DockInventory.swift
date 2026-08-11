import AppKit
import ApplicationServices
import UniformTypeIdentifiers

/// Reads the Dock's tiles — applications, pinned folders, pinned files and links, and
/// Trash — as title, kind, stable key, target URL, and icon.
///
/// Everything comes from the tile's own Accessibility attributes, so the list always
/// matches what is actually in the Dock rather than a hand-maintained guess. The subrole
/// says what a tile *is* (`AXApplicationDockItem`, `AXFolderDockItem`, `AXTrashDockItem`,
/// …) and `AXURL` says what it points at; only Trash publishes neither a URL nor anything
/// else to identify it by, and there is exactly one of it.
///
/// Enumerating costs an AX round trip per tile per attribute, roughly a hundred on an
/// ordinary Dock, which is the reason `items()` results are held by the caller rather
/// than recomputed: the settings list would otherwise redo all of it on every SwiftUI
/// redraw.
public enum DockInventory {

    /// A Dock tile's identity, without the icon. This is what the middle-click path
    /// needs; loading an icon there would be work no one ever looks at.
    public struct Target: Equatable, Sendable {
        public let title: String
        public let kind: DockItemKind
        /// The settings key: a bundle identifier for applications, a path or link URL for
        /// everything else. Stable across the tile being moved, renamed, or removed and
        /// put back.
        public let key: String
        /// What the tile points at. `nil` only when an application's bundle could not be
        /// located, in which case there is nothing to act on either.
        public let url: URL?

        public init(title: String, kind: DockItemKind, key: String, url: URL?) {
            self.title = title
            self.kind = kind
            self.key = key
            self.url = url
        }
    }

    public struct Item: Identifiable, Equatable {
        public let target: Target
        /// Loaded once when the Dock is enumerated, not on demand.
        ///
        /// This was a computed property, which meant `NSWorkspace.icon(forFile:)`
        /// allocated a fresh `NSImage` on every SwiftUI redraw of every row — forty
        /// items' worth of icon decoding for something that changes only when the Dock
        /// does. Storing it costs one image per item and nothing per frame.
        public let icon: NSImage

        public var id: String { target.key }
        public var title: String { target.title }
        public var kind: DockItemKind { target.kind }
        public var key: String { target.key }
        public var url: URL? { target.url }

        public static func == (lhs: Item, rhs: Item) -> Bool { lhs.target == rhs.target }
    }

    /// The one key that isn't derived from a URL. Trash reports no `AXURL`, and its
    /// actual location (`~/.Trash`) is not something a settings file should be keyed on —
    /// the same Dock on another account would miss.
    public static let trashKey = "com.apple.dock.trash"

    /// Every tile currently in the Dock, in Dock order.
    ///
    /// Separators and minimised-window tiles are dropped: one is not a target and the
    /// other is transient, so a setting stored against it would be orphaned the moment
    /// the window is restored.
    public static func items() -> [Item] {
        var found: [Item] = []
        var seen = Set<String>()

        for tile in tiles() {
            guard let target = target(from: tile), seen.insert(target.key).inserted else {
                continue
            }
            found.append(Item(target: target, icon: icon(for: target)))
        }
        return found
    }

    /// The tile under `location`, or `nil` if the point isn't on one.
    ///
    /// The obvious approach — `AXUIElementCopyElementAtPosition` — does not work here:
    /// the Dock returns `kAXErrorNotImplemented` (-25208) for positional hit-tests, on
    /// its tiles and on the strip as a whole. Verified on macOS 26.3. So the tiles are
    /// enumerated and the point matched against their reported frames instead, stopping
    /// at the first hit so a click near the left of the Dock doesn't pay for the rest.
    public static func target(at location: CGPoint) -> Target? {
        for tile in tiles() {
            guard let frame = AX.frame(tile), frame.contains(location) else { continue }
            return target(from: tile)
        }
        return nil
    }

    // MARK: - Tiles

    /// Every `AXDockItem` in the Dock, flattened across its lists.
    ///
    /// The Dock puts applications and the pinned section in separate `AXList`s on some
    /// configurations and one on others, so both are walked rather than assuming a shape.
    static func tiles() -> [AXUIElement] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [] }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var found: [AXUIElement] = []
        for list in AX.children(dockElement) {
            for tile in AX.children(list) where AX.role(tile) == "AXDockItem" {
                found.append(tile)
            }
        }
        return found
    }

    /// Resolves one tile to a target, or `nil` if it isn't something to act on.
    static func target(from tile: AXUIElement) -> Target? {
        let title = AX.string(tile, kAXTitleAttribute as String) ?? ""
        let url = AX.url(tile, kAXURLAttribute as String)

        switch AX.string(tile, kAXSubroleAttribute as String) {
        case "AXApplicationDockItem":
            // `AXURL` is authoritative and is what the Dock itself launches. The name
            // lookup below it is the old path, kept for a tile that publishes no URL;
            // it can only find apps in the usual install locations, which is why a
            // nested bundle like /Applications/Vendor/Thing.app used to go missing.
            guard let bundle = url ?? applicationURL(named: title),
                  let bundleID = Bundle(url: bundle)?.bundleIdentifier
            else { return nil }
            return Target(title: title.isEmpty ? bundle.deletingPathExtension().lastPathComponent : title,
                          kind: .application, key: bundleID, url: bundle)

        case "AXFolderDockItem":
            guard let url else { return nil }
            return Target(title: displayTitle(title, url), kind: .folder,
                          key: url.standardizedFileURL.path, url: url)

        case "AXDocumentDockItem":
            guard let url else { return nil }
            return Target(title: displayTitle(title, url), kind: .file,
                          key: url.standardizedFileURL.path, url: url)

        case "AXURLDockItem":
            guard let url else { return nil }
            return Target(title: title.isEmpty ? url.absoluteString : title,
                          kind: .webURL, key: url.absoluteString, url: url)

        case "AXTrashDockItem":
            return Target(title: title.isEmpty ? "Trash" : title, kind: .trash,
                          key: trashKey, url: trashURL)

        // Separators, minimised windows, and whatever Apple adds next.
        default:
            return nil
        }
    }

    private static func displayTitle(_ title: String, _ url: URL) -> String {
        title.isEmpty ? url.lastPathComponent : title
    }

    /// Where Trash actually lives for this user. `.trashDirectory` is the supported
    /// lookup; the literal path is the fallback for the case where it fails.
    public static var trashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
    }

    private static func icon(for target: Target) -> NSImage {
        // Trash's directory carries no icon of its own — the one people recognise is a
        // system image, and it is the only tile whose icon isn't just its file's.
        if target.kind == .trash {
            return NSImage(named: NSImage.trashFullName)
                ?? NSWorkspace.shared.icon(forFile: trashURL.path)
        }
        if let url = target.url, url.isFileURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .url)
    }

    /// Resolves a Dock tile title to a bundle URL.
    ///
    /// Running applications are authoritative — the tile title is the localized app name,
    /// which is exactly what `localizedName` reports. Anything not running falls back to
    /// a scan of the usual install locations.
    public static func applicationURL(named name: String) -> URL? {
        guard !name.isEmpty else { return nil }
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
