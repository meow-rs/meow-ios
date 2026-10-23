import CoreImage.CIFilterBuiltins
import SwiftData
import SwiftUI

struct AddSubscriptionSheet: View {
    var initialURL = ""

    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Subscription")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("My Subscription"))
                TextField("URL", text: $url, prompt: Text("https://…"))
            }
            .formStyle(.columns)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(MacTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isAdding {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAdding || trimmedURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { url = initialURL }
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let target = trimmedURL
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isAdding = true
        errorMessage = nil
        Task {
            defer { isAdding = false }
            do {
                try SubscriptionService.rejectPlainHTTP(target)
                let profile = try await appModel.subscriptionService.add(
                    name: displayName.isEmpty ? (URL(string: target)?.host ?? "Subscription") : displayName,
                    url: target,
                )
                if controller.selectedProfile() == nil {
                    controller.select(profile)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ProfileInfoSheet: View {
    let profile: Profile

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var interval: ProfileUpdateInterval = .manual
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Info")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $url, prompt: Text("Empty for a local config"))
                Picker("Updates", selection: $interval) {
                    Text("Manually").tag(ProfileUpdateInterval.manual)
                    Text("Daily").tag(ProfileUpdateInterval.daily)
                    Text("Weekly").tag(ProfileUpdateInterval.weekly)
                }
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .formStyle(.columns)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(MacTheme.danger)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = profile.name
            url = profile.url
            interval = profile.updateInterval
        }
    }

    private func save() {
        do {
            try appModel.subscriptionService.updateInfo(profile, name: name, url: url, updateInterval: interval)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Plain-text YAML editor. Saving validates the config with the engine first
/// and hot-reloads a running engine that uses it.
struct YAMLEditorSheet: View {
    let profile: Profile

    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(profile.name)
                    .font(.title3.weight(.semibold))
                Spacer()
                if !profile.yamlBackup.isEmpty, profile.yamlBackup != profile.yamlContent {
                    Button("Revert to Previous") { text = profile.yamlBackup }
                }
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(MacTheme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MacTheme.cardBorder))
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(MacTheme.danger)
                    .textSelection(.enabled)
            }
            HStack {
                Text(profile.isSelected && controller.isConnected ? "Saving reloads the running engine." : " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(text == profile.yamlContent)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640)
        .onAppear { text = profile.yamlContent }
    }

    private func save() {
        do {
            try MeowConfigValidator.validate(text)
            try appModel.subscriptionService.updateContent(profile, yaml: text)
            if profile.isSelected, controller.isConnected {
                appModel.ipcBridge.send(.reload, profileID: profile.id)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct QRCodePopover: View {
    let payload: String

    var body: some View {
        VStack(spacing: 10) {
            if let image = Self.render(payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
            }
            Text("Scan with meow on iPhone or Apple TV")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    static func render(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// `meow://connect?url=…` confirmation, mirroring the iOS sheet.
struct DeepLinkImportSheet: View {
    let confirmation: DeepLinkImportConfirmation

    @Environment(AppModel.self) private var appModel
    @Environment(MacController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [Profile]
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(confirmation.isDuplicate ? "Update Subscription?" : "Add Subscription?")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(confirmation.name).font(.headline)
                Text(confirmation.subscriptionURL.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if confirmation.isInsecure {
                Label(
                    "This link uses plain HTTP; anyone on the network can read or change it.",
                    systemImage: "exclamationmark.triangle.fill",
                )
                .font(.callout)
                .foregroundStyle(MacTheme.warning)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(MacTheme.danger)
            }
            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if confirmation.requestsActivation {
                    Button(confirmation.isDuplicate ? "Update" : "Add") { resolve(.importOnly) }
                    Button(confirmation.isDuplicate ? "Update and Use" : "Add and Use") { resolve(.importAndActivate) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(confirmation.isDuplicate ? "Update" : "Add") { resolve(.importOnly) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(isWorking)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func resolve(_ action: DeepLinkConfirmationAction) {
        isWorking = true
        errorMessage = nil
        let existing = profiles.first { $0.id == confirmation.existingProfileID }
        Task {
            defer { isWorking = false }
            do {
                let coordinator = DeepLinkImportCoordinator(subscriptionService: appModel.subscriptionService)
                let profile = try await coordinator.resolve(confirmation, action: action, existingProfile: existing)
                if let profile, profile.isSelected, controller.isConnected {
                    appModel.ipcBridge.send(.reload, profileID: profile.id)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
