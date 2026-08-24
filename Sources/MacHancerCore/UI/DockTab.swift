import AppKit
import SwiftUI

/// Middle-click behaviour for everything in the Dock: applications, pinned folders,
/// pinned files and links, and Trash.
///
/// The list is read from the Dock itself rather than maintained by hand, so it always
/// matches what is actually there. Settings are stored per bundle identifier for apps and
/// per path for everything else, which means rearranging the Dock, removing an item and
/// putting it back, or renaming an app leaves the choice intact — and items left at the
/// default cost no storage at all.
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
                    hasLoaded ? "No Dock Items Found" : "Reading the Dock…",
                    systemImage: "dock.rectangle",
                    description: Text(hasLoaded
                        ? "Reading the Dock needs Accessibility access. Check the General tab."
                        : "")
                )
            } else {
                List {
                    ForEach(items) { item in
                        DockItemRow(item: item, action: action(for: item))
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
            Toggle("Middle-click a Dock icon", isOn: $prefs.dockMiddleClickEnabled)
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
                 ? "All items use their default."
                 : "\(prefs.dockActions.customizedCount) item\(prefs.dockActions.customizedCount == 1 ? "" : "s") customized.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Reset All to Defaults") {
                var map = prefs.dockActions
                map.resetAll()
                prefs.dockActions = map
            }
            .disabled(prefs.dockActions.customizedCount == 0)
        }
        .padding(10)
        .opacity(prefs.dockMiddleClickEnabled ? 1 : 0.5)
    }

    private func reload() {
        items = DockInventory.items()
        hasLoaded = true
    }

    /// Writes go through `prefs.dockActions` wholesale so the change is persisted.
    ///
    /// The kind rides along on both sides because the default differs by kind, and a
    /// choice equal to the default is stored as nothing at all.
    private func action(for item: DockInventory.Item) -> Binding<DockAction> {
        Binding(
            get: { prefs.dockActions.action(for: item.key, kind: item.kind) },
            set: { newValue in
                var map = prefs.dockActions
                map.set(newValue, for: item.key, kind: item.kind)
                prefs.dockActions = map
            }
        )
    }
}

/// One Dock tile: icon, name, and what middle-clicking it does.
private struct DockItemRow: View {
    let item: DockInventory.Item
    @Binding var action: DockAction

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                // Two folders can share a name — one Downloads in the home folder and
                // another on an external disk look identical without this.
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 12)

            if action != DockAction.fallback(for: item.kind) {
                // Marks the rows the user has actually changed, so a customized Dock is
                // scannable without reading every picker.
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Customized — differs from the default")
            }

            Picker("", selection: $action) {
                ForEach(DockAction.options(for: item.kind)) { option in
                    Text(option.title(for: item.kind)).tag(option)
                }
            }
            .labelsHidden()
            // Trailing, not centred: a popup sizes itself to its longest option, so the
            // three-item folder menu is narrower than the eight-item application one and
            // the column went ragged the moment the Dock's pinned section appeared here.
            .frame(width: 210, alignment: .trailing)
        }
    }
}

private extension DockItemRow {
    /// The path, abbreviated the way a shell would. Applications are left bare: their
    /// install location is never the ambiguous part, and forty rows of `/Applications`
    /// is just noise.
    var subtitle: String? {
        switch item.kind {
        case .application, .trash:
            return nil
        case .folder, .file:
            return item.url.map { (($0.path as NSString).abbreviatingWithTildeInPath) }
        case .webURL:
            return item.url?.absoluteString
        }
    }
}
