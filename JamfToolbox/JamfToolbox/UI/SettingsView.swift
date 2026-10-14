import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything the Settings window edits. Changes stay in this draft until Save,
/// so Cancel (or just closing the window) discards them and credentials only
/// reach the Keychain when the user commits.
struct SettingsDraft: Equatable {
    var jamfURL = ""
    var authMethod = AuthMethod.basic
    var oauthID = ""
    var oauthSecret = ""
    var basicUser = ""
    var basicPassword = ""
    var verifyNotes = true
    var doubleClickAction = DeviceAction.openInJamf
    var sslVerify = true
    var caBundle = ""
    var lostModePresets: [LostModePreset] = Preferences().lostModePresets
    var lostModeSound = true
    var namePresets: [NamePreset] = Preferences().namePresets
    var lockPresets: [LockPreset] = Preferences().lockPresets
    var merakiKey = ""

    @MainActor
    init(settings: SettingsStore) {
        let p = settings.prefs
        jamfURL = p.jamfURL
        authMethod = p.authMethod
        oauthID = settings.secret("client_id")
        oauthSecret = settings.secret("client_secret")
        basicUser = settings.secret("username")
        basicPassword = settings.secret("password")
        verifyNotes = p.verifyNotes
        doubleClickAction = p.doubleClickAction
        sslVerify = p.sslVerify
        caBundle = p.sslCABundle
        lostModePresets = p.lostModePresets
        lostModeSound = p.lostModeSound
        namePresets = p.namePresets
        lockPresets = p.lockPresets
        merakiKey = settings.secret("meraki_api_key")
    }

    init() {}

    var credentials: (String, String) {
        authMethod == .oauth ? (oauthID, oauthSecret) : (basicUser, basicPassword)
    }
}

@MainActor
enum SettingsWindow {
    private static weak var current: NSWindow?

    static func show(model: AppModel) {
        if let current, current.isVisible {
            current.makeKeyAndOrderFront(nil)
            return
        }
        current = Windows.show(title: "Settings", size: CGSize(width: 580, height: 690), resizable: false) {
            SettingsView(model: model)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    enum Pane: String, CaseIterable, Identifiable {
        case connection = "Connection", templates = "Templates", meraki = "Meraki"
        var id: String { rawValue }
    }

    @State private var pane: Pane

    init(model: AppModel, pane: Pane = .connection) {
        self.model = model
        _pane = State(initialValue: pane)
    }

    @State private var draft = SettingsDraft()
    @State private var loaded = SettingsDraft()
    @State private var window: NSWindow?
    @State private var testing = false
    @State private var lostSelection: UUID?
    @State private var lockSelection: UUID?
    @State private var nameSelection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)

            Group {
                switch pane {
                case .connection: connectionPane
                case .templates: templatesPane
                case .meraki: merakiPane
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 580, height: 690)
        .background(WindowReader { window = $0 })
        .onAppear { reset() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // Closing the window abandons unsaved edits.
            if let window, (note.object as? NSWindow) === window { reset() }
        }
    }

    private func reset() {
        let fresh = SettingsDraft(settings: model.settings)
        draft = fresh
        loaded = fresh
        lostSelection = fresh.lostModePresets.first?.id
        lockSelection = fresh.lockPresets.first?.id
        nameSelection = fresh.namePresets.first?.id
    }

    // MARK: Panes

    private var connectionPane: some View {
        Form {
            Section("Jamf Pro") {
                TextField("Server URL", text: $draft.jamfURL, prompt: Text("https://yourorg.jamfcloud.com"))
                Picker("Authentication", selection: $draft.authMethod) {
                    Text("API client (recommended)").tag(AuthMethod.oauth)
                    Text("User account").tag(AuthMethod.basic)
                }
                .pickerStyle(.segmented)
                if draft.authMethod == .oauth {
                    TextField("Client ID", text: $draft.oauthID)
                    SecureField("Client secret", text: $draft.oauthSecret)
                } else {
                    TextField("Username", text: $draft.basicUser)
                    SecureField("Password", text: $draft.basicPassword)
                }
            }

            Section("Behavior") {
                Toggle("Preview and confirm before sending any command", isOn: $draft.verifyNotes)
                Picker("Double-click action", selection: $draft.doubleClickAction) {
                    ForEach(DeviceAction.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Toggle("Verify SSL certificates (recommended)", isOn: $draft.sslVerify)
                HStack {
                    TextField("CA bundle", text: $draft.caBundle, prompt: Text("Optional .pem file"))
                    Button("Choose…") { chooseCABundle() }
                }
                if draft.sslVerify {
                    Text("Only needed if your server's certificate comes from an internal CA. "
                         + "These certificates are trusted in addition to the ones macOS already trusts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("With verification off, credentials could be exposed to anyone intercepting traffic "
                          + "to the server. Prefer a CA bundle.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Security")
            }
        }
    }

    private var templatesPane: some View {
        Form {
            Section {
                presetControls(names: draft.lostModePresets.map(\.name), ids: draft.lostModePresets.map(\.id),
                               selection: $lostSelection,
                               add: {
                                   let new = LostModePreset(name: "New Message", message: "", footnote: draft.lostModePresets[0].footnote)
                                   draft.lostModePresets.append(new)
                                   lostSelection = new.id
                               },
                               remove: { index in draft.lostModePresets.remove(at: index); lostSelection = draft.lostModePresets.first?.id },
                               makeDefault: { index in draft.lostModePresets.insert(draft.lostModePresets.remove(at: index), at: 0) })
                let i = index(of: lostSelection, in: draft.lostModePresets.map(\.id))
                TextField("Name", text: $draft.lostModePresets[i].name)
                messageEditor("Message", text: $draft.lostModePresets[i].message, height: 56)
                TextField("Phone", text: $draft.lostModePresets[i].phone)
                TextField("Footnote", text: $draft.lostModePresets[i].footnote)
                Toggle("Play a sound when Lost Mode is enabled", isOn: $draft.lostModeSound)
            } header: {
                Text("Lost Mode Messages")
            } footer: {
                Text("The default message is used when previews are off. Otherwise you choose one when enabling Lost Mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                presetControls(names: draft.lockPresets.map(\.name), ids: draft.lockPresets.map(\.id),
                               selection: $lockSelection,
                               add: {
                                   let new = LockPreset(name: "New Message", message: "")
                                   draft.lockPresets.append(new)
                                   lockSelection = new.id
                               },
                               remove: { index in draft.lockPresets.remove(at: index); lockSelection = draft.lockPresets.first?.id },
                               makeDefault: { index in draft.lockPresets.insert(draft.lockPresets.remove(at: index), at: 0) })
                let i = index(of: lockSelection, in: draft.lockPresets.map(\.id))
                TextField("Name", text: $draft.lockPresets[i].name)
                messageEditor("Message", text: $draft.lockPresets[i].message, height: 56)
            } header: {
                Text("Lock Messages")
            } footer: {
                Text("Shown on the lock screen of locked Macs and mobile devices. You choose one when locking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                presetControls(names: draft.namePresets.map(\.name), ids: draft.namePresets.map(\.id),
                               selection: $nameSelection,
                               add: {
                                   let new = NamePreset(name: "New Format", template: "")
                                   draft.namePresets.append(new)
                                   nameSelection = new.id
                               },
                               remove: { index in draft.namePresets.remove(at: index); nameSelection = draft.namePresets.first?.id },
                               makeDefault: { index in draft.namePresets.insert(draft.namePresets.remove(at: index), at: 0) })
                let i = index(of: nameSelection, in: draft.namePresets.map(\.id))
                TextField("Name", text: $draft.namePresets[i].name)
                TextField("Format", text: $draft.namePresets[i].template, prompt: Text("{realname} - {username} - {serial}"))
            } header: {
                Text("Device Names")
            } footer: {
                Text("Used by Rename for computers and mobile devices alike. For example {username}-{model_short}-{serial_last4}.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Templates accept {tags}. Choose Jamf Toolbox Help from the Help menu for the full list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The selected preset's position (the first preset when nothing valid is selected).
    private func index(of id: UUID?, in ids: [UUID]) -> Int {
        id.flatMap { ids.firstIndex(of: $0) } ?? 0
    }

    /// Picker of saved presets with Add, Delete and Make Default.
    private func presetControls(names: [String], ids: [UUID], selection: Binding<UUID?>,
                                add: @escaping () -> Void, remove: @escaping (Int) -> Void,
                                makeDefault: @escaping (Int) -> Void) -> some View {
        let current = index(of: selection.wrappedValue, in: ids)
        return HStack {
            Picker("Preset", selection: Binding(get: { ids.indices.contains(current) ? ids[current] : nil },
                                                 set: { selection.wrappedValue = $0 })) {
                ForEach(ids.indices, id: \.self) { i in
                    Text((names[i].isEmpty ? "Untitled" : names[i]) + (i == 0 ? " (default)" : "")).tag(Optional(ids[i]))
                }
            }
            Button(action: add) { Image(systemName: "plus") }
                .help("Add a message")
            Button { remove(current) } label: { Image(systemName: "minus") }
                .help("Delete this message")
                .disabled(ids.count <= 1)
            Button("Make Default") { makeDefault(current) }
                .disabled(current == 0)
        }
    }

    /// A multi-line field with its label above it, so the text stays left-aligned
    /// and uses the full width (a trailing-aligned `LabeledContent` would not).
    private func messageEditor(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            TextEditor(text: text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private var merakiPane: some View {
        Form {
            Section("Dashboard API") {
                SecureField("API key", text: $draft.merakiKey)
                Text("Generate one in the Meraki Dashboard under your profile (My profile > API access). "
                     + "It is stored in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Organization") {
                let name = model.settings.prefs.merakiOrgName
                LabeledContent("Remembered") {
                    HStack {
                        Text(name.isEmpty ? "Chosen automatically on first use" : name)
                            .foregroundStyle(name.isEmpty ? .secondary : .primary)
                        if !name.isEmpty {
                            Button("Forget") {
                                model.settings.prefs.merakiOrgID = ""
                                model.settings.prefs.merakiOrgName = ""
                                model.persist()
                            }
                        }
                    }
                }
                Text("Lookups search your whole organization, so no network needs to be picked. If your key "
                     + "sees several organizations, you'll be asked once and the choice is remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Test Connection") { testConnection() }
                .disabled(testing)
            if testing { ProgressView().controlSize(.small) }
            if !model.settings.keychainAvailable {
                Label("Keychain unavailable — secrets stored in settings file", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel") { window?.performClose(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func chooseCABundle() {
        let panel = NSOpenPanel()
        panel.title = "Choose CA bundle"
        panel.allowedContentTypes = ["pem", "crt", "cer"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { draft.caBundle = url.path }
    }

    private func testConnection() {
        let url = draft.jamfURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            Task { await Dialogs.info("Enter the Jamf Pro server URL first.") }
            return
        }
        let (a, b) = draft.credentials
        let client = JamfClient(baseURL: url, authMethod: draft.authMethod,
                                credentialA: a.trimmingCharacters(in: .whitespacesAndNewlines), credentialB: b,
                                tls: TLSPolicy(verify: draft.sslVerify,
                                               caBundlePath: draft.caBundle.trimmingCharacters(in: .whitespaces)))
        testing = true
        Task {
            defer { testing = false }
            do {
                try await client.testConnection()
                await Dialogs.info("Connection successful — a token was issued.")
            } catch {
                await Dialogs.error(model.describe(error))
            }
        }
    }

    private func save() {
        let url = draft.jamfURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.isEmpty || url.lowercased().hasPrefix("https://") else {
            Task { await Dialogs.warning("The Jamf Pro URL should start with https://") }
            return
        }
        let settings = model.settings
        var p = settings.prefs
        var trimmedURL = url
        while trimmedURL.hasSuffix("/") { trimmedURL.removeLast() }
        p.jamfURL = trimmedURL
        p.authMethod = draft.authMethod
        p.verifyNotes = draft.verifyNotes
        p.doubleClickAction = draft.doubleClickAction
        p.sslVerify = draft.sslVerify
        p.sslCABundle = draft.caBundle.trimmingCharacters(in: .whitespaces)
        func cleanName(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled" : trimmed
        }
        p.lostModePresets = draft.lostModePresets.map { preset in
            var clean = preset
            clean.name = cleanName(preset.name)
            clean.message = preset.message.trimmingCharacters(in: .whitespacesAndNewlines)
            clean.phone = preset.phone.trimmingCharacters(in: .whitespaces)
            clean.footnote = preset.footnote.trimmingCharacters(in: .whitespaces)
            return clean
        }
        p.lostModeSound = draft.lostModeSound
        p.namePresets = draft.namePresets.map { preset in
            var clean = preset
            clean.name = cleanName(preset.name)
            clean.template = preset.template.trimmingCharacters(in: .whitespaces)
            return clean
        }
        p.lockPresets = draft.lockPresets.map { preset in
            var clean = preset
            clean.name = cleanName(preset.name)
            clean.message = preset.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean
        }
        settings.prefs = p

        // Only touch the Keychain for secrets the user actually changed.
        func store(_ account: String, _ new: String, _ old: String, trim: Bool = false) {
            let value = trim ? new.trimmingCharacters(in: .whitespacesAndNewlines) : new
            if value != old { settings.setSecret(account, value) }
        }
        store("client_id", draft.oauthID, loaded.oauthID, trim: true)
        store("client_secret", draft.oauthSecret, loaded.oauthSecret)
        store("username", draft.basicUser, loaded.basicUser, trim: true)
        store("password", draft.basicPassword, loaded.basicPassword)
        store("meraki_api_key", draft.merakiKey, loaded.merakiKey, trim: true)

        model.persist()
        model.settingsSaved()
        window?.performClose(nil)
    }
}

/// Captures the `NSWindow` hosting a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}

#if DEBUG
#Preview("Connection") { SettingsView(model: PreviewData.model(), pane: .connection) }
#Preview("Templates") { SettingsView(model: PreviewData.model(), pane: .templates) }
#Preview("Meraki") { SettingsView(model: PreviewData.model(), pane: .meraki) }
#endif
