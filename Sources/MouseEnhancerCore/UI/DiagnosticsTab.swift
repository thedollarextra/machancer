import SwiftUI

/// Self-check plus a live view of what the tap is seeing.
///
/// The event log is the fastest way to answer "why didn't my binding fire?" — with
/// several mouse utilities competing for the same buttons, guessing is hopeless.
struct DiagnosticsTab: View {
    @ObservedObject private var log = EventLog.shared
    @State private var results: [Diagnostics.Result] = []
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                // The tester belongs beside the self-check and the event log, not in
                // Settings: it answers "is this button even reaching us", which is a
                // troubleshooting question, not a preference.
                Section("Button Tester") {
                    ButtonTester()
                }

                Section("Self-check") {
                    HStack {
                        Text("Verify the Accessibility features this app depends on.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Run") { results = Diagnostics.run() }
                    }

                    ForEach(results) { result in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.passed ? .green : .orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.name)
                                Text(result.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 250)

            Divider()

            HStack {
                Text("Event Log").font(.headline)
                Spacer()
                if isRecording {
                    Text("\(log.entries.count) events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(isRecording ? "Stop" : "Record") {
                    isRecording.toggle()
                    isRecording ? log.startRecording() : log.stopRecording()
                }
                Button("Clear") { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if log.entries.isEmpty {
                VStack(spacing: 4) {
                    Text(isRecording ? "Waiting for mouse events…" : "Recording is off.")
                        .foregroundStyle(.secondary)
                    Text("Press Record, then use your mouse buttons to see how each event is handled.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.entries) { entry in
                            HStack(spacing: 6) {
                                Image(systemName: entry.suppressed ? "hand.raised.fill" : "arrow.right.to.line")
                                    .font(.caption2)
                                    .foregroundStyle(entry.suppressed ? .orange : .secondary)
                                    .help(entry.suppressed ? "Swallowed by Mouse Enhancer" : "Passed through")
                                Text(entry.summary)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .onDisappear {
            // Never leave recording on in the background — it costs work per event.
            if isRecording {
                isRecording = false
                log.stopRecording()
            }
        }
    }
}
