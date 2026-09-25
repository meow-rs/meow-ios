import SwiftUI

/// The Apple TV's "Import from iCloud Drive" sheet: the configs the iPhone
/// app relayed from `iCloud Drive › meow` (see `ICloudRelay`). Picking one
/// hands it to `onImport` and closes the sheet — the import itself, and any
/// error alert, run on `TVContentView`, since tvOS can't present an alert
/// from a view that is being dismissed.
struct TVICloudImportView: View {
    @Environment(ICloudRelayStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onImport: (RelayedConfig) -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("tv.icloud.title")
        }
        // A full-screen cover, not a `.sheet`: tvOS sheets are a narrow card
        // that truncates the title and leaves no room for a file list. A
        // cover's content is transparent, so it needs its own backdrop.
        .background(.thickMaterial, ignoresSafeAreaEdges: .all)
        .task { await store.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .noAccount:
            message("tv.icloud.noAccount", systemImage: "person.crop.circle.badge.exclamationmark")
        case let .failed(error):
            message("tv.icloud.failed \(error)", systemImage: "exclamationmark.icloud")
        case .idle, .loading, .loaded:
            if !store.configs.isEmpty {
                // Keep the list up during a refresh rather than flashing a spinner.
                configList
            } else if store.status == .loaded {
                message("tv.icloud.empty", systemImage: "icloud")
            } else {
                ProgressView()
            }
        }
    }

    private var configList: some View {
        List {
            Section {
                ForEach(store.configs) { config in
                    Button {
                        onImport(config)
                        dismiss()
                    } label: {
                        HStack(spacing: 20) {
                            Label(config.fileName, systemImage: "doc.text")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(config.modifiedAt, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("tv.icloud.row.\(config.fileName)")
                }
            } footer: {
                Text("tv.icloud.instructions")
            }
            refreshButton
        }
    }

    /// Instructions travel with every empty/error state: a TV user who got
    /// here has no other way to learn where the files are supposed to come
    /// from.
    private func message(_ title: LocalizedStringKey, systemImage: String) -> some View {
        VStack(spacing: 30) {
            Image(systemName: systemImage)
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3)
                .multilineTextAlignment(.center)
            Text("tv.icloud.instructions")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            refreshButton
        }
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var refreshButton: some View {
        Button {
            Task { await store.reload() }
        } label: {
            Label("subscriptions.refresh.swipe", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("tv.icloud.refresh")
    }
}
