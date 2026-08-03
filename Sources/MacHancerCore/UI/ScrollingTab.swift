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

            Section("Feel") {
                ValueSlider(
                    title: "Distance per step", value: $prefs.scrollStepPx,
                    range: 10...400, step: 5, unit: "px", decimals: 0,
                    help: "How far one notch of the wheel travels."
                )
                ValueSlider(
                    title: "Smoothness", value: $prefs.scrollSmoothingSec,
                    range: 0.05...0.60, step: 0.01, unit: "s",
                    help: "How long that distance takes to be paid out. Higher is "
                        + "smoother and floatier; lower is tighter and more immediate."
                )
                ValueSlider(
                    title: "Acceleration", value: $prefs.scrollAcceleration,
                    range: 0...1, step: 0.05, decimals: 2,
                    help: "How much further a notch travels when you spin the wheel "
                        + "quickly. 0 gives every notch the same distance."
                )
            }
            .disabled(!prefs.smoothScrollEnabled)

            Section("Compatibility") {
                Toggle("Send trackpad gesture phases", isOn: $prefs.scrollGesturePhases)
                    .help("Off if an app reacts to scrolling as though it were a swipe.")
                SettingNote("Phases are what give rubber-band overscroll and the "
                            + "smoothest path through Safari. They are only ever sent "
                            + "vertically — horizontally they read as a two-finger "
                            + "swipe, which navigates back instead of scrolling.")

                Toggle("Coast after the wheel stops", isOn: $prefs.scrollMomentum)
                    .disabled(!prefs.scrollGesturePhases)
                    .help("Labels the tail of a scroll as momentum, the way a trackpad "
                          + "does once your fingers leave it.")
                SettingNote("The distance travelled is the same either way; what changes "
                            + "is what the app is told the movement is, which decides how "
                            + "it snaps, paginates and rubber-bands at the end. Turn it "
                            + "off if an app ignores the last part of a scroll — a few "
                            + "discard momentum outright.")
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
