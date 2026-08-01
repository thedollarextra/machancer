import AppKit
import SwiftUI

/// Middle-click behaviour for every app in the Dock.
///
/// The list is read from the Dock itself rather than maintained by hand, so it always
/// matches what is actually there. Settings are stored per bundle identifier, which
/// means rearranging the Dock, removing an app and putting it back, or renaming it
/// leaves the choice intact — and apps left at the default cost no storage at all.
struct DockTab: View {
    @ObservedObject var prefs: UserPreferences

    @State private var items: [DockInventory.Item] = []
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if items.isEmpty {
                ContentUnavailableView(
                    hasLoaded ? "No Dock Apps Found" : "Reading the Dock…",
                    systemImage: "dock.rectangle",
                    description: Text(hasLoaded
                        ? "Reading the Dock needs Accessibility access. Check the General tab."
                        : "")
                )
            } else {
                List {
                    ForEach(items) { item in
                        DockAppRow(item: item, action: action(for: item.bundleID))
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 10))
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            Divider()
            footer
        }
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle("Middle-click a Dock icon", isOn: $prefs.dockNewInstanceEnabled)
                .toggleStyle(.checkbox)
            Spacer()
            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read the Dock")
        }
        .padding(10)
    }

    private var footer: some View {
        HStack {
            Text(prefs.dockActions.customizedCount == 0
                 ? "All apps use the default."
                 : "\(prefs.dockActions.customizedCount) app\(prefs.dockActions.customizedCount == 1 ? "" : "s") customized.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Reset All to New Window") {
                var map = prefs.dockActions
                map.resetAll()
                prefs.dockActions = map
            }
            .disabled(prefs.dockActions.customizedCount == 0)
        }
        .padding(10)
        .opacity(prefs.dockNewInstanceEnabled ? 1 : 0.5)
    }

    private func reload() {
        items = DockInventory.items()
        hasLoaded = true
    }

    /// Writes go through `prefs.dockActions` wholesale so the change is persisted.
    private func action(for bundleID: String) -> Binding<DockAction> {
        Binding(
            get: { prefs.dockActions.action(for: bundleID) },
            set: { newValue in
                var map = prefs.dockActions
                map.set(newValue, for: bundleID)
                prefs.dockActions = map
            }
        )
    }
}

/// One Dock app: icon, name, and what middle-clicking it does.
private struct DockAppRow: View {
    let item: DockInventory.Item
    @Binding var action: DockAction

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 22, height: 22)

            Text(item.title)
                .lineLimit(1)

            Spacer(minLength: 12)

            if action != DockAction.fallback {
                // Marks the rows the user has actually changed, so a customized Dock is
                // scannable without reading every picker.
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Customized — differs from the default")
            }

            Picker("", selection: $action) {
                ForEach(DockAction.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 210)
        }
    }
}
