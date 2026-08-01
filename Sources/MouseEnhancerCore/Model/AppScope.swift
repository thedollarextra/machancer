import AppKit
import CoreGraphics
import Foundation

/// Where a rule applies: everywhere, only in a listed set of apps, or everywhere
/// except a listed set.
///
/// One type used at two levels — per binding and app-wide — so "only in Photoshop"
/// and "never in Remote Desktop" are the same idea expressed once, and the global
/// setting is just a scope that gates every binding.
public struct AppScope: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Applies in every app.
        case everywhere
        /// Whitelist: applies only while one of `bundleIDs` is frontmost.
        case onlyIn
        /// Blacklist: applies everywhere except while one of `bundleIDs` is frontmost.
        case exceptIn

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .everywhere: return "All Applications"
            case .onlyIn:     return "Only In…"
            case .exceptIn:   return "Except In…"
            }
        }

        public var symbol: String {
            switch self {
            case .everywhere: return "globe"
            case .onlyIn:     return "scope"
            case .exceptIn:   return "nosign"
            }
        }
    }

    public var mode: Mode
    /// Bundle identifiers the mode refers to. Ignored when `mode == .everywhere`.
    public var bundleIDs: [String]

    public init(mode: Mode = .everywhere, bundleIDs: [String] = []) {
        self.mode = mode
        self.bundleIDs = bundleIDs
    }

    public static let everywhere = AppScope()

    /// Does this scope admit `bundleID`?
    ///
    /// A whitelist with nothing listed matches nothing — that is the honest reading of
    /// "only in these apps: none", and the UI flags it rather than silently treating it
    /// as "everywhere". An empty blacklist excludes nothing, which needs no warning.
    public func allows(_ bundleID: String?) -> Bool {
        switch mode {
        case .everywhere:
            return true
        case .onlyIn:
            guard let bundleID else { return false }
            return bundleIDs.contains(bundleID)
        case .exceptIn:
            guard let bundleID else { return true }
            return !bundleIDs.contains(bundleID)
        }
    }

    /// True when the scope can never match, so the UI can say so.
    public var isUnsatisfiable: Bool { mode == .onlyIn && bundleIDs.isEmpty }

    /// Short label for a row, e.g. "Only: Safari +2".
    public func summary(nameFor: (String) -> String) -> String {
        switch mode {
        case .everywhere:
            return "All Apps"
        case .onlyIn, .exceptIn:
            let prefix = mode == .onlyIn ? "Only" : "Except"
            guard let first = bundleIDs.first else { return "\(prefix): none" }
            let extra = bundleIDs.count - 1
            return extra > 0 ? "\(prefix): \(nameFor(first)) +\(extra)" : "\(prefix): \(nameFor(first))"
        }
    }
}

/// Resolves bundle identifiers to display names, and lists candidate apps to pick from.
public enum AppCatalog {
    public static func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        // Not installed or not resolvable right now: show the identifier rather than
        // pretending we know nothing about it.
        return bundleID
    }

    /// Running apps with a UI, de-duplicated and sorted — almost always the app being
    /// targeted. Anything else is reachable through the open panel.
    public static var runningApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                      seen.insert(id).inserted else { return nil }
                return (id, name)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}
