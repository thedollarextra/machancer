import AppKit
import ApplicationServices

/// Runtime self-check.
///
/// The Accessibility behaviour this app depends on cannot be verified from outside a
/// trusted, bundled process — an unbundled test binary borrows the terminal's TCC
/// identity and gets inconsistent answers. So the app checks itself, from the same
/// context it actually runs in.
public enum Diagnostics {

    public struct Result: Identifiable {
        public let id = UUID()
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public static func run() -> [Result] {
        var results: [Result] = []

        results.append(Result(
            name: "Accessibility trust",
            passed: AX.isTrusted,
            detail: AX.isTrusted
                ? "granted"
                : "not granted — bindings are inert. If the checkbox in System Settings "
                + "is already ticked, the entry is stale: remove Mouse Enhancer from the "
                + "list with “−” and add it again."
        ))

        // The check that matters most, and the one that used to be missing: trust can
        // read as granted while no tap is actually attached. Without a tap in this
        // list, nothing the app does can ever fire.
        results.append(ownTap())

        // Why a grant that was made can stop applying without anyone touching it.
        results.append(Result(
            name: "Code signature",
            passed: !CodeSignature.isAdHoc,
            detail: CodeSignature.summary
        ))

        // Positional hit-testing: strategy 1 of the close-window path.
        let centre = NSScreen.main.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
        let hit = AX.element(at: centre)
        results.append(Result(
            name: "Positional hit-test",
            passed: hit != nil,
            detail: hit != nil
                ? "available (role: \(hit.flatMap(AX.role) ?? "unknown"))"
                : "unavailable — close-window falls back to the window-list strategy"
        ))

        // Strategy 2: window server lookup + AX window match.
        let dispatcher = ActionDispatcher.shared
        if let (pid, bounds) = dispatcher.frontmostWindow(containing: centre) {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            let appElement = AXUIElementCreateApplication(pid)
            let windows = AX.attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
            let geometryReadable = windows.contains { AX.frame($0) != nil }
            results.append(Result(
                name: "Window-list fallback",
                passed: !windows.isEmpty,
                detail: "\(name): \(windows.count) AX window(s), geometry readable: \(geometryReadable), "
                      + "bounds \(Int(bounds.width))×\(Int(bounds.height))"
            ))
        } else {
            results.append(Result(
                name: "Window-list fallback",
                passed: false,
                detail: "no window under the centre of the main screen — move a window there and retry"
            ))
        }

        // Dock tile resolution.
        let dockRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").isEmpty
        var tileCount = 0
        var sample: String?
        if dockRunning {
            let dockElement = AXUIElementCreateApplication(
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")[0]
                    .processIdentifier
            )
            for list in AX.children(dockElement) {
                for tile in AX.children(list) where AX.role(tile) == "AXDockItem" {
                    tileCount += 1
                    if sample == nil { sample = AX.string(tile, kAXTitleAttribute as String) }
                }
            }
        }
        results.append(Result(
            name: "Dock tiles",
            passed: tileCount > 0,
            detail: tileCount > 0
                ? "\(tileCount) tiles readable (first: \(sample ?? "?"))"
                : "no Dock tiles readable — middle-click launching will not work"
        ))

        // Competing taps: a tap ahead of ours can eat the same buttons.
        results.append(competingTaps())

        return results
    }

    /// Is *our* tap actually in the system's tap list, and enabled?
    ///
    /// This is the ground truth for "why is nothing happening". `AXIsProcessTrusted()`
    /// answering yes is not sufficient — `CGEvent.tapCreate` can still have failed, or
    /// the tap can have been disabled afterwards — and in that state every binding
    /// silently does nothing while the UI looks healthy.
    public static func ownTapStatus() -> (attached: Bool, enabled: Bool) {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for tap in tapList() where pid_t(tap.tappingProcess) == ourPID {
            return (true, tap.enabled)
        }
        return (false, false)
    }

    /// Other enabled taps watching the same extra mouse buttons, by app name.
    /// One of these sitting ahead of ours can consume a button before we see it.
    public static func competingTapNames() -> [String] {
        let otherMouseMask: UInt64 =
            (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)

        let ourPID = ProcessInfo.processInfo.processIdentifier
        var names: Set<String> = []
        for tap in tapList()
        where tap.enabled && pid_t(tap.tappingProcess) != ourPID
            && (tap.eventsOfInterest & otherMouseMask) != 0 {
            let name = NSRunningApplication(processIdentifier: pid_t(tap.tappingProcess))?
                .localizedName ?? "pid \(tap.tappingProcess)"
            names.insert(name)
        }
        return names.sorted()
    }

    /// `CGGetEventTapList` is a two-call API: ask for the count, then fill a buffer.
    private static func tapList() -> [CGEventTapInformation] {
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        guard count > 0 else { return [] }

        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &taps, &count)
        return Array(taps.prefix(Int(count)))
    }

    private static func ownTap() -> Result {
        let status = ownTapStatus()
        guard status.attached else {
            return Result(
                name: "Event tap installed",
                passed: false,
                detail: "no tap attached — every binding is inert. Grant Accessibility access, "
                      + "or remove and re-add the app if it is already ticked."
            )
        }
        return Result(
            name: "Event tap installed",
            passed: status.enabled,
            detail: status.enabled
                ? "attached and enabled"
                : "attached but disabled by the system — it will be re-armed automatically"
        )
    }

    private static func competingTaps() -> Result {
        let names = competingTapNames()
        return Result(
            name: "Competing event taps",
            passed: names.isEmpty,
            detail: names.isEmpty
                ? "none — this app has the extra mouse buttons to itself"
                : "also tapping these buttons: \(names.joined(separator: ", "))"
        )
    }
}
