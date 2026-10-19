import Foundation

/// What's still missing before the app can do its work.
public struct SetupStatus: Equatable {
    /// A Jamf Pro URL and both halves of the sign-in. Required.
    public let jamfReady: Bool
    /// A Meraki Dashboard API key. Optional: only the network features need it,
    /// and they stay hidden without one, so the guide never asks for it alone.
    public let merakiReady: Bool
    /// Nothing has been set up yet (shown as a welcome).
    public var firstRun: Bool { !jamfReady && !merakiReady }

    public init(jamfReady: Bool, merakiReady: Bool) {
        self.jamfReady = jamfReady
        self.merakiReady = merakiReady
    }

    /// Worth showing the guide: the app can't do anything without Jamf Pro.
    public var needsGuide: Bool { !jamfReady }
}

/// The guide's wording, shared by both apps.
public enum SetupGuideText {
    public static let jamfMissing = "Enter your Jamf Pro server's address and sign in with your own Jamf Pro "
        + "account, or an API client. Everything the app does runs with that account's Jamf Pro privileges."
    public static let jamfReady = "Your server and sign-in are set."

    public static func meraki(_ status: SetupStatus) -> String {
        if status.merakiReady { return "Your Dashboard API key is set." }
        return "If your Wi-Fi runs on Cisco Meraki, add a Dashboard API key in Settings to see which "
            + "access point a device last used. Network features stay hidden until then."
    }
}

public enum SetupGuideChoice {
    case openSettings
    case later
}

extension AppModel {
    public var setupStatus: SetupStatus {
        let prefs = settings.prefs
        let (a, b) = settings.credentials(for: prefs.authMethod)
        let jamf = !prefs.jamfURL.isEmpty && !a.isEmpty && !b.isEmpty
        return SetupStatus(jamfReady: jamf, merakiReady: !settings.secret("meraki_api_key").isEmpty)
    }

    /// Explains what the app needs and offers to open Settings.
    public func showSetupGuide() async {
        switch await ui.setupGuide(setupStatus) {
        case .openSettings: openSettings()
        case .later: break
        }
    }
}
