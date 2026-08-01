import AppKit
import CoreGraphics
import Foundation

/// The four modifier keys a binding can require, as a codable option set.
///
/// Deliberately narrower than `CGEventFlags`: mouse events always carry incidental
/// bits (`maskNonCoalesced`, device flags, caps lock) that must never participate in
/// binding comparison.
public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option  = ModifierSet(rawValue: 1 << 1)
    public static let command = ModifierSet(rawValue: 1 << 2)
    public static let shift   = ModifierSet(rawValue: 1 << 3)

    public static let all: [ModifierSet] = [.control, .option, .shift, .command]

    /// Extracts only the four meaningful modifiers from a raw event's flags.
    public init(cgFlags: CGEventFlags) {
        var set = ModifierSet()
        if cgFlags.contains(.maskControl)   { set.insert(.control) }
        if cgFlags.contains(.maskAlternate) { set.insert(.option) }
        if cgFlags.contains(.maskCommand)   { set.insert(.command) }
        if cgFlags.contains(.maskShift)     { set.insert(.shift) }
        self = set
    }

    /// Same four modifiers, from an `NSEvent`. AppKit reports them in its own option
    /// set, and `NSEvent.modifierFlags` carries the same incidental bits (caps lock,
    /// numeric pad, function) that must stay out of binding comparison.
    public init(nsFlags: NSEvent.ModifierFlags) {
        var set = ModifierSet()
        if nsFlags.contains(.control) { set.insert(.control) }
        if nsFlags.contains(.option)  { set.insert(.option) }
        if nsFlags.contains(.command) { set.insert(.command) }
        if nsFlags.contains(.shift)   { set.insert(.shift) }
        self = set
    }

    public var cgFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option)  { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift)   { flags.insert(.maskShift) }
        return flags
    }

    public var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option:  return "⌥"
        case .shift:   return "⇧"
        case .command: return "⌘"
        default: return ""
        }
    }

    public var name: String {
        switch self {
        case .control: return "Control"
        case .option:  return "Option"
        case .shift:   return "Shift"
        case .command: return "Command"
        default: return ""
        }
    }

    /// "⌃⌥⌘" in the canonical macOS order, or "—" when no modifiers are required.
    public var symbols: String {
        let joined = Self.all.filter { contains($0) }.map(\.symbol).joined()
        return joined.isEmpty ? "—" : joined
    }
}
