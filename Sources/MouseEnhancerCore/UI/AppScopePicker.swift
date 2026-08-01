import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edits an `AppScope`: everywhere, a whitelist, or a blacklist.
///
/// A compact button opening a popover, because it sits at the end of an already busy
/// binding row and is left alone most of the time — the common case should cost one
/// glance, not permanent width.
struct AppScopePicker: View {
    @Binding var scope: AppScope?
    /// Shown when the scope is inherited rather than set — the app-wide default.
    var placeholder: String = "All Apps"

    @State private var showPopover = false

    private var current: AppScope { scope ?? .everywhere }

    private var bound: Binding<AppScope> {
        Binding(
            get: { scope ?? .everywhere },
            set: { scope = $0.mode == .everywhere && $0.bundleIDs.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Label(current.summary(nameFor: AppCatalog.displayName),
                  systemImage: current.isUnsatisfiable ? "exclamationmark.triangle" : current.mode.symbol)
                .font(.caption)
                .foregroundStyle(current.isUnsatisfiable ? Color.orange : Color.secondary)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(helpText)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            AppScopeEditor(scope: bound, title: "This Binding Applies In", listHeight: 130)
                .frame(width: 320)
        }
    }

    private var helpText: String {
        switch current.mode {
        case .everywhere: return "Applies in every app"
        case .onlyIn:
            return current.bundleIDs.isEmpty
                ? "Set to “Only In” with no apps listed — this never fires"
                : "Applies only in: " + current.bundleIDs.map(AppCatalog.displayName).joined(separator: ", ")
        case .exceptIn:
            return current.bundleIDs.isEmpty
                ? "Applies in every app (nothing excluded)"
                : "Applies everywhere except: " + current.bundleIDs.map(AppCatalog.displayName).joined(separator: ", ")
        }
    }
}

/// The shared editor body — mode picker plus a selectable app list with the standard
/// macOS +/− controls underneath. Used by the per-binding popover *and* by the app-wide
/// setting, so the two can't drift apart.
struct AppScopeEditor: View {
    @Binding var scope: AppScope
    let title: String
    /// The per-binding popover is compact; the app-wide one has a whole tab to breathe in.
    var listHeight: CGFloat = 150

    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)

            Picker("", selection: $scope.mode) {
                ForEach(AppScope.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(explanation)
                .font(.caption)
                .foregroundStyle(scope.isUnsatisfiable ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if scope.mode != .everywhere {
                appList
                controls
            }
        }
        .padding(12)
    }

    private var explanation: String {
        switch scope.mode {
        case .everywhere:
            return "Applies in every application."
        case .onlyIn:
            return scope.bundleIDs.isEmpty
                ? "No apps listed — with “Only In” selected, this will never apply."
                : "Applies only while one of these apps is frontmost."
        case .exceptIn:
            return scope.bundleIDs.isEmpty
                ? "Nothing excluded yet, so this currently applies everywhere."
                : "Applies everywhere except while one of these apps is frontmost."
        }
    }

    private var appList: some View {
        List(selection: $selection) {
            ForEach(scope.bundleIDs, id: \.self) { id in
                HStack(spacing: 6) {
                    Image(nsImage: icon(for: id))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(AppCatalog.displayName(for: id))
                    Spacer()
                }
                .tag(id)
            }
        }
        .frame(height: listHeight)
        .border(Color.secondary.opacity(0.25))
    }

    private var controls: some View {
        HStack(spacing: 0) {
            // "+" offers the running apps for convenience and Browse for anything else.
            Menu {
                Button("Browse…") { browseForApp() }
                if !addableApps.isEmpty {
                    Divider()
                    ForEach(addableApps, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Add an application — browse for it, or pick one that's running")

            Button {
                guard let selection else { return }
                scope.bundleIDs.removeAll { $0 == selection }
                self.selection = nil
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
            .disabled(selection == nil)
            .help("Remove the selected application")

            Spacer()

            Text("\(scope.bundleIDs.count) app\(scope.bundleIDs.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var addableApps: [(bundleID: String, name: String)] {
        AppCatalog.runningApps.filter { !scope.bundleIDs.contains($0.bundleID) }
    }

    private func add(_ bundleID: String) {
        guard !scope.bundleIDs.contains(bundleID) else { return }
        scope.bundleIDs.append(bundleID)
        selection = bundleID
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        add(id)
    }
}
