import Foundation

/// Minimal Meraki Dashboard API (v1) client for client lookups.
public actor MerakiClient {
    public static let productionBase = "https://api.meraki.com/api/v1"

    private let base: String
    private let apiKey: String
    private let transport: HTTPTransport

    public init(apiKey: String, tls: TLSPolicy, base: String = MerakiClient.productionBase) {
        self.apiKey = apiKey
        self.base = base
        self.transport = HTTPTransport(policy: tls)
    }

    /// Returns parsed JSON, or throws `ServiceError(isNotFound: true)` on 404.
    private func request(_ path: String) async throws -> JSONValue {
        guard let url = URL(string: "\(base)\(path)") else { throw ServiceError("Invalid Meraki request URL.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let result: HTTPResult
        do {
            result = try await transport.send(request)
        } catch {
            let explained = HTTPTransport.explain(error, host: "the Meraki API")
            if let service = explained as? ServiceError, service.message.hasPrefix("TLS certificate") {
                throw ServiceError("TLS verification failed reaching Meraki. The CA bundle configured "
                                   + "in Settings > Connection is used here too.")
            }
            throw explained
        }
        switch result.status {
        case 200..<300:
            break
        case 401:
            throw ServiceError("Meraki rejected the API key (401). Check it in Settings > Meraki.")
        case 404:
            throw ServiceError("Not found (404).", isNotFound: true)
        case 429:
            throw ServiceError("Meraki rate limit hit (429). Wait a few seconds and retry.")
        default:
            let detail = String(decoding: result.data.prefix(200), as: UTF8.self)
            throw ServiceError("Meraki API error HTTP \(result.status). \(detail)")
        }
        guard !result.data.isEmpty else { return .emptyObject }
        do {
            return try JSONValue.parse(result.data)
        } catch {
            throw ServiceError("Meraki returned an unreadable response.")
        }
    }

    public func organizations() async throws -> [JSONValue] {
        try await request("/organizations").arrayValue ?? []
    }

    public func networks(orgID: String) async throws -> [JSONValue] {
        try await request("/organizations/\(URLEncoding.quote(orgID))/networks?perPage=1000").arrayValue ?? []
    }

    /// All Meraki hardware (APs, switches, …) in a network.
    public func devices(networkID: String) async throws -> [JSONValue] {
        try await request("/networks/\(URLEncoding.quote(networkID))/devices").arrayValue ?? []
    }

    /// Look up a client by MAC in one network. Returns nil if not found.
    public func client(networkID: String, mac: String) async throws -> JSONValue? {
        do {
            return try await request("/networks/\(URLEncoding.quote(networkID))/clients/\(URLEncoding.quote(normalizeMAC(mac)))")
        } catch let error as ServiceError where error.isNotFound {
            return nil
        }
    }

    /// Org-wide client lookup by MAC — no network needed. The payload's `records`
    /// holds one entry per network the MAC was seen on; nil if it's nowhere in the org.
    public func searchClient(orgID: String, mac: String) async throws -> JSONValue? {
        let payload: JSONValue
        do {
            payload = try await request("/organizations/\(URLEncoding.quote(orgID))/clients/search?mac=\(URLEncoding.quote(normalizeMAC(mac)))")
        } catch let error as ServiceError where error.isNotFound {
            return nil
        }
        guard case .object = payload, let records = payload["records"]?.arrayValue, !records.isEmpty else { return nil }
        return payload
    }
}
