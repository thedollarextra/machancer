import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One tunable value that either follows the shared default or overrides it.
///
/// Rendered as a compact button opening a popover, not as inline controls. A checkbox,
/// a readout and a stepper are already too wide for a binding row, and two of them side
/// by side squeezed the "Global" label down to one letter per line. Same pattern as
/// `AppScopePicker`: a glance costs one word, editing costs one click.
private struct TimingOverrideField: View {
    let title: String
    let globalValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let decimals: Int
    @Binding var value: Double?

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Text(value == nil ? "Auto" : format(value ?? globalValue))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(value == nil
              ? "\(title): using the shared default (\(format(globalValue)))"
              : "\(title): \(format(value ?? globalValue)) — overriding the shared default")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            TimingOverrideEditor(
                title: title, globalValue: globalValue, range: range, step: step,
                unit: unit, decimals: decimals, value: $value
            )
            .frame(width: 260)
        }
    }

    private func format(_ number: Double) -> String {
        String(format: "%.\(decimals)f %@", number, unit)
    }
}

/// Popover body for a single override. Split out so each SwiftUI expression stays small.
private struct TimingOverrideEditor: View {
    let title: String
    let globalValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let decimals: Int
    @Binding var value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.capitalized).font(.headline)

            Toggle("Use the shared default", isOn: usesGlobal)
                .toggleStyle(.checkbox)

            if value == nil {
                Text("Currently \(format(globalValue)), from the Gestures tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ValueSlider(
                    title: "This binding", value: concrete, range: range, step: step,
                    unit: unit, decimals: decimals
                )
            }
        }
        .padding(12)
    }

    private func format(_ number: Double) -> String {
        String(format: "%.\(decimals)f %@", number, unit)
    }

    /// Unticking seeds the override from the current shared value, so taking manual
    /// control never makes the behaviour jump underneath you.
    private var usesGlobal: Binding<Bool> {
        Binding(
            get: { value == nil },
            set: { isGlobal in value = isGlobal ? nil : globalValue }
        )
    }

    private var concrete: Binding<Double> {
        Binding(get: { value ?? globalValue }, set: { value = $0 })
    }
}

/// One editable rule: button + modifiers + trigger → action, plus any payload the
/// chosen action needs.
struct BindingRow: View {
    @Binding var binding: ActionBinding
    @ObservedObject var prefs: UserPreferences
    /// True when an earlier rule already claims this exact input everywhere this one
    /// applies, so this row can never fire.
    var isShadowed: Bool = false
    let onDelete: () -> Void

    @State private var showMacroEditor = false

    /// Stored optional so old bindings still decode; presented as a plain checkbox.
    /// Written back as `nil` when off so a row that never used it stays byte-identical
    /// in the exported JSON.
    private var dragThroughBinding: Binding<Bool> {
        Binding(
            get: { binding.duringWindowDrag == true },
            set: { binding.duringWindowDrag = $0 ? true : nil }
        )
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Drag handle. The whole row is draggable — this marks it as such,
                // which is otherwise invisible.
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .help("Drag to reorder — earlier bindings win when two rules match the same input")

                Toggle("", isOn: $binding.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Enable this binding")

                modifierToggles

                inputSourceToggle

                if MouseButton.isKey(binding.button) {
                    KeyButtonRecorder(button: $binding.button)
                        .frame(width: 118, height: 24)
                } else {
                    Picker("", selection: $binding.button) {
                        ForEach(MouseButton.bindable, id: \.self) { number in
                            Text(MouseButton.label(number)).tag(number)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 118)
                }

                Picker("", selection: $binding.trigger) {
                    ForEach(binding.availableTriggers) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                if binding.trigger == .chord {
                    Picker("", selection: chordPartnerBinding) {
                        ForEach(MouseButton.bindable, id: \.self) { number in
                            Text("+ " + MouseButton.label(number)).tag(number)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Spacer(minLength: 0)

                AppScopePicker(scope: $binding.scope)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this binding")
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)

                if binding.trigger == .swipe {
                    // A swipe has no action to choose: the window server decides what
                    // each direction means, which is precisely what makes it feel native.
                    Text("Up: Mission Control · Down: App Exposé · Left/Right: Spaces")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 340, alignment: .leading)
                } else {
                    Picker("", selection: $binding.action.kind) {
                        Text(ActionKind.none.title).tag(ActionKind.none)
                        ForEach(ActionKind.grouped, id: \.group) { entry in
                            Divider()
                            ForEach(entry.kinds) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)

                    payloadEditor
                }

                Spacer(minLength: 0)

                timingEditor

                // Only offered where movement is the input. A click or a hold is
                // unaffected by another button dragging, so the option would be noise.
                if binding.trigger.isDrag || binding.trigger == .swipe {
                    Toggle("While dragging", isOn: dragThroughBinding)
                        .toggleStyle(.checkbox)
                        .help("Keep this gesture working while a window is already being "
                              + "dragged — press this button mid-drag and the gesture "
                              + "still tracks the mouse.")
                }

                if binding.action.kind.isDestructive {
                    Toggle("Confirm", isOn: $binding.requiresConfirmation)
                        .toggleStyle(.checkbox)
                        .help("Ask before running this destructive action")
                }
            }

            if binding.trigger != .swipe, !binding.action.isRunnable, binding.action.kind != .none {
                Label("Needs configuration — this binding won't fire yet.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isShadowed {
                Label("Never fires — an earlier binding above already uses this exact "
                      + "input. Drag this row above it, or narrow one of them to an app.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if MouseButton.isKey(binding.button), binding.modifiers.isEmpty,
               binding.isEnabled, binding.effectiveScope.mode == .everywhere {
                Label("Bound with no modifiers and no app scope — this key stops typing its character everywhere.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
        .opacity(binding.isEnabled ? 1 : 0.5)
        .sheet(isPresented: $showMacroEditor) {
            MacroEditor(steps: $binding.action.macroSteps)
        }
    }

    /// Switches the row between a mouse button and a keyboard key as its input.
    /// Switching resets what no longer applies: a key can't drag or chord.
    private var inputSourceToggle: some View {
        Button {
            if MouseButton.isKey(binding.button) {
                binding.button = MouseButton.button4
            } else {
                binding.button = MouseButton.keyButton(0x60)   // F5: harmless default
                if !binding.availableTriggers.contains(binding.trigger) {
                    binding.trigger = .click
                }
            }
        } label: {
            Image(systemName: MouseButton.isKey(binding.button) ? "keyboard" : "computermouse")
        }
        .buttonStyle(.borderless)
        .help(MouseButton.isKey(binding.button)
              ? "Bound to a keyboard key — click to switch to a mouse button"
              : "Bound to a mouse button — click to switch to a keyboard key")
    }

    private var modifierToggles: some View {
        HStack(spacing: 2) {
            ForEach(ModifierSet.all, id: \.rawValue) { modifier in
                Toggle(modifier.symbol, isOn: modifierBinding(modifier))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help(modifier.name)
            }
        }
    }

    /// The one timing knob this trigger actually uses. Click and chord have none, so
    /// their rows stay uncluttered.
    @ViewBuilder
    private var timingEditor: some View {
        switch binding.timingKnob {
        case .hold:
            TimingOverrideField(
                title: "hold delay", globalValue: prefs.holdThresholdSec,
                range: 0.10...2.0, step: 0.05, unit: "s", decimals: 2,
                value: $binding.holdDelay
            )
        case .doubleClick:
            TimingOverrideField(
                title: "double-click interval", globalValue: prefs.doubleClickIntervalSec,
                range: 0.15...0.80, step: 0.05, unit: "s", decimals: 2,
                value: $binding.doubleClickInterval
            )
        case .dragDistance:
            TimingOverrideField(
                title: "drag distance", globalValue: prefs.dragThresholdPx,
                range: 3...80, step: 1, unit: "px", decimals: 0,
                value: $binding.dragDistance
            )
        case .swipeDistance:
            // Two axes, because they genuinely want different travel — a sideways flick
            // between spaces versus a deliberate pull into Mission Control.
            HStack(spacing: 6) {
                Text("X").font(.caption).foregroundStyle(.tertiary)
                TimingOverrideField(
                    title: "horizontal sensitivity", globalValue: prefs.swipeDistanceXPx,
                    range: 40...600, step: 10, unit: "px", decimals: 0,
                    value: $binding.swipeDistanceX
                )
                Text("Y").font(.caption).foregroundStyle(.tertiary)
                TimingOverrideField(
                    title: "vertical sensitivity", globalValue: prefs.swipeDistanceYPx,
                    range: 40...600, step: 10, unit: "px", decimals: 0,
                    value: $binding.swipeDistanceY
                )
            }
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var payloadEditor: some View {
        switch binding.action.kind {
        case .mouseButton:
            Picker("", selection: nativeButtonBinding) {
                Text("Same Button (\(MouseButton.label(binding.button)))").tag(-1)
                Divider()
                ForEach(MouseButton.bindable, id: \.self) { number in
                    Text(MouseButton.label(number)).tag(number)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            .help("Deliver this button to the system untouched, so macOS and apps apply their built-in behaviour.")

        case .customKeystroke:
            KeystrokeRecorder(keystroke: $binding.action.keystroke)
                .frame(width: 150, height: 24)

        case .launchApplication:
            Button(applicationLabel) { chooseApplication() }
                .frame(maxWidth: 190)

        case .runShortcut:
            TextField("Shortcut name", text: shortcutNameBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)

        case .macro:
            Button {
                showMacroEditor = true
            } label: {
                let count = (binding.action.macroSteps ?? []).count
                Label(count == 0 ? "Edit Macro…" : "Edit Macro… (\(count))",
                      systemImage: "list.number")
            }
            .frame(maxWidth: 190)

        default:
            EmptyView()
        }
    }

    private var applicationLabel: String {
        guard let path = binding.action.applicationPath else { return "Choose App…" }
        return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.action.applicationPath = url.path
    }

    // MARK: - Bindings into optionals

    private func modifierBinding(_ modifier: ModifierSet) -> Binding<Bool> {
        Binding(
            get: { binding.modifiers.contains(modifier) },
            set: { isOn in
                if isOn { binding.modifiers.insert(modifier) }
                else { binding.modifiers.remove(modifier) }
            }
        )
    }

    /// `-1` stands in for "no explicit number" — the action follows whatever button the
    /// row is bound to, so changing the button above doesn't leave a stale target behind.
    private var nativeButtonBinding: Binding<Int> {
        Binding(
            get: { binding.action.mouseButtonNumber ?? -1 },
            set: { binding.action.mouseButtonNumber = $0 < 0 ? nil : $0 }
        )
    }

    private var chordPartnerBinding: Binding<Int> {
        Binding(
            get: { binding.chordPartner ?? MouseButton.button5 },
            set: { binding.chordPartner = $0 }
        )
    }

    private var shortcutNameBinding: Binding<String> {
        Binding(
            get: { binding.action.shortcutName ?? "" },
            set: { binding.action.shortcutName = $0 }
        )
    }
}
