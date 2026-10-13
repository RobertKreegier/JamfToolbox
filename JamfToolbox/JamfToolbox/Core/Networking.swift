import Foundation
import Security

/// A user-facing error from talking to Jamf Pro or Meraki.
struct ServiceError: LocalizedError {
    let message: String
    /// True for HTTP 404, which callers treat as "that device no longer exists".
    var isNotFound = false
    /// True for HTTP 403: the account is authenticated but lacks a privilege.
    var isPermissionDenied = false

    init(_ message: String, isNotFound: Bool = false, isPermissionDenied: Bool = false) {
        self.message = message
        self.isNotFound = isNotFound
        self.isPermissionDenied = isPermissionDenied
    }

    var errorDescription: String? { message }
}

typealias JamfError = ServiceError
typealias MerakiError = ServiceError

/// How server certificates are judged.
struct TLSPolicy: Equatable {
    /// When false, any certificate is accepted (discouraged).
    var verify = true
    /// Optional PEM/DER file of extra trusted roots for internal CAs. Added to
    /// the system trust store rather than replacing it.
    var caBundlePath = ""
}

struct HTTPResult {
    let status: Int
    let data: Data
}

/// URLSession wrapper that applies a `TLSPolicy`.
///
/// Uses an ephemeral session so no cookies or cache are shared between
/// requests, matching the behavior of the original `urllib` client.
final class HTTPTransport {
    private let session: URLSession
    private let delegate: TLSDelegate

    init(policy: TLSPolicy) {
        delegate = TLSDelegate(policy: policy)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        try delegate.validateBundle()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResult(status: status, data: data)
    }

    /// Turn a low-level failure into something worth showing.
    static func explain(_ error: Error, host: String) -> Error {
        if let service = error as? ServiceError { return service }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return ServiceError(
                "TLS certificate verification failed for \(host).\n\n"
                + "macOS does not trust the server's certificate. Fixes, in order of preference:\n"
                + "1. If the certificate comes from an internal/district CA, export that CA as a "
                + ".pem file and choose it as the CA bundle in Settings > Connection (or install "
                + "it in Keychain Access and mark it trusted).\n"
                + "2. As a last resort, uncheck \"Verify SSL certificates\" in Settings "
                + "(not recommended).")
        default:
            return ServiceError("Could not reach \(host): \(urlError.localizedDescription)")
        }
    }
}

/// Server-trust handling and redirect policy for `HTTPTransport`.
private final class TLSDelegate: NSObject, URLSessionTaskDelegate {
    let policy: TLSPolicy
    private let lock = NSLock()
    private var cachedAnchors: [SecCertificate]?

    init(policy: TLSPolicy) { self.policy = policy }

    /// Fail early, with a clear message, if the configured CA file is unusable.
    func validateBundle() throws {
        guard policy.verify, !policy.caBundlePath.isEmpty else { return }
        _ = try anchors()
    }

    private func anchors() throws -> [SecCertificate] {
        lock.lock(); defer { lock.unlock() }
        if let cachedAnchors { return cachedAnchors }
        let path = (policy.caBundlePath as NSString).expandingTildeInPath
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ServiceError("Could not load CA bundle \(policy.caBundlePath): \(error.localizedDescription)")
        }
        let certificates = Self.certificates(inPEMOrDER: data)
        guard !certificates.isEmpty else {
            throw ServiceError("Could not load CA bundle \(policy.caBundlePath): no certificates found in the file.")
        }
        cachedAnchors = certificates
        return certificates
    }

    /// Accepts a PEM bundle (any number of certificates) or a single DER file.
    static func certificates(inPEMOrDER data: Data) -> [SecCertificate] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        guard let text = String(data: data, encoding: .utf8), text.contains(begin) else {
            return SecCertificateCreateWithData(nil, data as CFData).map { [$0] } ?? []
        }
        var result: [SecCertificate] = []
        var remaining = text[...]
        while let start = remaining.range(of: begin), let stop = remaining.range(of: end, range: start.upperBound..<remaining.endIndex) {
            let base64 = remaining[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(base64)),
               let certificate = SecCertificateCreateWithData(nil, der as CFData) {
                result.append(certificate)
            }
            remaining = remaining[stop.upperBound...]
        }
        return result
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if !policy.verify {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        if policy.caBundlePath.isEmpty {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // System trust first; only if that fails, also trust the custom roots.
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard let anchors = try? anchors() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// URLSession drops the Authorization header when a redirect leaves the
    /// original host. Meraki legitimately redirects `api.meraki.com` to a
    /// regional shard, so carry the header across *within meraki.com only*.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if redirected.value(forHTTPHeaderField: "Authorization") == nil,
           let original = task.originalRequest,
           let auth = original.value(forHTTPHeaderField: "Authorization"),
           let from = original.url?.host?.lowercased(),
           let to = redirected.url?.host?.lowercased(),
           redirected.url?.scheme == "https" {
            let sameHost = from == to
            let meraki = (from == "meraki.com" || from.hasSuffix(".meraki.com"))
                && (to == "meraki.com" || to.hasSuffix(".meraki.com"))
            if sameHost || meraki {
                redirected.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }
        completionHandler(redirected)
    }
}

enum URLEncoding {
    /// Matches Python's `urllib.parse.quote` defaults: letters, digits and
    /// `_.-~` stay as-is, and so does `/`. Everything else (including `*`
    /// and `:`) is percent-encoded.
    static func quote(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "_.-~/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

enum XMLEscape {
    /// Same three characters Python's `xml.sax.saxutils.escape` handles.
    static func text(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
