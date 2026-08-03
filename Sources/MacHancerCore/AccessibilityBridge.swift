import AppKit
import ApplicationServices

/// Thin, crash-free helpers over the AXUIElement C API.
///
/// Every `AXUIElementCopyAttributeValue` result comes back as `CFTypeRef?`; the
/// force-casts that read naturally (`parent as! AXUIElement`) will trap whenever an
/// attribute exists but holds a different type. Everything here checks the CFTypeID
/// first and returns `nil` rather than taking the process down.
public enum AX {
    public static let systemWide = AXUIElementCreateSystemWide()

    /// Hit-test in AX coordinate space (origin top-left, same as `CGEvent.location`).
    public static func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &element
        )
        return result == .success ? element : nil
    }

    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    public static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    /// `nil` when the attribute is absent, which is meaningfully different from `false`
    /// — a menu item that reports no enabled state is not a disabled menu item.
    public static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    /// Safe downcast of an attribute value to an AXUIElement.
    public static func child(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    /// Screen frame of an element, in AX space (origin top-left).
    public static func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let posValue = attribute(element, kAXPositionAttribute as String),
            let sizeValue = attribute(element, kAXSizeAttribute as String),
            CFGetTypeID(posValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    public static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute as String)
    }

    @discardableResult
    public static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    public static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// Walks up the parent chain looking for the enclosing window.
    /// Bounded so a cyclic or pathologically deep hierarchy cannot hang the event tap.
    public static func enclosingWindow(of element: AXUIElement, maxDepth: Int = 24) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < maxDepth {
            if role(node) == kAXWindowRole { return node }
            current = child(node, kAXParentAttribute as String)
            depth += 1
        }
        return nil
    }

    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
