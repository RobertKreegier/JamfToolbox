import Foundation

/// A device's current state, read for a summary view (the iOS info card).
public struct DeviceSnapshot {
    public let device: DeviceRef
    public let record: JSONValue
    /// The record flattened to list fields.
    public let entry: DeviceEntry
    /// Mobile devices only; nil when Jamf Pro doesn't say.
    public let lostMode: Bool?
}

/// Where Meraki last saw a device.
public struct MerakiSighting {
    public let apName: String
    public let apMAC: String
    public let ssid: String
    public let networkName: String
    public let lastSeen: Date?
    /// Meraki's full client record.
    public let client: JSONValue
}

public enum LocateOutcome {
    case found(MerakiSighting)
    /// Meraki has no client with this MAC anywhere in the organization.
    case notFound
    /// Jamf Pro has no Wi-Fi MAC for the device.
    case noMAC
    /// No Meraki API key in Settings.
    case notConfigured
    /// The key sees several organizations and none has been chosen yet.
    case needsOrg
}

/// Quiet reads for summary views: no prompts, errors are thrown to the caller.
extension AppModel {
    /// Reads the device's record and refreshes its row in the working list.
    public func loadSnapshot(_ device: DeviceRef) async throws -> DeviceSnapshot {
        guard let client else { throw ServiceError("Add your Jamf Pro URL and credentials in Settings first.") }
        let record = try await client.record(for: device.type, id: device.id)
        let entry = Templates.entry(from: record, type: device.type, deviceID: device.id)
        updateListEntry(type: device.type, id: device.id, fields: entry.fields)
        let lostMode = device.type == .mobile ? Templates.lostModeEnabled(in: record) : nil
        return DeviceSnapshot(device: device, record: record, entry: entry, lostMode: lostMode)
    }

    /// Looks a MAC up across the remembered Meraki organization.
    public func locate(mac: String) async throws -> LocateOutcome {
        guard !mac.isEmpty else { return .noMAC }
        let key = settings.secret("meraki_api_key")
        guard !key.isEmpty else { return .notConfigured }
        let meraki = MerakiClient(apiKey: key, tls: tlsPolicy, base: merakiBase)

        var orgID = settings.prefs.merakiOrgID
        if orgID.isEmpty {
            let orgs = try await meraki.organizations().compactMap(NamedID.init(json:))
            guard orgs.count == 1 else { return .needsOrg }
            rememberOrg(orgs[0])
            orgID = orgs[0].id
        }
        guard let found = try await merakiFind(meraki, orgID: orgID, mac: mac) else { return .notFound }
        let record = found.record
        let seconds = lastSeenSeconds(record)
        return .found(MerakiSighting(
            apName: record["recentDeviceName"]?.text ?? "",
            apMAC: record["recentDeviceMac"]?.text ?? "",
            ssid: record["ssid"]?.text ?? "",
            networkName: found.network["name"]?.text ?? "",
            lastSeen: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil,
            client: record))
    }

    /// The working-list entry for `id`, as a device reference.
    public func deviceRef(_ id: String, type: DeviceType) -> DeviceRef? {
        guard let entry = entries(for: type).first(where: { $0.id == id }) else { return nil }
        return DeviceRef(id: entry.id, name: entry.value(.name).isEmpty ? entry.id : entry.value(.name), type: type)
    }
}
