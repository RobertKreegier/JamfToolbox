import Foundation

/// What's still missing before the app can do its work.
public struct SetupStatus: Equatable {
    /// A Jamf Pro URL and both halves of the sign-in. Required.
    public let jamfReady: Bool
    /// A Meraki Dashboard API key. Optional: only the Wi-Fi lookups need it.
    public let merakiReady: Bool
    /// The user chose to go without Meraki.
    public let merakiSkipped: Bool
    /// Nothing has been set up yet (shown as a welcome).
    public var firstRun: Bool { !jamfReady && !merakiReady && !merakiSkipped }

    public init(jamfReady: Bool, merakiReady: Bool, merakiSkipped: Bool) {
        self.jamfReady = jamfReady
        self.merakiReady = merakiReady
        self.merakiSkipped = merakiSkipped
    }

    /// Worth showing the guide: Jamf Pro is missing, or Meraki is and hasn't been skipped.
    public var needsGuide: Bool { !jamfReady || (!merakiReady && !merakiSkipped) }
}

/// The guide's wording, shared by both apps.
public enum SetupGuideText {
    public static let jamfMissing = "Enter your Jamf Pro server's address and sign in with your own Jamf Pro "
        + "account, or an API client. Everything the app does runs with that account's Jamf Pro privileges."
    public static let jamfReady = "Your server and sign-in are set."

    public static func meraki(_ status: SetupStatus) -> String {
        if status.merakiReady { return "Your Dashboard API key is set." }
        if status.merakiSkipped { return "Skipped. Add a Dashboard API key in Settings any time." }
        return "If your Wi-Fi runs on Cisco Meraki, add a Dashboard API key to see which access point "
            + "a device last used. Everything else works without it."
    }
}

public enum SetupGuideChoice {
    case openSettings
    /// Don't ask about Meraki again.
    case skipMeraki
    case later
}

extension AppModel {
    public var setupStatus: SetupStatus {
        let prefs = settings.prefs
        let (a, b) = settings.credentials(for: prefs.authMethod)
        let jamf = !prefs.jamfURL.isEmpty && !a.isEmpty && !b.isEmpty
        return SetupStatus(jamfReady: jamf,
                           merakiReady: !settings.secret("meraki_api_key").isEmpty,
                           merakiSkipped: prefs.merakiSetupSkipped)
    }

    /// Explains what the app needs and offers to open Settings.
    public func showSetupGuide() async {
        let status = setupStatus
        switch await ui.setupGuide(status) {
        case .openSettings:
            openSettings()
        case .skipMeraki:
            settings.prefs.merakiSetupSkipped = true
            persist()
            log.add("Meraki setup skipped. Add an API key in Settings any time to see devices' Wi-Fi access points.")
            if !status.jamfReady { openSettings() }
        case .later:
            break
        }
    }
}
