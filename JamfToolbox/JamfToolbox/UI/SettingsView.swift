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
    var lostModeMessage = ""
    var lostModePhone = ""
    var lostModeFootnote = ""
    var lostModeSound = true
    var renameComputer = ""
    var renameMobile = ""
    var lockMessage = ""
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
        lostModeMessage = p.lostModeMessage
        lostModePhone = p.lostModePhone
        lostModeFootnote = p.lostModeFootnote
        lostModeSound = p.lostModeSound
        renameComputer = p.renameFormatComputer
        renameMobile = p.renameFormatMobile
        lockMessage = p.lockMessage
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
            Section("Lost Mode") {
                messageEditor("Message", text: $draft.lostModeMessage, height: 56)
                TextField("Phone", text: $draft.lostModePhone)
                TextField("Footnote", text: $draft.lostModeFootnote)
                Toggle("Play a sound when Lost Mode is enabled", isOn: $draft.lostModeSound)
            }
            Section("Rename") {
                TextField("Computers", text: $draft.renameComputer)
                TextField("Mobile devices", text: $draft.renameMobile)
                Text("For example {username}-{model_short}-{serial_last4}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Lock") {
                messageEditor("Message", text: $draft.lockMessage, height: 56)
            }
            Section {
                Text("Templates accept {tags}. Choose Jamf Toolbox Help from the Help menu for the full list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        p.lostModeMessage = draft.lostModeMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        p.lostModePhone = draft.lostModePhone.trimmingCharacters(in: .whitespaces)
        p.lostModeFootnote = draft.lostModeFootnote.trimmingCharacters(in: .whitespaces)
        p.lostModeSound = draft.lostModeSound
        p.renameFormatComputer = draft.renameComputer.trimmingCharacters(in: .whitespaces)
        p.renameFormatMobile = draft.renameMobile.trimmingCharacters(in: .whitespaces)
        p.lockMessage = draft.lockMessage.trimmingCharacters(in: .whitespacesAndNewlines)
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
