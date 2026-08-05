import SwiftUI

/// Smooth scrolling: how a wheel notch is turned into a trackpad-shaped stream.
///
/// Its own tab rather than a section of Gestures, because it has nothing to do with
/// bindings — no button, no trigger, no action. It is a filter on the scroll stream that
/// happens to live in the same tap.
struct ScrollingTab: View {
    @ObservedObject var prefs: UserPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Smooth scrolling", isOn: $prefs.smoothScrollEnabled)
                    .help("Replaces each wheel notch with a short, decelerating glide.")
                SettingNote("A wheel notch moves the page in one jump; a trackpad moves "
                            + "it as a stream of small steps. This turns the first into "
                            + "the second, which is what makes Safari scroll the way it "
                            + "does under two fingers.")
            }

            Section("Axes") {
                Toggle("Invert wheel direction (vertical)", isOn: $prefs.reverseVertical)
                Toggle("Invert wheel direction (horizontal)", isOn: $prefs.reverseHorizontal)
                Toggle("Smooth vertical scrolling", isOn: $prefs.smoothVertical)
                Toggle("Smooth horizontal scrolling", isOn: $prefs.smoothHorizontal)
                SettingNote("macOS has one natural-scrolling switch and it moves both "
                            + "axes together, so inverting only one of them is only "
                            + "reachable here.")
            }
            .disabled(!prefs.smoothScrollEnabled)

            Section("Keys") {
                ModifierPicker(title: "Dash Key", selection: $prefs.scrollBoostModifier,
                               help: "Increase scrolling speed on long pages.")
                ModifierPicker(title: "Toggle Key", selection: $prefs.scrollToggleModifier,
                               help: "Change vertical scrolling to horizontal scrolling.")
                ModifierPicker(title: "Block Key", selection: $prefs.scrollDisableModifier,
                               help: "Temporarily block smooth scrolling.")
                SettingNote("A modifier claimed here stops being a zoom modifier for the "
                            + "wheel — ⌘ and ⌃ are otherwise left alone, since both zoom.")
            }
            .disabled(!prefs.smoothScrollEnabled)

            Section("Feel") {
                ValueSlider(
                    title: "Step", value: $prefs.scrollStepPx,
                    range: 10...400, step: 0.4, decimals: 2,
                    help: "Sets the minimum scroll distance."
                )
                ValueSlider(
                    title: "Speed", value: $prefs.scrollSpeed,
                    range: 0.1...10, step: 0.05, decimals: 2,
                    help: "Multiplies Step. Distance per notch is Step x Speed."
                )
                ValueSlider(
                    title: "Duration", value: $prefs.scrollSmoothingSec,
                    range: 0.05...0.60, step: 0.01, unit: "s",
                    help: "How long that distance takes to be paid out."
                )
                ValueSlider(
                    title: "Dash multiplier", value: $prefs.scrollBoostFactor,
                    range: 1...10, step: 0.5, unit: "x", decimals: 1,
                    help: "How much further a notch travels while the Dash Key is held."
                )
                ValueSlider(
                    title: "Auto acceleration", value: $prefs.scrollAcceleration,
                    range: 0...1, step: 0.05, decimals: 2,
                    help: "Extra distance when the wheel is spun quickly. Mos has no "
                        + "equivalent, so 0 matches it."
                )
                SettingNote("Step and Speed are Mos's two dials and compose the same way, "
                            + "so its numbers transfer directly. Duration is in seconds "
                            + "here rather than Mos's own unit.")
            }
            .disabled(!prefs.smoothScrollEnabled)

            Section("Emission") {
                Picker("Event shape", selection: $prefs.scrollGesturePhases) {
                    Text("Line events (Mos-style)").tag(false)
                    Text("Trackpad gestures").tag(true)
                }
                .pickerStyle(.radioGroup)

                SettingNote("Line events are what Mos emits — non-continuous, no gesture "
                            + "phases, smoothness bought purely with volume and rate. "
                            + "Nothing downstream can mistake a scroll for a swipe or "
                            + "discard its tail, so it behaves uniformly everywhere.")
                SettingNote("Trackpad gestures mark the events continuous and wrap them "
                            + "in began/changed/ended, which is what unlocks rubber-band "
                            + "overscroll and WebKit's smoothest path in Safari — at the "
                            + "cost of apps that read a phased horizontal scroll as a "
                            + "back-swipe, or drop momentum entirely.")

                Toggle("Coast after the wheel stops", isOn: $prefs.scrollMomentum)
                    .disabled(!prefs.scrollGesturePhases)
                    .help("Momentum is a gesture concept; it needs trackpad mode.")
            }
            .disabled(!prefs.smoothScrollEnabled)

            Section {
                AppScopeEditor(scope: scopeBinding, title: "Smooth Scrolling Applies In",
                               listHeight: 120)
                    .padding(.horizontal, -4)
                SettingNote("Exclude anything that wants the raw wheel — games, remote "
                            + "desktops, and apps that count notches rather than pixels. "
                            + "Trackpads and Magic Mice are never touched.")
            }
            .disabled(!prefs.smoothScrollEnabled)
        }
        .formStyle(.grouped)
    }

    /// Writes go through `prefs.smoothScrollScope` wholesale so the change is persisted.
    private var scopeBinding: Binding<AppScope> {
        Binding(
            get: { prefs.smoothScrollScope },
            set: { prefs.smoothScrollScope = $0 }
        )
    }
}

/// One modifier, or none. Mirrors how the rest of the app talks about modifiers while
/// staying a single-choice control — two modifiers for one hold would be a chord, and
/// these are meant to be reachable with the hand already on the mouse.
private struct ModifierPicker: View {
    let title: String
    @Binding var selection: ModifierSet
    var help: String = ""

    private static let options: [(String, ModifierSet)] = [
        ("None", ModifierSet()), ("⌃ Control", .control), ("⌥ Option", .option),
        ("⇧ Shift", .shift), ("⌘ Command", .command),
    ]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Self.options, id: \.1.rawValue) { Text($0.0).tag($0.1) }
        }
        .help(help)
    }
}
