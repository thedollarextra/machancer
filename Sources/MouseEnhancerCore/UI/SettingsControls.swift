import SwiftUI

/// A labelled numeric setting: name, current value, stepper, slider.
///
/// One component for every tunable in the app. These were previously hand-built at each
/// site and had drifted — different orders, some with steppers and some without, values
/// formatted three ways — which reads as unfinished however carefully each one was
/// written. Detail belongs in `help` (a tooltip) rather than a paragraph under every
/// row; a settings pane the user has to *read* is a settings pane they will avoid.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var decimals: Int = 2
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Text(formatted)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 2)
        .help(help)
    }

    private var formatted: String {
        unit.isEmpty
            ? String(format: "%.\(decimals)f", value)
            : String(format: "%.\(decimals)f %@", value, unit)
    }
}

/// A one-line explanatory note. Used sparingly — where the *consequence* of a setting
/// isn't guessable from its name.
struct SettingNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
