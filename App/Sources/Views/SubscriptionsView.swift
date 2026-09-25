import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SubscriptionsView: View {
    @Environment(SubscriptionService.self) private var service
    @Query(sort: \Profile.lastUpdated, order: .reverse) private var profiles: [Profile]
    @State private var showingAdd = false
    @State private var showingAddShadowsocks = false
    @State private var showingImporter = false
    @State private var editing: Profile?
    @State private var editingInfo: Profile?
    @State private var exporting: Profile?
    @State private var error: String?
    /// File name of the last iCloud Drive export, for the confirmation alert.
    @State private var exportedFileName: String?
    // Owned here, not by `EngineOverviewSection`: the section changes
    // container on a fold and would otherwise reset (popping a pushed screen).
    @State private var routeMode: RouteMode = .rule
    @State private var auxiliaryDestination: EngineAuxiliaryDestination?
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Single abbreviated unit with the "ago" wording built in, so the row
    /// subtitle stays on one line even on the narrowest compact widths.
    private static let updatedFormat: Date.RelativeFormatStyle =
        .relative(presentation: .named, unitsStyle: .abbreviated)

    var body: some View {
        // Profiles list first in both poses so its identity (scroll position,
        // swipe state) survives a fold; the Engine column only joins at
        // regular width, with the gutter on the fold divider.
        AdaptiveGrid(spacing: 0, fillsHeight: true) {
            profilesList
            if sizeClass == .regular {
                engineColumn
            }
        }
        .background(AppTheme.screenBackground)
        .navigationDestination(item: $auxiliaryDestination) { destination in
            EngineAuxiliaryDestinationView(destination: destination)
        }
        .navigationTitle("subscriptions.nav.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addSubscriptionMenu(identifier: "subscriptions.toolbar.add")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionSheet(error: $error)
        }
        .sheet(isPresented: $showingAddShadowsocks) {
            AddShadowsocksSheet(error: $error)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: yamlContentTypes(),
            allowsMultipleSelection: false,
        ) { result in
            handleImport(result)
        }
        .sheet(item: $editing) { profile in
            NavigationStack {
                YamlEditorView(profile: profile)
            }
        }
        .sheet(item: $editingInfo) { profile in
            EditSubscriptionInfoSheet(profile: profile, error: $error)
        }
        .sheet(item: $exporting) { profile in
            QRExportSheet(kind: exportKind(profile), payloads: exportPayloads(profile))
        }
        .alert(
            "subscriptions.exportICloud.done.title",
            isPresented: Binding(
                get: { exportedFileName != nil },
                set: { if !$0 { exportedFileName = nil } },
            ),
            presenting: exportedFileName,
        ) { _ in
            Button("common.ok") { exportedFileName = nil }
        } message: { fileName in
            Text("subscriptions.exportICloud.done.message \(fileName)")
        }
        .alert("common.error", isPresented: .constant(error != nil)) {
            Button("common.ok") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var engineSection: some View {
        EngineOverviewSection(
            showsStatusSummary: false,
            routeMode: $routeMode,
            auxiliaryDestination: $auxiliaryDestination,
        )
    }

    private var engineColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("subscriptions.section.engine")
                    .padding(.leading, 4)
                engineSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
    }

    private var profilesList: some View {
        List {
            Section {
                if profiles.isEmpty {
                    emptySubscriptionCard
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                ForEach(profiles) { profile in
                    GlassCard {
                        HStack {
                            // Selection is scoped to the leading label so the
                            // trailing action buttons stay independently
                            // tappable (a whole-row onTapGesture otherwise
                            // shadows them and steals taps in UI tests).
                            Button {
                                try? service.select(profile)
                            } label: {
                                HStack {
                                    Image(systemName: profile.isSelected ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(profile.isSelected ? AppTheme.accent : .secondary)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.name).font(.headline)
                                        // One abbreviated unit ("25 min. ago"), one line: the
                                        // two-unit `.relative` style wrapped on the iPhone Duo
                                        // outer display once the side control strip took its
                                        // share of the width.
                                        updatedSubtitle(profile)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(Text(
                                profile.isSelected
                                    ? "subscriptions.row.a11y.selected"
                                    : "subscriptions.row.a11y.notSelected",
                            ))
                            .accessibilityHint(Text("subscriptions.row.a11y.selectHint"))
                            .accessibilityIdentifier("subscriptions.row.select")
                            Button {
                                editing = profile
                            } label: {
                                Image(systemName: "pencil")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("subscriptions.row.a11y.edit \(profile.name)"))
                            .accessibilityHint(Text("subscriptions.row.a11y.editHint"))
                            .accessibilityIdentifier("subscriptions.row.editYaml")
                            if isExportable(profile) {
                                Button {
                                    exporting = profile
                                } label: {
                                    Image(systemName: "qrcode")
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("subscriptions.row.a11y.exportQR \(profile.name)"))
                                .accessibilityHint(Text("subscriptions.row.a11y.exportQRHint"))
                                .accessibilityIdentifier("subscriptions.row.exportQR")
                            }
                            Button {
                                editingInfo = profile
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("subscriptions.row.a11y.editInfo \(profile.name)"))
                            .accessibilityHint(Text("subscriptions.row.a11y.editInfoHint"))
                            .accessibilityIdentifier("subscriptions.row.editInfoButton")
                        }
                    }
                    // `.contain` keeps the row id on the group without
                    // clobbering the child buttons' own identifiers (a bare
                    // identifier on a container propagates to every child).
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("subscription.row.\(profile.name)")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .swipeActions(edge: .leading) {
                        if !profile.url.isEmpty {
                            Button {
                                Task { try? await service.refresh(profile) }
                            } label: {
                                Label("subscriptions.refresh.swipe", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                            .accessibilityLabel(Text("subscriptions.row.a11y.refresh \(profile.name)"))
                            .accessibilityHint(Text("subscriptions.row.a11y.refreshHint"))
                            .accessibilityIdentifier("subscriptions.row.refresh")
                        }
                        Button {
                            editingInfo = profile
                        } label: {
                            Label("subscriptions.editInfo.swipe", systemImage: "square.and.pencil")
                        }
                        .tint(AppTheme.accent)
                        .accessibilityIdentifier("subscriptions.row.editInfo")
                        // A swipe action rather than a fourth inline icon: the
                        // row's control strip is already at its width budget on
                        // the iPhone Duo outer display.
                        Button {
                            exportToICloudDrive(profile)
                        } label: {
                            Label("subscriptions.exportICloud.swipe", systemImage: "icloud.and.arrow.up")
                        }
                        .tint(.indigo)
                        .accessibilityLabel(Text("subscriptions.row.a11y.exportICloud \(profile.name)"))
                        .accessibilityIdentifier("subscriptions.row.exportICloud")
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? service.delete(profile)
                        } label: {
                            Label("common.delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                SectionHeader("subscriptions.section.profiles")
            }

            // At compact width the Engine section rides at the bottom of the
            // list; at regular width it becomes its own column (see `body`).
            if sizeClass != .regular {
                Section {
                    engineSection
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    SectionHeader("subscriptions.section.engine")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Helpers

private extension SubscriptionsView {
    private func updatedSubtitle(_ profile: Profile) -> Text {
        Text(
            "subscriptions.row.updated \(profile.lastUpdated, format: Self.updatedFormat)",
            comment: "Subscription row subtitle; %@ = relative time, e.g. '25 min. ago'",
        )
    }

    private var emptySubscriptionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("subscriptions.empty.title", systemImage: "tray")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("subscriptions.empty.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("subscriptions.toolbar.addFromURL", systemImage: "link")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .tint(AppTheme.accent)
                    .accessibilityIdentifier("subscriptions.empty.addFromURL")

                    Button {
                        showingImporter = true
                    } label: {
                        // Shorter than the toolbar-menu label — the full
                        // "Import from iCloud Drive…" truncates at this
                        // half-card width.
                        Label("subscriptions.empty.importFile", systemImage: "icloud.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .tint(AppTheme.accent)
                    .accessibilityIdentifier("subscriptions.empty.importFromFile")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `.contain` keeps the card id on the group without clobbering the
        // buttons' own identifiers (a bare identifier on a container view
        // propagates to every child element).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subscriptions.emptyState")
    }

    private func addSubscriptionMenu(identifier: String) -> some View {
        Menu {
            Button {
                showingAdd = true
            } label: {
                Label("subscriptions.toolbar.addFromURL", systemImage: "link")
            }
            .accessibilityIdentifier("subscriptions.toolbar.addFromURL")

            Button {
                showingAddShadowsocks = true
            } label: {
                Label("subscriptions.toolbar.addShadowsocks", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("subscriptions.toolbar.addShadowsocks")

            Button {
                showingImporter = true
            } label: {
                Label("subscriptions.toolbar.importFromFile", systemImage: "icloud.and.arrow.down")
            }
            .accessibilityIdentifier("subscriptions.toolbar.importFromFile")
        } label: {
            Image(systemName: "plus")
                .font(.headline.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("subscriptions.toolbar.a11y.add"))
        .accessibilityIdentifier(identifier)
    }

    /// File picker accepts YAML proper plus `.txt` and unspecified data —
    /// iCloud Drive routinely serves Clash configs uploaded from desktops
    /// where the OS tagged them as `public.plain-text` or just `public.data`,
    /// not `public.yaml`. The actual YAML check happens inside addLocal's
    /// normalize step, so widening the accept list here is safe.
    private func yamlContentTypes() -> [UTType] {
        var types: [UTType] = [.yaml, .plainText, .text, .data]
        if let yml = UTType(filenameExtension: "yml") {
            types.append(yml)
        }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let yaml = try await readSecurityScoped(url)
                    let suggestedName = url.deletingPathExtension().lastPathComponent
                    let name = suggestedName.isEmpty ? "Imported" : suggestedName
                    _ = try await service.addLocal(name: name, yamlContent: yaml)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        case let .failure(err):
            error = err.localizedDescription
        }
    }

    /// iCloud Drive / Files picker hands back a URL that requires a
    /// security-scoped resource access pairing before the sandbox lets us
    /// read it. The picker URL is single-shot — we copy the bytes into a
    /// String and let the scope expire.
    private func readSecurityScoped(_ url: URL) async throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SubscriptionsView",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                    "subscriptions.import.invalidEncoding",
                    comment: "Shown when an imported file isn't UTF-8 text",
                )],
            )
        }
        return yaml
    }
}

// MARK: - QR export

extension SubscriptionsView {
    /// A profile is QR-exportable when there's a share link to encode: the
    /// locally generated Shadowsocks profile exports per-server `ss://` URIs,
    /// URL subscriptions export the subscription URL itself. Local YAML
    /// imports (empty URL, not generated) have nothing link-shaped to share.
    /// Copies the profile's YAML into `iCloud Drive › meow`; the relay then
    /// carries it to the Apple TV (see `ICloudDriveExporter`).
    private func exportToICloudDrive(_ profile: Profile) {
        let name = profile.name
        let yaml = profile.yamlContent
        Task {
            do {
                exportedFileName = try await ICloudDriveExporter.export(name: name, yaml: yaml)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func isExportable(_ profile: Profile) -> Bool {
        ShadowsocksConfigBuilder.isGenerated(profile.yamlContent) || !profile.url.isEmpty
    }

    private func exportKind(_ profile: Profile) -> QRExportSheet.Kind {
        ShadowsocksConfigBuilder.isGenerated(profile.yamlContent) ? .shadowsocksURI : .subscriptionURL
    }

    private func exportPayloads(_ profile: Profile) -> [QRExportSheet.Payload] {
        if ShadowsocksConfigBuilder.isGenerated(profile.yamlContent) {
            return ShadowsocksConfigBuilder.extractServers(from: profile.yamlContent).map {
                QRExportSheet.Payload(title: $0.name, text: ShadowsocksURIEncoder.encode($0))
            }
        }
        guard !profile.url.isEmpty else { return [] }
        return [QRExportSheet.Payload(title: profile.name, text: profile.url)]
    }
}

private struct AddSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionService.self) private var service
    @Binding var error: String?
    @State private var name = ""
    @State private var url = ""
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("subscriptions.add.field.name", text: $name)
                    TextField("subscriptions.add.field.url", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle("subscriptions.add.nav.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey(
                        submitting ? "subscriptions.add.button.adding" : "subscriptions.add.button.add",
                    )) {
                        submitting = true
                        Task {
                            do {
                                _ = try await service.add(name: name, url: url)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                            submitting = false
                        }
                    }
                    .disabled(name.isEmpty || url.isEmpty || submitting)
                }
            }
        }
    }
}

/// Edits a subscription's name and update URL only — the YAML body is left
/// untouched (that's what the pencil / `YamlEditorView` is for). A changed URL
/// is picked up on the next refresh, not immediately. See issue #182.
private struct EditSubscriptionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionService.self) private var service
    let profile: Profile
    @Binding var error: String?
    @State private var name: String
    @State private var url: String

    init(profile: Profile, error: Binding<String?>) {
        self.profile = profile
        _error = error
        _name = State(initialValue: profile.name)
        _url = State(initialValue: profile.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("subscriptions.add.field.name", text: $name)
                        .accessibilityIdentifier("subscriptions.editInfo.nameField")
                    TextField("subscriptions.add.field.url", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier("subscriptions.editInfo.urlField")
                } footer: {
                    Text("subscriptions.editInfo.footer")
                }
            }
            .navigationTitle("subscriptions.editInfo.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("subscriptions.editInfo.button.save") {
                        do {
                            try service.updateInfo(profile, name: name, url: url)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("subscriptions.editInfo.saveButton")
                }
            }
        }
    }
}
