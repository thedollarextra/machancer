import AppKit
import SwiftUI

/// The app-wide scope: where MacHancer operates at all.
///
/// Previously this was a blacklist only — games, remote-desktop clients and drawing
/// apps that use the extra mouse buttons natively. It now takes the same three modes an
/// individual binding does, so it can equally be inverted into "only work in these
/// apps". This gate sits above everything: outside it, no binding fires and every
/// button behaves natively, whatever the individual rules say.
struct ExclusionsTab: View {
    @ObservedObject var prefs: UserPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppScopeEditor(scope: scopeBinding, title: "MacHancer Applies In", listHeight: 230)

            Divider()

            HStack {
                if let frontmost = FrontmostAppTracker.shared.bundleIdentifier,
                   frontmost != Bundle.main.bundleIdentifier,
                   prefs.globalScope.mode != .everywhere,
                   !prefs.globalScope.bundleIDs.contains(frontmost) {
                    Button("Add “\(FrontmostAppTracker.shared.localizedName ?? frontmost)”") {
                        prefs.globalScope.bundleIDs.append(frontmost)
                    }
                    .help("Add the app that was frontmost before this window opened")
                }

                Spacer()

                Text("Individual bindings can narrow this further on the Bindings tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    /// Writes go through `prefs.globalScope` wholesale so the change is persisted and
    /// the per-app lookup cache is invalidated.
    private var scopeBinding: Binding<AppScope> {
        Binding(
            get: { prefs.globalScope },
            set: { prefs.globalScope = $0 }
        )
    }
}
