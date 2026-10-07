import AppKit
import SwiftUI

struct NamedID: Identifiable, Hashable {
    let id: String
    let name: String

    init(id: String, name: String) { self.id = id; self.name = name }

    init?(json: JSONValue) {
        let id = json["id"]?.text ?? ""
        guard !id.isEmpty else { return nil }
        let name = json["name"]?.text ?? ""
        self.init(id: id, name: name.isEmpty ? id : name)
    }
}

struct MerakiNetworkChoice {
    let org: NamedID
    let network: NamedID
}

extension AppModel {
    func merakiClient() async -> MerakiClient? {
        let key = settings.secret("meraki_api_key")
        guard !key.isEmpty else {
            await Dialogs.info("Add your Meraki Dashboard API key in Settings > Meraki first.")
            openSettings()
            return nil
        }
        return MerakiClient(apiKey: key, tls: tlsPolicy)
    }

    func actionMerakiInfo() async {
        guard let meraki = await merakiClient(),
              let device = await selectedDevice(),
              let client = await requireClient() else { return }

        let cachedMAC = entries.first { $0.id == device.id }?.value(.wifiMAC) ?? ""

        // Always re-read the MAC from Jamf Pro rather than trusting the saved
        // row: querying Meraki with a stale MAC returns a confident answer
        // about the wrong device.
        guard let (record, tags) = await loadRecord(device, client: client) else { return }
        let entry = Templates.entry(from: record, type: device.type, deviceID: device.id)
        updateListEntry(type: device.type, id: device.id, fields: entry.fields)

        let mac = tags["wifi_mac"] ?? ""
        guard !mac.isEmpty else {
            await Dialogs.info("Jamf Pro has no MAC address on record for “\(device.name)”.\n\n"
                               + "Try “Update Inventory” and check back once the device has reported in.")
            return
        }
        if !cachedMAC.isEmpty, normalizeMAC(cachedMAC) != normalizeMAC(mac) {
            log.add("Note: MAC for \(device.name) changed since it was added (\(cachedMAC) → \(mac)). "
                    + "Using the current one.")
        }
        // The org-wide search needs no network; only fall back to a
        // per-network lookup if the user asks for it.
        guard let orgID = await merakiEnsureOrg(meraki) else { return }
        await merakiSearch(meraki, device: device, mac: mac, orgID: orgID)
    }

    private func rememberOrg(_ org: NamedID) {
        settings.prefs.merakiOrgID = org.id
        settings.prefs.merakiOrgName = org.name
        persist()
    }

    /// The remembered organization, or ask Meraki (and the user, if there are several).
    private func merakiEnsureOrg(_ meraki: MerakiClient) async -> String? {
        let saved = settings.prefs.merakiOrgID
        if !saved.isEmpty { return saved }

        switch await busyScope("Loading Meraki organizations…", { try await meraki.organizations() }) {
        case .failure(let error):
            let message = describe(error)
            log.add("Meraki lookup failed: \(message)")
            await Dialogs.error(message)
            return nil
        case .success(let json):
            let orgs = json.compactMap(NamedID.init(json:))
            guard !orgs.isEmpty else {
                await Dialogs.info("That Meraki API key can't see any organizations. Check the key in Settings > Meraki.")
                return nil
            }
            if orgs.count == 1 {
                rememberOrg(orgs[0])   // nothing to choose; remember it silently
                return orgs[0].id
            }
            let picked: NamedID? = await Sheets.present { done in
                MerakiOrgSheet(orgs: orgs, savedID: settings.prefs.merakiOrgID, done: done)
            }
            guard let picked else { return nil }
            rememberOrg(picked)
            return picked.id
        }
    }

    /// Resolve an AP's MAC to its Dashboard name, caching per network.
    private func merakiAPName(_ meraki: MerakiClient, networkID: String, apMAC: String) async -> String {
        guard !apMAC.isEmpty, !networkID.isEmpty else { return "" }
        if apNames[networkID] == nil {
            var names: [String: String] = [:]
            if let hardware = try? await meraki.devices(networkID: networkID) {
                for item in hardware {
                    let mac = item["mac"]?.text ?? ""
                    let name = item["name"]?.text ?? ""
                    names[normalizeMAC(mac)] = name.isEmpty ? mac : name
                }
            }
            apNames[networkID] = names
        }
        return apNames[networkID]?[normalizeMAC(apMAC)] ?? ""
    }

    private func lastSeenSeconds(_ record: JSONValue) -> Double {
        switch record["lastSeen"] {
        case .number(let n)?: return Double(n) ?? 0
        case .string(let s)?: return parseISO8601(s)?.timeIntervalSince1970 ?? 0
        default: return 0
        }
    }

    /// One org-wide call: finds the client and the network it's on.
    private func merakiSearch(_ meraki: MerakiClient, device: DeviceRef, mac: String, orgID: String) async {
        let orgName = settings.prefs.merakiOrgName.isEmpty ? orgID : settings.prefs.merakiOrgName

        let outcome = await busyScope("Searching Meraki for \(device.name)…") { () -> (record: JSONValue, network: JSONValue, count: Int)? in
            guard let payload = try await meraki.searchClient(orgID: orgID, mac: mac) else { return nil }
            // Newest sighting first.
            let records = (payload["records"]?.arrayValue ?? []).sorted { lastSeenSeconds($0) > lastSeenSeconds($1) }
            guard var record = records.first else { return nil }
            let network = record["network"] ?? .emptyObject
            if record["manufacturer"] == nil {
                record = record.setting("manufacturer", to: .string(payload["manufacturer"]?.text ?? ""))
            }
            if (record["recentDeviceName"]?.text ?? "").isEmpty {
                let name = await merakiAPName(meraki, networkID: network["id"]?.text ?? "",
                                              apMAC: record["recentDeviceMac"]?.text ?? "")
                record = record.setting("recentDeviceName", to: .string(name))
            }
            return (record, network, records.count)
        }

        switch outcome {
        case .failure(let error):
            let message = describe(error)
            log.add("Meraki lookup failed: \(message)")
            await Dialogs.error(message)
        case .success(nil):
            log.add("Meraki: \(normalizeMAC(mac)) not found in “\(orgName)”.")
            if await Dialogs.confirm(
                "No client with MAC \(normalizeMAC(mac)) was found anywhere in the “\(orgName)” organization.\n\n"
                + "This usually means the device hasn't been on the Wi-Fi recently. Search one specific network instead?",
                yes: "Search a Network…", no: "Cancel") {
                await merakiPickNetwork(meraki, device: device, mac: mac)
            }
        case .success(let result?):
            let networkName = result.network["name"]?.text ?? ""
            let shownNetwork = networkName.isEmpty ? "unknown network" : networkName
            let note = result.count > 1
                ? "Seen on \(result.count) networks — showing the most recent. See Full response… for all."
                : "Right-click a field to copy it."
            let ap = firstNonEmpty(result.record["recentDeviceName"]?.text, result.record["recentDeviceMac"]?.text) ?? "?"
            log.add("Meraki: \(device.name) — network “\(shownNetwork)”, "
                    + "SSID “\(firstNonEmpty(result.record["ssid"]?.text) ?? "?")”, AP “\(ap)”, "
                    + "last seen \(firstNonEmpty(friendlyTimestamp(result.record["lastSeen"])) ?? "?").")
            showMerakiInfo(device: device, mac: mac, networkName: shownNetwork, client: result.record,
                           note: note, changeLabel: "Search a network…", meraki: meraki)
        }
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { !$0.isEmpty }
    }

    private func showMerakiInfo(device: DeviceRef, mac: String, networkName: String, client: JSONValue,
                                note: String, changeLabel: String, meraki: MerakiClient) {
        InfoWindows.showMeraki(
            deviceName: device.name, mac: mac, networkName: networkName, client: client,
            note: note, changeLabel: changeLabel,
            onChangeNetwork: { Task { await self.merakiPickNetwork(meraki, device: device, mac: mac) } })
    }

    /// Fallback path: choose one network, remember it, and look the client up there.
    func merakiPickNetwork(_ meraki: MerakiClient, device: DeviceRef, mac: String) async {
        let prefs = settings.prefs
        let picked: MerakiNetworkChoice? = await Sheets.present(resizable: true) { done in
            MerakiNetworkSheet(meraki: meraki, savedOrgID: prefs.merakiOrgID,
                               savedNetworkID: prefs.merakiNetworkID, done: done)
        }
        guard let picked else { return }
        settings.prefs.merakiOrgID = picked.org.id
        settings.prefs.merakiOrgName = picked.org.name
        settings.prefs.merakiNetworkID = picked.network.id
        settings.prefs.merakiNetworkName = picked.network.name
        persist()
        await merakiLookup(meraki, device: device, mac: mac, network: picked.network)
    }

    /// Look the client up in one specific network.
    private func merakiLookup(_ meraki: MerakiClient, device: DeviceRef, mac: String, network: NamedID) async {
        let outcome = await busyScope("Looking up \(device.name) in Meraki (\(network.name))…") { () -> JSONValue? in
            guard var client = try await meraki.client(networkID: network.id, mac: mac) else { return nil }
            // Some responses include only the AP's MAC; resolve it to the name the user knows.
            if (client["recentDeviceName"]?.text ?? "").isEmpty {
                let name = await merakiAPName(meraki, networkID: network.id,
                                              apMAC: client["recentDeviceMac"]?.text ?? "")
                client = client.setting("recentDeviceName", to: .string(name))
            }
            return client
        }
        switch outcome {
        case .failure(let error):
            let message = describe(error)
            log.add("Meraki lookup failed: \(message)")
            await Dialogs.error(message)
        case .success(nil):
            log.add("Meraki: \(normalizeMAC(mac)) not found in “\(network.name)”.")
            if await Dialogs.confirm(
                "No client with MAC \(normalizeMAC(mac)) was found in the “\(network.name)” network.\n\n"
                + "Look in a different network?", yes: "Choose Network…", no: "Cancel") {
                await merakiPickNetwork(meraki, device: device, mac: mac)
            }
        case .success(let client?):
            let ap = firstNonEmpty(client["recentDeviceName"]?.text, client["recentDeviceMac"]?.text) ?? "?"
            log.add("Meraki: \(device.name) — SSID “\(firstNonEmpty(client["ssid"]?.text) ?? "?")”, "
                    + "AP “\(ap)”, last seen \(firstNonEmpty(friendlyTimestamp(client["lastSeen"])) ?? "?").")
            showMerakiInfo(device: device, mac: mac, networkName: network.name, client: client,
                           note: "Right-click a field to copy it.", changeLabel: "Change network…", meraki: meraki)
        }
    }
}
