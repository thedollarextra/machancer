import CoreGraphics
import Foundation

/// A recorded keyboard shortcut, used by the `.customKeystroke` action.
public struct Keystroke: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// e.g. "⌘⇧4" or "⌃F2"
    public var display: String {
        let mods = ModifierSet.all.filter { modifiers.contains($0) }.map(\.symbol).joined()
        return mods + KeyNames.name(for: keyCode)
    }
}

/// Virtual key code → printable name. Covers the keys people actually bind;
/// anything else falls back to the raw code rather than pretending to know.
public enum KeyNames {
    private static let table: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
        0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",

        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
        0x47: "Clear", 0x4C: "⌤", 0x75: "⌦", 0x72: "Help",
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",

        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",

        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
    ]

    public static func name(for keyCode: UInt16) -> String {
        table[keyCode] ?? "Key \(keyCode)"
    }
}
