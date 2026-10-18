import CryptoKit
import Foundation

/// Dropbox OAuth 2 (PKCE, no client secret) and the HTTP API v2 calls the app needs.
///
/// The app must be created in the Dropbox App Console with the "App folder" access type and the
/// permissions files.metadata.read, files.content.read and files.content.write. Register the redirect
/// URI `db-<APP_KEY>://2/token` there.
public actor DropboxAuth {
    public struct Tokens: Codable, Sendable {
        public var accessToken: String
        public var expiresAt: Date
        public var refreshToken: String
    }

    public let appKey: String
    private let store: SecretStore
    private let session: URLSession
    private var tokens: Tokens?
    private static let account = "dropbox.tokens"

    public init(appKey: String, store: SecretStore, session: URLSession = .shared) {
        self.appKey = appKey
        self.store = store
        self.session = session
        if let data = store.read(Self.account) { self.tokens = try? JSONDecoder().decode(Tokens.self, from: data) }
    }

    public var isConfigured: Bool { !appKey.isEmpty }
    public var isLinked: Bool { tokens != nil }
    public var redirectURI: String { "db-\(appKey)://2/token" }
    public var callbackScheme: String { "db-\(appKey)" }

    // MARK: PKCE

    public static func makePKCE() -> (verifier: String, challenge: String) {
        let verifier = base64URL(VaultCrypto.randomBytes(48))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return (verifier, challenge)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public func authorizeURL(challenge: String) -> URL? {
        var c = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")
        c?.queryItems = [
            .init(name: "client_id", value: appKey),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "token_access_type", value: "offline"),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        return c?.url
    }

    public static func code(fromCallback url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    // MARK: Tokens

    public func exchange(code: String, verifier: String) async throws {
        let body = [
            "code": code, "grant_type": "authorization_code", "client_id": appKey,
            "redirect_uri": redirectURI, "code_verifier": verifier,
        ]
        let json = try await tokenRequest(body)
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw RemoteError.unauthorized
        }
        try save(Tokens(accessToken: access, expiresAt: Self.expiry(json), refreshToken: refresh))
    }

    public func validAccessToken() async throws -> String {
        guard let t = tokens else { throw RemoteError.unauthorized }
        if t.expiresAt > Date().addingTimeInterval(60) { return t.accessToken }
        return try await refresh()
    }

    @discardableResult
    public func refresh() async throws -> String {
        guard let t = tokens else { throw RemoteError.unauthorized }
        let json = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": t.refreshToken, "client_id": appKey])
        guard let access = json["access_token"] as? String else { throw RemoteError.unauthorized }
        try save(Tokens(accessToken: access, expiresAt: Self.expiry(json), refreshToken: t.refreshToken))
        return access
    }

    public func unlink() {
        tokens = nil
        store.delete(Self.account)
    }

    private func save(_ t: Tokens) throws {
        tokens = t
        try store.write(try JSONEncoder().encode(t), account: Self.account)
    }

    private static func expiry(_ json: [String: Any]) -> Date {
        Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int) ?? 14_400))
    }

    private func tokenRequest(_ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await DropboxHTTP.send(req, session: session)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RemoteError.unauthorized }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The email of the linked account, for display.
    public func accountEmail() async -> String? {
        guard let token = try? await validAccessToken() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await DropboxHTTP.send(req, session: session),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

enum DropboxHTTP {
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost].contains(error.code) {
            throw RemoteError.offline
        }
    }
}

public struct DropboxRemoteStore: RemoteStore {
    private let auth: DropboxAuth
    private let session: URLSession

    public init(auth: DropboxAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: RemoteStore

    public func listFiles() async throws -> [RemoteFile] {
        var result = [RemoteFile]()
        var json = try await rpc("files/list_folder", ["path": "", "recursive": false, "limit": 2000])
        while true {
            for entry in (json["entries"] as? [[String: Any]]) ?? [] where entry[".tag"] as? String == "file" {
                if let name = entry["name"] as? String, let rev = entry["rev"] as? String {
                    result.append(RemoteFile(name: name, rev: rev))
                }
            }
            guard json["has_more"] as? Bool == true, let cursor = json["cursor"] as? String else { break }
            json = try await rpc("files/list_folder/continue", ["cursor": cursor])
        }
        return result
    }

    public func download(_ name: String) async throws -> (data: Data, rev: String) {
        var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        req.httpMethod = "POST"
        req.setValue(try Self.argHeader(["path": "/\(name)"]), forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, response) = try await send(req)
        let http = response as! HTTPURLResponse
        guard let resultHeader = http.value(forHTTPHeaderField: "Dropbox-API-Result"),
              let meta = try? JSONSerialization.jsonObject(with: Data(resultHeader.utf8)) as? [String: Any],
              let rev = meta["rev"] as? String else { throw RemoteError.server("Unexpected response from Dropbox.") }
        return (data, rev)
    }

    public func upload(_ name: String, data: Data, expectedRev: String?) async throws -> String {
        let mode: Any = expectedRev.map { [".tag": "update", "update": $0] } ?? "add"
        var req = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(
            try Self.argHeader(["path": "/\(name)", "mode": mode, "autorename": false, "mute": true, "strict_conflict": true]),
            forHTTPHeaderField: "Dropbox-API-Arg")
        req.httpBody = data
        let (body, _) = try await send(req)
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any], let rev = json["rev"] as? String
        else { throw RemoteError.server("Unexpected response from Dropbox.") }
        return rev
    }

    // MARK: Plumbing

    private func rpc(_ endpoint: String, _ params: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/\(endpoint)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, _) = try await send(req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func send(_ request: URLRequest, retryingAuth: Bool = true) async throws -> (Data, URLResponse) {
        var req = request
        req.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await DropboxHTTP.send(req, session: session)
        guard let http = response as? HTTPURLResponse else { throw RemoteError.server("No response.") }
        switch http.statusCode {
        case 200..<300:
            return (data, response)
        case 401:
            guard retryingAuth else { throw RemoteError.unauthorized }
            try await auth.refresh()
            return try await send(request, retryingAuth: false)
        case 409:
            throw Self.mapConflict(data)
        case 429:
            throw RemoteError.rateLimited(retryAfter: Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)
        default:
            throw RemoteError.server("Dropbox error \(http.statusCode).")
        }
    }

    static func mapConflict(_ data: Data) -> RemoteError {
        let summary = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_summary"] as? String) ?? ""
        if summary.contains("conflict") { return .conflict }
        if summary.contains("not_found") { return .notFound }
        return .server(summary.isEmpty ? "Dropbox rejected the request." : summary)
    }

    /// HTTP headers must be ASCII, so non-ASCII characters are escaped as \uXXXX.
    static func argHeader(_ args: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: args)
        let json = String(decoding: data, as: UTF8.self)
        return json.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "\\u%04x", $0.value) }.joined()
    }
}
