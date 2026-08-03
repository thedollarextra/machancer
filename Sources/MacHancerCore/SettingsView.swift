import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var prefs = UserPreferences.shared

    /// Trust state isn't observable, so poll it — otherwise the banner stays stale
    /// while the window is open and the user grants access in System Settings.
    @State private var isTrusted = AX.isTrusted
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var showRepairConfirmation = false
    @State private var showResetConfirmation = false
    @State private var repairError: String?
    @ObservedObject private var repair = PermissionRepair.shared
    private let trustPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// Divides the poll down for the expensive half of it — see `onReceive` below.
    @State private var slowTick = 0

    public init() {}

    public var body: some View {
        TabView {
            GeneralTab(
                prefs: prefs,
                isTrusted: isTrusted,
                launchAtLogin: launchAtLoginBinding,
                loginItemError: loginItemError,
                showReset: $showResetConfirmation,
                accessibility: { AnyView(accessibilitySection) }
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            bindingsTab
                .tabItem { Label("Bindings", systemImage: "computermouse") }

            GesturesTab(prefs: prefs)
                .tabItem { Label("Gestures", systemImage: "hand.draw") }

            ScrollingTab(prefs: prefs)
                .tabItem { Label("Scrolling", systemImage: "arrow.up.and.down") }

            DockTab(prefs: prefs)
                .tabItem { Label("Dock", systemImage: "dock.rectangle") }

            ExclusionsTab(prefs: prefs)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }

        }
        // A floor, not a size. The window resizes, and the Bindings list is what wants
        // the room — but below roughly this width macOS collapses the tab overflow into
        // a "»" menu, which buries entire sections behind two clicks. The tab bar exists
        // precisely so that doesn't happen, so it sets the minimum.
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .onReceive(trustPoll) { _ in
            // Cheap, and the one thing the user is actively waiting on: they are in
            // System Settings ticking the box and want this banner to notice.
            let current = AX.isTrusted
            if current != isTrusted { isTrusted = current }

            // The other two are not cheap. `LoginItem.isEnabled` is a synchronous XPC
            // round trip to `smd`, and `repair.refresh` reads the code signature —
            // sampling the process showed those two were essentially its entire CPU
            // cost while this window was open, once a second, forever. Neither can
            // change without the user leaving to visit System Settings, so a five-
            // second cadence still catches it well within the time it takes to walk
            // back to this window.
            slowTick &+= 1
            guard slowTick % 5 == 0 else { return }
            let login = LoginItem.isEnabled
            if login != launchAtLogin { launchAtLogin = login }
            repair.refresh()
        }
        .alert("Reset all settings?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) { prefs.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every binding and calibration value returns to its factory default. "
                 + "Your Accessibility permission is not affected.")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { desired in
                loginItemError = LoginItem.setEnabled(desired)
                launchAtLogin = LoginItem.isEnabled
            }
        )
    }

    // MARK: - Bindings

    private var bindingsTab: some View {
        VStack(spacing: 0) {
            if prefs.bindings.isEmpty {
                ContentUnavailableView(
                    "No Bindings",
                    systemImage: "computermouse",
                    description: Text("Add a binding to map a mouse button or key to an action.")
                )
            } else {
                // A `List` rather than a `LazyVStack`, because `onMove` is what provides
                // drag-to-reorder and only `List` offers it. Order is meaningful: the
                // first matching rule wins among equally-scoped bindings, so being able
                // to rearrange them decides which one that is.
                let shadowed = prefs.shadowedBindingIDs
                List {
                    ForEach(bindingIndices, id: \.self) { index in
                        BindingRow(
                            binding: bindingAt(index),
                            prefs: prefs,
                            isShadowed: shadowed.contains(prefs.bindings[index].id),
                            onDelete: { deleteBinding(at: index) }
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 10))
                    }
                    .onMove { source, destination in
                        var all = prefs.bindings
                        all.move(fromOffsets: source, toOffset: destination)
                        prefs.bindings = all
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            Divider()

            HStack {
                Button {
                    prefs.bindings.append(
                        ActionBinding(button: MouseButton.button4, action: ActionSpec(kind: .none))
                    )
                } label: {
                    Label("Add Binding", systemImage: "plus")
                }

                Spacer()

                Text("Earlier bindings win when two rules match. Drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private var bindingIndices: [Int] { Array(prefs.bindings.indices) }

    /// Writes go through `prefs.bindings` wholesale so the change is persisted and
    /// the lookup index is invalidated.
    private func bindingAt(_ index: Int) -> Binding<ActionBinding> {
        Binding(
            get: {
                index < prefs.bindings.count
                    ? prefs.bindings[index]
                    : ActionBinding(button: MouseButton.button4, action: .none)
            },
            set: { updated in
                guard index < prefs.bindings.count else { return }
                var all = prefs.bindings
                all[index] = updated
                prefs.bindings = all
            }
        )
    }

    private func deleteBinding(at index: Int) {
        guard index < prefs.bindings.count else { return }
        var all = prefs.bindings
        all.remove(at: index)
        prefs.bindings = all
    }

    // MARK: - Accessibility
    //
    // Lives on General only. It used to be repeated at the foot of the Calibration tab
    // as well, which made the window look like it had lost track of its own state.

    private var accessibilitySection: some View {
        Section("Accessibility") {
            HStack {
                Image(systemName: isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isTrusted ? .green : .orange)
                Text(isTrusted
                     ? "Access granted — bindings are live."
                     : "Access is not in effect — bindings are inert.")
                Spacer()
                if !isTrusted {
                    Button("Open Settings…") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .font(.callout)

            if let explanation = repair.explanation {
                // Selectable: this branch ends in a command the user has to run, and an
                // unselectable one may as well not be there.
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(repair.state == .repairDidNotTake ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if repair.canRepair {
                HStack(alignment: .firstTextBaseline) {
                    Button("Repair Permission…") { showRepairConfirmation = true }
                    SettingNote("Deletes the stale record and restarts, so the grant is "
                                + "made against this build.")
                }
            }

            if let repairError {
                Label(repairError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Reset Accessibility access for MacHancer?", isPresented: $showRepairConfirmation) {
            Button("Reset and Restart") {
                repairError = nil
                repair.repair { repairError = $0 }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MacHancer will be removed from the Accessibility list and will quit "
                 + "and reopen. Approve the prompt that follows, and the grant will be "
                 + "recorded against this build.\n\nThis affects only MacHancer's own "
                 + "entry — no other app's access is changed.")
        }
    }
}

// MARK: - General

/// Split into its own `View` rather than a computed property. The tabs had grown large
/// enough that the SwiftUI type checker was taking minutes on the combined expression;
/// each tab as an independent type keeps that solve small.
private struct GeneralTab: View {
    @ObservedObject var prefs: UserPreferences
    let isTrusted: Bool
    let launchAtLogin: Binding<Bool>
    let loginItemError: String?
    @Binding var showReset: Bool
    let accessibility: () -> AnyView

    @State private var transferMessage: String?
    @State private var transferFailed = false

    /// Names the grant *and* how long is left on it — "on" alone would invite leaving
    /// it on, which is the thing the expiry exists to prevent.
    private var keyNameToggleTitle: String {
        guard let remaining = DebugLog.keyNameGrantRemaining else {
            return "Include key names (1 hour)"
        }
        let minutes = Int(remaining / 60) + 1
        return "Including key names — \(minutes) min left"
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacHancer Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try prefs.exportSettings().encoded().write(to: url)
            transferFailed = false
            transferMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bundle = try SettingsBundle.decoded(from: Data(contentsOf: url))
            prefs.importSettings(bundle)
            transferFailed = false
            let count = bundle.bindings?.count ?? 0
            transferMessage = "Imported \(count) binding\(count == 1 ? "" : "s") from "
                + "\(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferMessage = "Import failed — the file isn't a MacHancer export."
        }
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch MacHancer at login", isOn: launchAtLogin)
                if let loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !LoginItem.isInStableLocation {
                    Label("Move the app to /Applications — login items launched from "
                          + "elsewhere are unreliable.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Feedback") {
                Toggle("Show a HUD naming each action as it fires",
                       isOn: $prefs.showActionFeedback)
                    .help("Turn off to run actions silently.")
            }

            Section("Safety") {
                Toggle("Ignore clicks on the empty desktop for window actions",
                       isOn: $prefs.closeIgnoresDesktop)
                    .help("Stops a stray click on bare desktop reaching whatever is behind it.")
                SettingNote("Close and Quit can also ask for confirmation individually — "
                            + "see the Confirm box on each binding.")
            }

            accessibility()

            Section("Backup") {
                HStack {
                    Button("Export Settings…") { exportSettings() }
                    Button("Import Settings…") { importSettings() }
                    Spacer()
                }
                SettingNote("Saves every binding, calibration value and Dock choice to a "
                            + "single file you can keep or move to another Mac.")
                if let transferMessage {
                    Text(transferMessage)
                        .font(.caption)
                        .foregroundStyle(transferFailed ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Diagnostics") {
                Toggle("Write a diagnostic log", isOn: $prefs.debugLogging)
                    .help("Records what the tap saw and what the engine decided, to "
                          + "~/Library/Logs/MacHancer.log.")

                Toggle(keyNameToggleTitle, isOn: $prefs.isLoggingKeyNames)
                    .disabled(!prefs.debugLogging)
                SettingNote("Every keystroke on the system reaches the log, so key names "
                            + "are withheld by default — they would turn it into a "
                            + "transcript of everything you type. Turning them on grants "
                            + "one hour and then lapses on its own, because the risk is "
                            + "forgetting, not the hour.")

                if prefs.debugLogging {
                    Button("Reveal Log in Finder") {
                        NSWorkspace.shared.selectFile(DebugLog.path, inFileViewerRootedAtPath: "")
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: AppInfo.versionString)
                Button("Copy System Info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppInfo.supportSummary, forType: .string)
                }
                .help("Copies the version and macOS build — the two things worth quoting in a bug report.")
            }

            Section {
                Button("Reset All Settings…", role: .destructive) { showReset = true }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gestures

private struct GesturesTab: View {
    @ObservedObject var prefs: UserPreferences

    var body: some View {
        Form {
            Section {
                SettingNote("Shared defaults. Any binding can opt out by unticking "
                            + "Global on its row in Bindings.")
            }

            Section("Timing") {
                ValueSlider(
                    title: "Hold delay", value: $prefs.holdThresholdSec,
                    range: 0.10...2.0, step: 0.05, unit: "s",
                    help: "How long a button is held before Press & Hold fires. "
                        + "Shorter fires sooner but makes a slow click read as a hold."
                )
                ValueSlider(
                    title: "Double-click interval", value: $prefs.doubleClickIntervalSec,
                    range: 0.15...0.60, step: 0.05, unit: "s",
                    help: "Only affects buttons with a Double Click binding — their "
                        + "single click waits this long to see if a second arrives."
                )
            }

            Section("Drag") {
                ValueSlider(
                    title: "Drag distance", value: $prefs.dragThresholdPx,
                    range: 5...50, step: 1, unit: "px", decimals: 0,
                    help: "Travel before a drag gesture is recognised. The dominant "
                        + "axis decides the direction."
                )
            }

            Section("Hold & Swipe") {
                ValueSlider(
                    title: "Horizontal sensitivity", value: $prefs.swipeDistanceXPx,
                    range: 40...600, step: 10, unit: "px", decimals: 0,
                    help: "Travel equal to one full sideways swipe (spaces). "
                        + "Smaller is more sensitive."
                )
                ValueSlider(
                    title: "Vertical sensitivity", value: $prefs.swipeDistanceYPx,
                    range: 40...600, step: 10, unit: "px", decimals: 0,
                    help: "Travel equal to one full vertical swipe (Mission Control "
                        + "and Exposé). Smaller is more sensitive."
                )
                ValueSlider(
                    title: "Direction lock", value: $prefs.swipeAxisLockPx,
                    range: 1...40, step: 1, unit: "px", decimals: 0,
                    help: "Movement before a swipe commits to horizontal or vertical. "
                        + "Raise it if diagonal drags pick the wrong axis."
                )
                SettingNote("Smaller sensitivity values mean less mouse travel per swipe. "
                            + "Each binding can override both axes.")
            }

            Section("Spaces") {
                ValueSlider(
                    title: "Repeat spacing", value: $prefs.spaceSwitchGapSec,
                    range: 0...1.0, step: 0.02, unit: "s",
                    help: "macOS drops a space switch that arrives mid-animation. This "
                        + "holds each repeat back just long enough to land. 0 disables it."
                )
                SettingNote("For a genuinely shorter animation, turn on Reduce Motion in "
                            + "System Settings → Accessibility → Display.")
            }

            MachineSpecificSection(prefs: prefs)
        }
        .formStyle(.grouped)
    }
}

/// Settings whose *correct* value depends on the machine rather than on taste.
///
/// Kept together and labelled as such so it's clear these are not preferences in the
/// ordinary sense: they compensate for behaviour that differs between Macs and macOS
/// builds, and the right setting is whichever one works here.
private struct MachineSpecificSection: View {
    @ObservedObject var prefs: UserPreferences

    var body: some View {
        Section("Machine-Specific") {
            Toggle("Use the live transition for downward swipes",
                   isOn: $prefs.nativeDownSwipe)
                .help("Off: the gesture is measured and App Exposé is opened on release "
                      + "— reliable, but not continuous. On: the transition follows the "
                      + "drag, if this Mac accepts it.")
            SettingNote("On some Macs a downward swipe animates but never completes, so "
                        + "this is off by default. Turn it on to see which kind this is — "
                        + "if Exposé stops opening, turn it back off.")
        }
    }
}
