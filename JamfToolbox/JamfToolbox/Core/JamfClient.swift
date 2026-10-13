import Foundation

/// Minimal Jamf Pro API client covering the tasks this app performs.
///
/// Uses the classic API (JSON responses) for searches, device detail and a few
/// legacy commands, and the modern API for token auth and MDM commands
/// (device name, lock, Lost Mode, inventory).
actor JamfClient {
    nonisolated let baseURL: String
    private let authMethod: AuthMethod
    private let credentialA: String   // client ID, or username
    private let credentialB: String   // client secret, or password
    private let transport: HTTPTransport

    private var token: String?
    private var tokenExpiry: Date?
    private var tokenTask: Task<(String, Date), Error>?

    init(baseURL: String, authMethod: AuthMethod, credentialA: String, credentialB: String, tls: TLSPolicy) {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = trimmed
        self.authMethod = authMethod
        self.credentialA = credentialA
        self.credentialB = credentialB
        self.transport = HTTPTransport(policy: tls)
    }

    // MARK: Auth

    private func fetchToken() async throws -> (String, Date) {
        var request: URLRequest
        switch authMethod {
        case .oauth:
            guard let url = URL(string: "\(baseURL)/api/oauth/token") else { throw ServiceError("The Jamf Pro URL is not valid.") }
            request = URLRequest(url: url)
            // Hand-encoded: URLComponents leaves "+" alone in values, which a
            // form parser would read as a space and corrupt the client secret.
            var unreserved = CharacterSet.alphanumerics
            unreserved.insert(charactersIn: "-._~")
            func encode(_ value: String) -> String {
                value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            }
            let form = [("grant_type", "client_credentials"), ("client_id", credentialA), ("client_secret", credentialB)]
                .map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
            request.httpBody = Data(form.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case .basic:
            guard let url = URL(string: "\(baseURL)/api/v1/auth/token") else { throw ServiceError("The Jamf Pro URL is not valid.") }
            request = URLRequest(url: url)
            request.httpBody = Data()
            let basic = Data("\(credentialA):\(credentialB)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let result: HTTPResult
        do {
            result = try await transport.send(request)
        } catch {
            throw HTTPTransport.explain(error, host: baseURL)
        }
        guard (200..<300).contains(result.status) else {
            if result.status == 401 {
                throw ServiceError("Authentication failed (401). Check your credentials in Settings.")
            }
            throw ServiceError("Token request failed: HTTP \(result.status)")
        }

        let payload = (try? JSONValue.parse(result.data)) ?? .emptyObject
        let tokenText = payload["access_token"]?.text ?? ""
        let fallbackToken = payload["token"]?.text ?? ""
        let value = tokenText.isEmpty ? fallbackToken : tokenText
        guard !value.isEmpty else { throw ServiceError("Jamf Pro did not return a token.") }

        // Refresh a minute early so a token never expires mid-request.
        let expiry: Date
        if let ttl = payload["expires_in"]?.text, let seconds = Double(ttl), seconds > 0 {
            expiry = Date().addingTimeInterval(seconds - 60)
        } else if let expires = payload["expires"]?.text, let date = parseISO8601(expires) {
            expiry = date.addingTimeInterval(-60)
        } else {
            expiry = Date().addingTimeInterval(15 * 60)
        }
        return (value, expiry)
    }

    private func currentToken() async throws -> String {
        if let token, let tokenExpiry, Date() < tokenExpiry { return token }
        if let tokenTask { return try await tokenTask.value.0 }
        let task = Task { try await self.fetchToken() }
        tokenTask = task
        defer { tokenTask = nil }
        let (fresh, expiry) = try await task.value
        token = fresh
        tokenExpiry = expiry
        return fresh
    }

    func testConnection() async throws {
        token = nil
        tokenExpiry = nil
        _ = try await currentToken()
    }

    // MARK: Requests

    /// Sends an authenticated request and returns the parsed JSON response
    /// (an empty object when the body is empty or unreadable).
    @discardableResult
    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         contentType: String? = nil) async throws -> JSONValue {
        let bearer = try await currentToken()
        guard let url = URL(string: "\(baseURL)\(path)") else { throw ServiceError("Invalid request URL: \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 45
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let result: HTTPResult
        do {
            result = try await transport.send(request)
        } catch {
            throw HTTPTransport.explain(error, host: baseURL)
        }
        switch result.status {
        case 200..<300:
            break
        case 401:
            // The token may have been revoked mid-session; the next call fetches a new one.
            token = nil
            tokenExpiry = nil
            throw ServiceError("Session expired or unauthorized (401). Try again.")
        case 403:
            throw ServiceError("Permission denied (403). The API account lacks a required privilege.",
                               isPermissionDenied: true)
        case 404:
            throw ServiceError("Not found (404): \(path)", isNotFound: true)
        default:
            let detail = String(decoding: result.data.prefix(300), as: UTF8.self)
            throw ServiceError("HTTP \(result.status) on \(method) \(path). \(detail)")
        }
        guard !result.data.isEmpty else { return .emptyObject }
        return (try? JSONValue.parse(result.data)) ?? .emptyObject
    }

    // MARK: Searches & detail

    private static func matchPattern(_ query: String) -> String {
        URLEncoding.quote(query.isEmpty ? "*" : "*\(query)*")
    }

    func searchComputers(_ query: String) async throws -> [JSONValue] {
        let data = try await request("/JSSResource/computers/match/\(Self.matchPattern(query))")
        return data["computers"]?.arrayValue ?? []
    }

    func searchMobileDevices(_ query: String) async throws -> [JSONValue] {
        let data = try await request("/JSSResource/mobiledevices/match/\(Self.matchPattern(query))")
        return data["mobile_devices"]?.arrayValue ?? []
    }

    func record(for type: DeviceType, id: String) async throws -> JSONValue {
        guard let numeric = Int(id) else { throw ServiceError("Invalid device ID: \(id)") }
        switch type {
        case .computer:
            return try await request("/JSSResource/computers/id/\(numeric)")["computer"] ?? .emptyObject
        case .mobile:
            return try await request("/JSSResource/mobiledevices/id/\(numeric)")["mobile_device"] ?? .emptyObject
        }
    }

    // MARK: Mobile device commands

    private func mobileCommand(_ command: String, id: String, extraXML: String = "") async throws {
        let numeric = try numericID(id)
        let xml = "<mobile_device_command><general><command>\(command)</command>\(extraXML)"
            + "</general><mobile_devices><mobile_device><id>\(numeric)</id>"
            + "</mobile_device></mobile_devices></mobile_device_command>"
        try await request("/JSSResource/mobiledevicecommands/command", method: "POST",
                          body: Data(xml.utf8), contentType: "text/xml")
    }

    private func numericID(_ id: String) throws -> Int {
        guard let value = Int(id) else { throw ServiceError("Invalid device ID: \(id)") }
        return value
    }

    private func mdmCommand(managementID: String, _ commandData: [String: String]) async throws {
        let payload: [String: Any] = [
            "commandData": commandData,
            "clientData": [["managementId": managementID]],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        try await request("/api/v2/mdm/commands", method: "POST", body: body, contentType: "application/json")
    }

    private func mobileMDMCommand(id: String, _ commandData: [String: String]) async throws {
        let management = try await mobileManagementID(id)
        guard !management.isEmpty else {
            throw ServiceError("Could not find this device's management ID, which is required to send MDM commands. "
                               + "The device may not be fully enrolled/supervised.")
        }
        try await mdmCommand(managementID: management, commandData)
    }

    /// Resolve a mobile device's managementId, tolerating the shapes different Jamf versions return.
    private func mobileManagementID(_ id: String) async throws -> String {
        let numeric = try numericID(id)
        let detail = try await request("/api/v2/mobile-devices/\(numeric)/detail")
        if let management = detail["managementId"]?.text, !management.isEmpty { return management }
        if let management = detail["general"]?["managementId"]?.text, !management.isEmpty { return management }
        // Fallback: the list endpoint can also carry it.
        if let listing = try? await request("/api/v2/mobile-devices?page=0&page-size=1&filter=id==\(numeric)"),
           let first = listing["results"]?.arrayValue?.first,
           let management = first["managementId"]?.text, !management.isEmpty {
            return management
        }
        return ""
    }

    /// Enable Lost Mode. Tries the classic EnableLostMode command first (it supports
    /// the sound option); if the server rejects it, falls back to the modern
    /// ENABLE_LOST_MODE MDM command.
    func enableLostMode(id: String, message: String, phone: String, footnote: String,
                        playSound: Bool) async throws -> String {
        let extra = "<lost_mode_message>\(XMLEscape.text(message))</lost_mode_message>"
            + "<lost_mode_phone>\(XMLEscape.text(phone))</lost_mode_phone>"
            + "<lost_mode_footnote>\(XMLEscape.text(footnote))</lost_mode_footnote>"
            + "<lost_mode_with_sound>\(playSound ? "true" : "false")</lost_mode_with_sound>"
            + "<always_enforce_lost_mode>true</always_enforce_lost_mode>"
        do {
            try await mobileCommand("EnableLostMode", id: id, extraXML: extra)
            return "Enable Lost Mode command queued."
        } catch is ServiceError {
            // Newer servers drop the classic command. The sound is a separate
            // PLAY_LOST_MODE_SOUND command, sent once Lost Mode is on.
            try await mobileMDMCommand(id: id, [
                "commandType": "ENABLE_LOST_MODE",
                "lostModeMessage": message,
                "lostModePhone": phone,
                "lostModeFootnote": footnote,
            ])
            var note = "Enable Lost Mode command queued."
            if playSound {
                do {
                    try await mobileMDMCommand(id: id, ["commandType": "PLAY_LOST_MODE_SOUND"])
                    note += " Lost Mode sound requested."
                } catch let error as ServiceError {
                    note += " Lost Mode is on, but the sound command failed: \(error.message)"
                }
            }
            return note
        }
    }

    /// The classic DisableLostMode command returns HTTP 400 on current Jamf Pro
    /// versions; DISABLE_LOST_MODE on the MDM commands endpoint is the supported route.
    func disableLostMode(id: String) async throws -> String {
        try await mobileMDMCommand(id: id, ["commandType": "DISABLE_LOST_MODE"])
        return "Disable Lost Mode command queued via MDM."
    }

    /// The classic DeviceName command returns HTTP 400 on current Jamf Pro
    /// versions, so use a SETTINGS MDM command. The name travels in a JSON
    /// body, so any characters (spaces included) are fine.
    func renameMobileDevice(id: String, newName: String) async throws -> String {
        try await mobileMDMCommand(id: id, ["commandType": "SETTINGS", "deviceName": newName])
        return "Set Device Name command queued via MDM."
    }

    func updateInventoryMobile(id: String) async throws -> String {
        do {
            try await mobileMDMCommand(id: id, ["commandType": "DEVICE_INFORMATION"])
            return "Update Inventory command queued."
        } catch is ServiceError {
            try await mobileCommand("UpdateInventory", id: id)
            return "Update Inventory command queued (classic)."
        }
    }

    /// Mobile devices lock with their existing passcode (Apple MDM behavior), so no PIN.
    func lockMobileDevice(id: String, message: String = "", phone: String = "") async throws -> String {
        var command = ["commandType": "DEVICE_LOCK"]
        if !message.isEmpty { command["message"] = message }
        if !phone.isEmpty { command["phoneNumber"] = phone }
        do {
            try await mobileMDMCommand(id: id, command)
            return "Lock Device command queued."
        } catch is ServiceError {
            try await mobileCommand("DeviceLock", id: id)
            return "Lock Device command queued (classic)."
        }
    }

    // MARK: Computer commands

    private func computerCommand(_ command: String, id: String, extraXML: String = "") async throws {
        let numeric = try numericID(id)
        let xml = "<computer_command><general><command>\(command)</command>\(extraXML)"
            + "</general><computers><computer><id>\(numeric)</id>"
            + "</computer></computers></computer_command>"
        try await request("/JSSResource/computercommands/command", method: "POST",
                          body: Data(xml.utf8), contentType: "text/xml")
    }

    private func computerManagementID(_ id: String) async throws -> String {
        let numeric = try numericID(id)
        let detail = try await request("/api/v1/computers-inventory-detail/\(numeric)")
        if let management = detail["general"]?["managementId"]?.text, !management.isEmpty { return management }
        return detail["managementId"]?.text ?? ""
    }

    private func computerMDMCommand(id: String, _ commandData: [String: String]) async throws {
        let management = try await computerManagementID(id)
        guard !management.isEmpty else {
            throw ServiceError("Could not find this computer's management ID, which is required to send MDM commands.")
        }
        try await mdmCommand(managementID: management, commandData)
    }

    /// Lock a Mac with a 6-digit recovery PIN. Modern DEVICE_LOCK first (carrying
    /// the PIN), classic as a fallback for older servers.
    func lockComputer(id: String, passcode: String, message: String = "") async throws -> String {
        var command = ["commandType": "DEVICE_LOCK", "pin": passcode]
        if !message.isEmpty { command["message"] = message }
        do {
            try await computerMDMCommand(id: id, command)
            return "Lock Device command queued."
        } catch is ServiceError {
            var extra = "<passcode>\(XMLEscape.text(passcode))</passcode>"
            if !message.isEmpty { extra += "<lock_message>\(XMLEscape.text(message))</lock_message>" }
            try await computerCommand("DeviceLock", id: id, extraXML: extra)
            return "Lock Device command queued (classic)."
        }
    }

    /// Update the inventory record name, then send the SETTINGS MDM command so the
    /// change reaches the Mac itself. (The command type is SETTINGS, not
    /// SET_COMPUTER_NAME; the latter is rejected as unknown.)
    func renameComputer(id: String, newName: String) async throws -> String {
        let numeric = try numericID(id)
        let xml = "<computer><general><name>\(XMLEscape.text(newName))</name></general></computer>"
        try await request("/JSSResource/computers/id/\(numeric)", method: "PUT",
                          body: Data(xml.utf8), contentType: "text/xml")
        do {
            try await computerMDMCommand(id: id, ["commandType": "SETTINGS", "deviceName": newName])
            return "Name updated and Set Computer Name command queued via MDM."
        } catch let error as ServiceError {
            return "Name updated in Jamf Pro, but the push-to-device command failed: \(error.message). "
                + "It will reconcile on the Mac's next inventory update."
        }
    }

    // MARK: Advanced commands

    private func deviceMDM(_ type: DeviceType, id: String, _ commandData: [String: String]) async throws {
        switch type {
        case .computer: try await computerMDMCommand(id: id, commandData)
        case .mobile: try await mobileMDMCommand(id: id, commandData)
        }
    }

    /// Restarts immediately. Mobile devices must be supervised.
    func restartDevice(type: DeviceType, id: String) async throws -> String {
        try await deviceMDM(type, id: id, ["commandType": "RESTART_DEVICE"])
        return "Restart command queued."
    }

    /// A shut-down device can't be powered back on remotely. Mobile devices must be supervised.
    func shutDownDevice(type: DeviceType, id: String) async throws -> String {
        try await deviceMDM(type, id: id, ["commandType": "SHUT_DOWN_DEVICE"])
        return "Shut Down command queued."
    }

    /// Clears the Screen Time (restrictions) passcode. Supervised mobile devices only.
    func clearScreenTimePasscode(id: String) async throws -> String {
        try await mobileMDMCommand(id: id, ["commandType": "CLEAR_RESTRICTIONS_PASSWORD"])
        return "Clear Screen Time Passcode command queued."
    }

    /// The modern command needs the device's unlock token; when the server
    /// doesn't expose one, fall back to the classic ClearPasscode command.
    func clearPasscode(id: String) async throws -> String {
        let token = try await mobileUnlockToken(id)
        if !token.isEmpty {
            do {
                try await mobileMDMCommand(id: id, ["commandType": "CLEAR_PASSCODE", "unlockToken": token])
                return "Clear Passcode command queued."
            } catch let error as ServiceError where !error.isPermissionDenied {
                // fall through to the classic command
            }
        }
        try await mobileCommand("ClearPasscode", id: id)
        return "Clear Passcode command queued (classic)."
    }

    private func mobileUnlockToken(_ id: String) async throws -> String {
        let numeric = try numericID(id)
        for path in ["/api/v2/mobile-devices/\(numeric)/detail", "/api/v2/mobile-devices/\(numeric)"] {
            guard let detail = try? await request(path) else { continue }
            for candidate in [detail["unlockToken"], detail["security"]?["unlockToken"], detail["general"]?["unlockToken"]] {
                if let token = candidate?.text, !token.isEmpty { return token }
            }
        }
        return ""
    }

    /// Wakes the device so it checks in. Blank push has its own endpoint (it is
    /// not an MDM command type); the classic command is the fallback.
    func blankPush(type: DeviceType, id: String) async throws -> String {
        let management: String
        if type == .computer {
            management = try await computerManagementID(id)
        } else {
            management = try await mobileManagementID(id)
        }
        if !management.isEmpty {
            do {
                let body = try JSONSerialization.data(withJSONObject: ["clientManagementIds": [management]])
                let response = try await request("/api/v2/mdm/blank-push", method: "POST",
                                                 body: body, contentType: "application/json")
                if let failed = response["errorUuids"]?.arrayValue, !failed.isEmpty {
                    throw ServiceError("Jamf Pro reported an error sending the blank push to this device.")
                }
                return "Blank push queued."
            } catch let error as ServiceError where !error.isPermissionDenied {
                // fall through to the classic command
            }
        }
        let numeric = try numericID(id)
        let resource = type == .computer ? "computercommands" : "mobiledevicecommands"
        try await request("/JSSResource/\(resource)/command/BlankPush/id/\(numeric)", method: "POST")
        return "Blank push queued (classic)."
    }

    /// Erases the device. Computers require a 6-digit PIN. There is deliberately
    /// no second route: retrying a destructive command after an ambiguous
    /// failure could send it twice.
    func eraseDevice(type: DeviceType, id: String, pin: String = "") async throws -> String {
        var data = ["commandType": "ERASE_DEVICE"]
        if type == .computer { data["pin"] = pin }
        try await deviceMDM(type, id: id, data)
        return "Wipe command queued."
    }

    /// Removes the device record from Jamf Pro (the device itself is untouched).
    func deleteDevice(type: DeviceType, id: String) async throws -> String {
        let numeric = try numericID(id)
        let classic = type == .computer ? "/JSSResource/computers/id/\(numeric)"
                                        : "/JSSResource/mobiledevices/id/\(numeric)"
        do {
            try await request(classic, method: "DELETE")
        } catch let error as ServiceError where !error.isPermissionDenied && !error.isNotFound {
            let modern = type == .computer ? "/api/v1/computers-inventory/\(numeric)"
                                           : "/api/v2/mobile-devices/\(numeric)"
            try await request(modern, method: "DELETE")
        }
        return "Device record deleted from Jamf Pro."
    }

    // MARK: Misc

    nonisolated func deviceWebURL(type: DeviceType, id: String) -> URL? {
        let page = type == .computer ? "computers.html" : "mobileDevices.html"
        return URL(string: "\(baseURL)/\(page)?id=\(id)&o=r")
    }
}
