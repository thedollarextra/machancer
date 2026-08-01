import Combine
import Foundation

/// Rolling log of what the tap saw and what it decided.
///
/// Recording is opt-in and off by default: this is fed from the event-tap callback,
/// so when nobody is watching it must cost a single boolean check. Publishing is
/// coalesced — a fast drag produces events far quicker than SwiftUI should redraw.
public final class EventLog: ObservableObject {
    public static let shared = EventLog()

    public struct Entry: Identifiable, Sendable {
        public let id: UInt64
        public let timestamp: Date
        public let button: Int
        public let phase: String
        public let modifiers: ModifierSet
        public let outcome: String
        public let suppressed: Bool

        public var summary: String {
            let mods = modifiers.isEmpty ? "" : modifiers.symbols + " "
            return "\(mods)\(MouseButton.label(button)) \(phase) → \(outcome)"
        }
    }

    /// Bounded so a long recording session can't grow without limit.
    public static let capacity = 250

    @Published public private(set) var entries: [Entry] = []

    /// Checked on every event; keep it a plain stored property.
    public private(set) var isRecording = false

    private var buffer: [Entry] = []
    private var nextID: UInt64 = 0
    private var flushScheduled = false

    public init() {}

    public func startRecording() {
        guard !isRecording else { return }
        isRecording = true
    }

    public func stopRecording() {
        isRecording = false
        flush()
    }

    public func clear() {
        buffer.removeAll(keepingCapacity: true)
        entries = []
    }

    /// Called from the tap callback. Must stay allocation-light and never block.
    public func record(
        button: Int,
        phase: String,
        modifiers: ModifierSet,
        outcome: String,
        suppressed: Bool
    ) {
        guard isRecording else { return }

        nextID &+= 1
        let entry = Entry(
            id: nextID,
            timestamp: Date(),
            button: button,
            phase: phase,
            modifiers: modifiers,
            outcome: outcome,
            suppressed: suppressed
        )

        buffer.append(entry)
        if buffer.count > Self.capacity {
            buffer.removeFirst(buffer.count - Self.capacity)
        }
        scheduleFlush()
    }

    /// Publish at most ~12×/second; a drag can emit events far faster than that.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        guard entries.count != buffer.count || entries.last?.id != buffer.last?.id else { return }
        entries = buffer.reversed()   // newest first for display
    }
}
