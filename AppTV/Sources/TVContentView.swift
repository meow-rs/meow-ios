import MeowModels
import SwiftData
import SwiftUI

/// The whole tvOS app in one screen: title, connect button, subscription-URL
/// field, profile list.
///
/// A re-implementation rather than a reuse of `ContentView`: everything under
/// `App/Sources/Views` is iPhone-shaped (tab bar, sheets, swipe actions, the
/// QR camera scanner) and parts of it don't exist on tvOS at all, so this
/// target compiles the model + service layer only and puts this view on top.
/// The duplicated stage labels below are the cost of that split — keep them
/// in sync with `GlobalVpnSwitchBar`.
///
/// Layout decisions against the tvOS HIG are listed in `AppTV/README.md`.
///
/// Styling note: no explicit `buttonStyle` anywhere. tvOS's default style is
/// the one that gets the focus lift and parallax, which is what a remote
/// control needs; `.bordered` / `.borderedProminent` only arrived in tvOS 17
/// and buy nothing here.
struct TVContentView: View {
    @Environment(VpnManager.self) private var vpnManager
    @Environment(AppIPCBridge.self) private var ipcBridge
    @Environment(SubscriptionService.self) private var subscriptionService
    /// Same ordering as the iOS Configs tab (`SubscriptionsView`).
    @Query(sort: \Profile.lastUpdated, order: .reverse) private var profiles: [Profile]

    @State private var subscriptionURL = ""
    @State private var isAdding = false
    @State private var importError: String?
    @State private var isShowingICloudImport = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case toggle
        case subscriptionURL
    }

    /// No outer padding: SwiftUI already insets tvOS content by the TV safe
    /// area (80 pt sides, 60 pt top/bottom), and adding the same again
    /// doubled the margins and left the bottom third of the screen empty.
    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            header

            HStack(alignment: .top, spacing: 60) {
                connectionPanel
                subscriptionPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($focusedField, .toggle)
        // An alert rather than an inline banner: tvOS errors that need
        // acknowledging are modal, and a banner pushed every control down
        // and moved focus targets out from under the remote.
        .fullScreenCover(isPresented: $isShowingICloudImport) {
            TVICloudImportView(onImport: importRelayed)
        }
        .alert("common.error", isPresented: isShowingError, presenting: errorMessage) { _ in
            Button("common.ok", action: dismissError)
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("home.nav.title")
                .font(.largeTitle.weight(.bold))
            Text(profileName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("vpn.profile.name")
        }
    }

    private var connectionPanel: some View {
        VStack(spacing: 24) {
            Image(systemName: isConnected ? "power.circle.fill" : "power.circle")
                .font(.system(size: 96))
                .foregroundStyle(isConnected ? Color.green : Color.secondary)
                .accessibilityHidden(true)

            Text(stageBadgeText)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("vpn.status")

            // Never `.disabled`: a disabled control can't take focus on
            // tvOS, so the one button on this side of the screen would be
            // unreachable and the remote would have nowhere to land. With no
            // profile it moves focus to the URL field instead (`toggle()`).
            Button(action: toggle) {
                Text(toggleTitle)
                    .frame(maxWidth: .infinity)
            }
            .focused($focusedField, equals: .toggle)
            .accessibilityIdentifier("vpn.toggle")

            if needsProfile {
                Text("tv.connect.hint.noProfile")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .focusSection()
    }

    private var subscriptionPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("tv.subscription.section")
                .font(.title3.weight(.semibold))

            TextField("tv.subscription.field.url", text: $subscriptionURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: .subscriptionURL)
                .onSubmit(addSubscription)
                .accessibilityIdentifier("tv.subscription.url")

            HStack(spacing: 20) {
                Button(LocalizedStringKey(
                    isAdding ? "subscriptions.add.button.adding" : "subscriptions.add.button.add",
                )) {
                    addSubscription()
                }
                .disabled(isAdding || trimmedURL.isEmpty)
                .accessibilityIdentifier("tv.subscription.add")

                Button {
                    isShowingICloudImport = true
                } label: {
                    Label("tv.icloud.button", systemImage: "icloud.and.arrow.down")
                }
                .accessibilityIdentifier("tv.icloud.open")
            }

            Divider()

            Text("tv.profiles.section")
                .font(.title3.weight(.semibold))

            if profiles.isEmpty {
                Text("tv.profiles.empty")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                // `List`, not a `ScrollView` of buttons: a clipping scroll
                // view cut the focused row's lift off flat, and `List` rows
                // get the system focus treatment with room to grow.
                List(orderedProfiles) { profile in
                    profileRow(profile)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .focusSection()
    }

    private func profileRow(_ profile: Profile) -> some View {
        Button {
            select(profile)
        } label: {
            HStack(spacing: 12) {
                Text(profile.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if profile.isSelected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(profile.isSelected ? .isSelected : [])
        .accessibilityIdentifier("tv.profile.row.\(profile.name)")
        // Long-press on the remote: the tvOS home for the secondary actions
        // iOS keeps in swipe actions.
        .contextMenu {
            if !profile.url.isEmpty {
                Button {
                    refresh(profile)
                } label: {
                    Label("subscriptions.refresh.swipe", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                delete(profile)
            } label: {
                Label("common.delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Derived state

    private var selectedProfile: Profile? {
        profiles.first(where: \.isSelected)
    }

    /// The active profile first, so it is never scrolled out of sight behind
    /// profiles that merely refreshed more recently.
    private var orderedProfiles: [Profile] {
        profiles.filter(\.isSelected) + profiles.filter { !$0.isSelected }
    }

    private var trimmedURL: String {
        subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var profileName: String {
        selectedProfile?.name ?? String(
            localized: "home.profile.none",
            comment: "Placeholder shown in profile-name slot when no subscription profile is selected",
        )
    }

    private var errorMessage: String? {
        importError ?? vpnManager.lastError
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    dismissError()
                }
            },
        )
    }

    private var isConnected: Bool {
        vpnManager.stage == .connected
    }

    private var isInFlight: Bool {
        let stage = vpnManager.stage
        return stage == .preparing || stage == .connecting || stage == .stopping
    }

    private var needsProfile: Bool {
        !isConnected && !isInFlight && selectedProfile == nil
    }

    private var stageBadgeText: LocalizedStringKey {
        switch vpnManager.stage {
        case .idle, .stopped, .error: "home.badge.disconnected"
        case .preparing: "home.badge.preparing"
        case .connecting: "home.badge.connecting"
        case .connected: "home.badge.connected"
        case .stopping: "home.badge.disconnecting"
        }
    }

    private var toggleTitle: LocalizedStringKey {
        switch vpnManager.stage {
        case .connected: "home.toggle.disconnect"
        case .preparing: "home.toggle.preparing"
        case .connecting: "home.toggle.connecting"
        case .stopping: "home.toggle.disconnecting"
        default: "home.toggle.connect"
        }
    }
}

// MARK: - Actions

private extension TVContentView {
    /// Same ordering as `GlobalVpnSwitchBar.toggle()`: the IPC intent is
    /// queued BEFORE the tunnel call, so the extension already knows which
    /// profile to load by the time it starts.
    ///
    /// One tvOS-only step first: `config.yaml` lives under the App Group's
    /// `Library/Caches` here (see `AppGroup.containerURL`), which the system
    /// may purge while the selected profile survives in SwiftData. Rewriting
    /// it from the profile keeps a purge from leaving the tunnel with no
    /// config to read.
    func toggle() {
        // Stands in for `.disabled` (see `connectionPanel`): presses while a
        // transition is running are ignored, and with nothing to connect to
        // the press takes the user to the field that fixes that.
        if isInFlight {
            return
        }
        if needsProfile {
            focusedField = .subscriptionURL
            return
        }
        if isConnected {
            ipcBridge.send(.stop)
            Task { await vpnManager.disconnect() }
        } else {
            if let selectedProfile {
                do {
                    try subscriptionService.writeActiveConfig(selectedProfile)
                } catch {
                    importError = error.localizedDescription
                    return
                }
            }
            ipcBridge.send(.start, profileID: selectedProfile?.id)
            Task { await vpnManager.connect() }
        }
    }

    func addSubscription() {
        let raw = trimmedURL
        // Same scheme allow-list as `SubscriptionDeepLink.parse` — only
        // http/https. A mistyped `file://` would otherwise turn the field
        // into an arbitrary local-file read.
        //
        // `http://` is deliberately let through here rather than rejected:
        // this target's Info.plist carries the same ATS settings as iOS, so
        // `SubscriptionService.rejectPlainHTTP` catches it one layer down and
        // surfaces the localized `subscriptions.error.plainHTTP` explanation.
        // Duplicating that check here would only replace a good message with
        // a worse one.
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else {
            importError = String(localized: "tv.subscription.error.invalidURL")
            return
        }

        isAdding = true
        importError = nil
        Task {
            do {
                // iOS asks for a name in a second field; on a remote control
                // that's two keyboard sessions for a label, so derive it from
                // the host — the same fallback `SubscriptionDeepLink` uses for
                // a link with no `&name=`.
                let profile = try await subscriptionService.add(name: url.host ?? raw, url: raw)
                // Add-then-select: `add` only inserts, and a profile nobody
                // selected never reaches `config.yaml`, so the tunnel would
                // have nothing to start with.
                try subscriptionService.select(profile)
                reloadIfConnected(profile)
                subscriptionURL = ""
            } catch {
                importError = error.localizedDescription
            }
            isAdding = false
        }
    }

    /// Same add-then-select as `addSubscription`, via `upsertLocal` so
    /// re-importing a file edited on the Mac updates its profile in place.
    func importRelayed(_ config: RelayedConfig) {
        Task {
            do {
                let profile = try await subscriptionService.upsertLocal(
                    name: config.profileName,
                    yamlContent: config.yaml,
                )
                try subscriptionService.select(profile)
                reloadIfConnected(profile)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    func select(_ profile: Profile) {
        do {
            try subscriptionService.select(profile)
            reloadIfConnected(profile)
        } catch {
            importError = error.localizedDescription
        }
    }

    func refresh(_ profile: Profile) {
        Task {
            do {
                try await subscriptionService.refresh(profile)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    func delete(_ profile: Profile) {
        do {
            try subscriptionService.delete(profile)
        } catch {
            importError = error.localizedDescription
        }
    }

    func dismissError() {
        importError = nil
        vpnManager.clearError()
    }

    /// `select` rewrites `config.yaml`, but a running engine has already read
    /// it. On iOS the escape hatch is Settings → "Reload engine config"; tvOS
    /// has no settings screen, so switching profiles mid-session would be a
    /// dead end. Send the same `.reload` intent inline instead — this is the
    /// one place the tvOS UI deliberately does more than its iOS counterpart.
    func reloadIfConnected(_ profile: Profile) {
        guard isConnected else { return }
        ipcBridge.send(.reload, profileID: profile.id)
    }
}
