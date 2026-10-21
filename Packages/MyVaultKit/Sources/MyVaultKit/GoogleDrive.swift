import Foundation

/// Google OAuth 2.0 for an "iOS" type OAuth client (PKCE, no client secret, custom redirect scheme made from
/// the client id) and the Google Drive API v3 calls the app needs.
///
/// Only the non-sensitive scope `drive.appdata` is requested: the app can see a hidden folder of its own in your
/// Drive and nothing else. Create the client in Google Cloud Console (see the README) and publish the consent
/// screen, otherwise Google expires the login every 7 days.
public actor GoogleAuth {
    public struct Tokens: Codable, Sendable {
        public var accessToken: String
        public var expiresAt: Date
        public var refreshToken: String
    }

    public static let scope = "https://www.googleapis.com/auth/drive.appdata"

    public let clientID: String
    private let store: SecretStore
    private let session: URLSession
    private var tokens: Tokens?
    private static let account = "google.tokens"

    public init(clientID: String, store: SecretStore, session: URLSession = .shared) {
        self.clientID = clientID
        self.store = store
        self.session = session
        if let data = store.read(Self.account) { self.tokens = try? JSONDecoder().decode(Tokens.self, from: data) }
    }

    public var isConfigured: Bool { Self.normalizedClientID(clientID) != nil }
    public var isLinked: Bool { tokens != nil }

    /// Google's redirect scheme for iOS clients: the client id in reverse order.
    public var callbackScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    public var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    /// Accepts the id as copied from Google (`123-abc.apps.googleusercontent.com`) and rejects anything else.
    public static func normalizedClientID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$"#
        return id.range(of: pattern, options: .regularExpression) != nil ? id : nil
    }

    public func authorizeURL(challenge: String) -> URL? {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        c?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            // `offline` + `consent` make Google return a refresh token, so you stay signed in.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c?.url
    }

    public static func code(fromCallback url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    // MARK: Tokens

    public func exchange(code: String, verifier: String) async throws {
        let json = try await tokenRequest([
            "code": code, "grant_type": "authorization_code", "client_id": clientID,
            "redirect_uri": redirectURI, "code_verifier": verifier,
        ])
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
        let json = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": t.refreshToken, "client_id": clientID])
        guard let access = json["access_token"] as? String else { throw RemoteError.unauthorized }
        // Google does not send the refresh token again; keep the one we have.
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
        Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int) ?? 3_600))
    }

    private func tokenRequest(_ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await DropboxHTTP.send(req, session: session)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RemoteError.unauthorized }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// Stores the encrypted files in the hidden app data folder of your Google Drive.
///
/// Drive has no "write only if unchanged" call, so an update first checks the file's `version` and then writes.
/// Fine for one person with two devices; a write at the very same instant from both could still collide, and the
/// next sync merges it like any other conflict.
public actor GoogleDriveRemoteStore: RemoteStore {
    private let auth: GoogleAuth
    private let session: URLSession
    private var ids: [String: String] = [:]

    public init(auth: GoogleAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    private static let api = "https://www.googleapis.com/drive/v3/files"
    private static let upload = "https://www.googleapis.com/upload/drive/v3/files"

    // MARK: RemoteStore

    public func listFiles() async throws -> [RemoteFile] {
        var result = [RemoteFile]()
        var pageToken: String?
        ids.removeAll()
        repeat {
            var c = URLComponents(string: Self.api)!
            c.queryItems = [
                .init(name: "spaces", value: "appDataFolder"),
                .init(name: "q", value: "trashed = false"),
                .init(name: "pageSize", value: "1000"),
                .init(name: "fields", value: "nextPageToken,files(id,name,version)"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let json = try await getJSON(c.url!)
            for f in (json["files"] as? [[String: Any]]) ?? [] {
                guard let id = f["id"] as? String, let name = f["name"] as? String else { continue }
                ids[name] = id
                result.append(RemoteFile(name: name, rev: Self.version(f)))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return result
    }

    public func download(_ name: String) async throws -> (data: Data, rev: String) {
        guard let file = try await find(name) else { throw RemoteError.notFound }
        var c = URLComponents(string: "\(Self.api)/\(file.id)")!
        c.queryItems = [.init(name: "alt", value: "media")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "GET"
        let (data, _) = try await send(req)
        return (data, file.rev)
    }

    public func upload(_ name: String, data: Data, expectedRev: String?) async throws -> String {
        let existing = try await find(name)
        guard let expectedRev else {
            if existing != nil { throw RemoteError.conflict }
            return try await create(name, data: data)
        }
        guard let existing else { throw RemoteError.notFound }
        guard existing.rev == expectedRev else { throw RemoteError.conflict }

        var c = URLComponents(string: "\(Self.upload)/\(existing.id)")!
        c.queryItems = [.init(name: "uploadType", value: "media"), .init(name: "fields", value: "id,version")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "PATCH"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (body, _) = try await send(req)
        return Self.version((try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
    }

    public func deleteFile(_ name: String) async throws {
        guard let file = try await find(name) else { return }
        var req = URLRequest(url: URL(string: "\(Self.api)/\(file.id)")!)
        req.httpMethod = "DELETE"
        _ = try await send(req)
        ids[name] = nil
    }

    // MARK: Helpers

    private func find(_ name: String) async throws -> (id: String, rev: String)? {
        var c = URLComponents(string: Self.api)!
        // File names here are uuids and "header.json": no characters that need escaping in the query.
        c.queryItems = [
            .init(name: "spaces", value: "appDataFolder"),
            .init(name: "q", value: "name = '\(name)' and trashed = false"),
            .init(name: "fields", value: "files(id,name,version)"),
            .init(name: "orderBy", value: "createdTime"),
        ]
        let json = try await getJSON(c.url!)
        guard let f = ((json["files"] as? [[String: Any]]) ?? []).first, let id = f["id"] as? String else { return nil }
        ids[name] = id
        return (id, Self.version(f))
    }

    private func create(_ name: String, data: Data) async throws -> String {
        let boundary = "safevault-\(UUID().uuidString)"
        let meta = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]])
        var body = Data()
        body += Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += meta
        body += Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body += data
        body += Data("\r\n--\(boundary)--".utf8)

        var c = URLComponents(string: Self.upload)!
        c.queryItems = [.init(name: "uploadType", value: "multipart"), .init(name: "fields", value: "id,version")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (resp, _) = try await send(req)
        let json = (try JSONSerialization.jsonObject(with: resp) as? [String: Any]) ?? [:]
        if let id = json["id"] as? String { ids[name] = id }
        return Self.version(json)
    }

    static func version(_ json: [String: Any]) -> String {
        if let s = json["version"] as? String { return s }
        if let n = json["version"] as? Int { return String(n) }
        return "0"
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
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
        case 404:
            throw RemoteError.notFound
        case 429:
            throw RemoteError.rateLimited(retryAfter: Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5)
        default:
            throw Self.mapError(status: http.statusCode, data: data)
        }
    }

    static func mapError(status: Int, data: Data) -> RemoteError {
        let error = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]) ?? [:]
        let reasons = ((error["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
        let message = (error["message"] as? String) ?? "Google Drive error \(status)."
        if reasons.contains("storageQuotaExceeded") { return .quotaExceeded }
        if reasons.contains(where: { $0 == "rateLimitExceeded" || $0 == "userRateLimitExceeded" }) { return .rateLimited(retryAfter: 5) }
        if status == 403, reasons.contains(where: { $0 == "insufficientPermissions" || $0 == "authError" }) { return .unauthorized }
        return .server(message)
    }
}
