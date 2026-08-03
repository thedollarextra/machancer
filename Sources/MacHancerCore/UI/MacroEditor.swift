import AppKit
import SwiftUI

/// Sheet for editing a `.macro` action's step list: keystrokes, mouse clicks,
/// built-in actions, and delays, in order, with drag-to-reorder.
struct MacroEditor: View {
    @Binding var steps: [MacroStep]?
    @Environment(\.dismiss) private var dismiss

    /// The list edits a non-optional working copy; `nil` and `[]` mean the same thing
    /// to the model, so the distinction isn't worth threading through every row.
    private var workingSteps: Binding<[MacroStep]> {
        Binding(
            get: { steps ?? [] },
            set: { steps = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Macro Steps").font(.headline)
                Spacer()
                Text("Steps run in order, top to bottom. Drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            if workingSteps.wrappedValue.isEmpty {
                ContentUnavailableView(
                    "No Steps",
                    systemImage: "list.number",
                    description: Text("Add a keystroke, mouse click, action, or wait step.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(workingSteps, id: \.id) { $step in
                        MacroStepRow(step: $step) {
                            workingSteps.wrappedValue.removeAll { $0.id == step.id }
                        }
                    }
                    .onMove { from, to in
                        workingSteps.wrappedValue.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Menu {
                    Button("Keystroke") { add(.keystroke) }
                    Button("Mouse Click") { add(.mouseClick) }
                    Button("Action") { add(.action) }
                    Button("Wait") { add(.delay) }
                } label: {
                    Label("Add Step", systemImage: "plus")
                }
                .fixedSize()

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 400)
    }

    private func add(_ kind: MacroStep.Kind) {
        var step = MacroStep(kind: kind)
        switch kind {
        case .delay:      step.delaySec = 0.5
        case .mouseClick: step.mouseButton = 0
        case .action:     step.actionKind = .missionControl
        case .keystroke:  break   // recorded in the row
        }
        workingSteps.wrappedValue.append(step)
    }
}

/// One step: number, type picker, the payload editor that type needs, delete.
private struct MacroStepRow: View {
    @Binding var step: MacroStep
    let onDelete: () -> Void

    /// Mouse buttons a click step can post — including left/right, which are fine to
    /// *send* even though they're not bindable as triggers.
    private static let clickableButtons = Array(0...7)

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $step.kind) {
                ForEach(MacroStep.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            payloadEditor

            Spacer(minLength: 0)

            if !step.isConfigured {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("This step isn't configured yet and will be skipped.")
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var payloadEditor: some View {
        switch step.kind {
        case .keystroke:
            KeystrokeRecorder(keystroke: $step.keystroke)
                .frame(width: 150, height: 24)

        case .mouseClick:
            Picker("", selection: mouseButtonBinding) {
                ForEach(Self.clickableButtons, id: \.self) { number in
                    Text(MouseButton.label(number)).tag(number)
                }
            }
            .labelsHidden()
            .frame(width: 140)

        case .action:
            Picker("", selection: actionKindBinding) {
                ForEach(ActionKind.macroInvocable) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 220)

        case .delay:
            HStack(spacing: 4) {
                TextField("", value: delayBinding, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper("", value: delayBinding, in: 0.05...10, step: 0.05)
                    .labelsHidden()
                Text("s").foregroundStyle(.secondary)
            }
        }
    }

    private var mouseButtonBinding: Binding<Int> {
        Binding(get: { step.mouseButton ?? 0 }, set: { step.mouseButton = $0 })
    }

    private var actionKindBinding: Binding<ActionKind> {
        Binding(get: { step.actionKind ?? .missionControl }, set: { step.actionKind = $0 })
    }

    private var delayBinding: Binding<Double> {
        Binding(
            get: { step.delaySec ?? 0.5 },
            set: { step.delaySec = min(max($0, 0.05), 10) }
        )
    }
}
