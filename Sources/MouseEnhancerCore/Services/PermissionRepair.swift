import AppKit
import Combine
import Foundation

/// Detects and repairs the "ticked but denied" Accessibility state.
///
/// The failure it exists for: TCC stores a code requirement next to the authorisation
/// value. Toggling the switch in System Settings rewrites the value and leaves the
/// requirement alone, so once a rebuilt binary stops matching, the switch is stuck in a
/// state where it reads as granted and denies every request. The only fix is to delete
/// the record so the next grant is recorded against the current binary — which is what
/// `tccutil reset` does, and what no amount of clicking in System Settings will.
public final class PermissionRepair: ObservableObject {
    public static let shared = PermissionRepair()

    public enum State: Equatable {
        case granted
        /// Never successfully trusted on this machine, as far as we've seen.
        case notGranted
        /// We *were* trusted, under a build with a different signature. This is the
        /// case where the checkbox lies.
        case staleGrant(previousBuild: String)
        /// A repair was attempted and access is still missing. `tccutil` exits 0
        /// whether or not it removed anything, so this is the only way to find out.
        case repairDidNotTake
    }

    @Published public private(set) var state: State = .notGranted

    private let defaults: UserDefaults
    private static let lastTrustedKey = "lastTrustedCDHash"
    private static let repairAttemptedKey = "accessibilityRepairAttemptedAt"

    /// How long after a repair we keep treating "still no access" as that repair
    /// having failed, rather than as a fresh problem.
    private static let repairGrace: TimeInterval = 15 * 60

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    // MARK: - State

    /// Cheap enough to call from the settings poll; no subprocesses, no TCC lookups.
    public func refresh() {
        let new: State
        if AX.isTrusted {
            defaults.removeObject(forKey: Self.repairAttemptedKey)
            noteTrusted()
            new = .granted
        } else if recentlyAttemptedRepair {
            new = .repairDidNotTake
        } else if let previous = defaults.string(forKey: Self.lastTrustedKey),
                  previous != CodeSignature.cdHash {
            new = .staleGrant(previousBuild: CodeSignature.shortHash(previous))
        } else {
            new = .notGranted
        }
        if new != state { state = new }
    }

    private var recentlyAttemptedRepair: Bool {
        let attempted = defaults.double(forKey: Self.repairAttemptedKey)
        guard attempted > 0 else { return false }
        return Date().timeIntervalSince1970 - attempted < Self.repairGrace
    }

    /// Records the signature that access was actually granted to. Called the moment the
    /// tap attaches, because that is the only unambiguous proof we were trusted — an
    /// entry in System Settings is not.
    public func noteTrusted() {
        guard let hash = CodeSignature.cdHash else { return }
        guard defaults.string(forKey: Self.lastTrustedKey) != hash else { return }
        defaults.set(hash, forKey: Self.lastTrustedKey)
    }

    /// What to tell the user, given the state and how the app is signed.
    public var explanation: String? {
        switch state {
        case .granted:
            return CodeSignature.isAdHoc
                ? "This build is ad-hoc signed, so the grant is tied to this exact binary. "
                + "Rebuilding the app will silently invalidate it — the checkbox stays "
                + "ticked while nothing works. Sign with a stable certificate to stop that: "
                + "./build.sh --create-identity"
                : nil

        case .notGranted:
            return "Grant Accessibility access to enable bindings. If Mouse Enhancer is "
                 + "already listed and ticked, the entry is stale and repairing it is the "
                 + "only thing that will help — see below."

        case .staleGrant(let previousBuild):
            return "Access was granted to a previous build (cdhash \(previousBuild)); this "
                 + "one is \(CodeSignature.shortHash(CodeSignature.cdHash)). macOS matches "
                 + "the grant against the exact binary, so it no longer applies — and the "
                 + "checkbox in System Settings stays ticked regardless. Un-ticking and "
                 + "re-ticking it will not help; the stale record has to be deleted."

        case .repairDidNotTake:
            return "The automatic repair did not remove the stale record. Accessibility "
                 + "grants are stored system-wide, so tccutil cannot delete one without "
                 + "administrator rights — and it reports success either way.\n\n"
                 + "Remove it by hand instead: in System Settings → Privacy & Security → "
                 + "Accessibility, select Mouse Enhancer and press “−”, then add it again "
                 + "with “+” and switch it on. The “−” is what actually deletes the record; "
                 + "the toggle never does. Equivalently, in Terminal:\n\n"
                 + "sudo tccutil reset Accessibility \(Bundle.main.bundleIdentifier ?? "")"
        }
    }

    /// Shown whenever access is missing: the reset is harmless when there is no record
    /// to delete, and there is no way to ask TCC whether one exists. Withdrawn once a
    /// repair has demonstrably failed — offering the same ineffective button again is
    /// how a user ends up clicking it ten times.
    public var canRepair: Bool {
        switch state {
        case .granted, .repairDidNotTake: return false
        case .notGranted, .staleGrant: return true
        }
    }

    // MARK: - Repair

    /// Deletes this app's Accessibility record and restarts so the grant can be made
    /// against the current binary. Calls back only on failure — on success the app is
    /// already on its way out.
    public func repair(completion: @escaping (String?) -> Void) {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            completion("No bundle identifier — cannot reset the record.")
            return
        }

        // Off the main thread: tccutil talks to tccd, and a slow daemon should not
        // freeze the settings window.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = Self.resetAccessibility(bundleID: bundleID)

            DispatchQueue.main.async {
                guard let self else { return }
                guard failure == nil else {
                    completion(failure)
                    return
                }
                self.defaults.removeObject(forKey: Self.lastTrustedKey)
                // Recorded before the restart, and checked after it: tccutil's exit
                // status says nothing about whether a record was actually removed, so
                // surviving the restart without access is the only real evidence.
                self.defaults.set(Date().timeIntervalSince1970, forKey: Self.repairAttemptedKey)
                self.relaunch()
            }
        }
    }

    private static func resetAccessibility(bundleID: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundleID]

        let errors = Pipe()
        task.standardError = errors
        task.standardOutput = Pipe()

        do {
            try task.run()
        } catch {
            return "Could not run tccutil: \(error.localizedDescription)"
        }

        // Read before waiting: a full pipe buffer would deadlock the child.
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus != 0 else { return nil }

        let detail = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty
            ? "tccutil exited with status \(task.terminationStatus)."
            : "tccutil failed: \(detail)"
    }

    /// A fresh process is the point of the restart: this one has already been refused,
    /// and macOS will not re-prompt a process it has already answered.
    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        // Single-quoted for the shell — this app's own path routinely contains spaces
        // (iCloud Drive) and would otherwise be split into arguments.
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \(quoted)",
        ]
        try? helper.run()

        NSApp.terminate(nil)
    }
}
