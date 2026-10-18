import XCTest

@testable import MyVaultKit

final class ImportTests: XCTestCase {
    // The exact Safe export layout could not be verified without a real file, so these samples follow the
    // layout the importer assumes. When a real export is available, add it here as a fixture.
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <database>
    <label id="7" name="Finance" type="user"/>
    <card title="Gmail" id="1" time_stamp="1600000000" deleted="false" template="false">
      <field name="Login" type="login">alex@example.com</field>
      <field name="Password" type="password">vX9#kQ2$mT7!pL4z</field>
      <field name="Website" type="website">https://mail.google.com</field>
      <field name="One-time password" type="one_time_password">JBSWY3DPEHPK3PXP</field>
      <notes>Main &amp; only mailbox</notes>
      <label_id>7</label_id>
    </card>
    <card title="Visa" id="2" time_stamp="1600000100000">
      <field name="Card Number" type="secret">4242424242424242</field>
      <field name="Expiry" type="expiry">09/28</field>
      <field name="CVV" type="pin">123</field>
    </card>
    <card title="Home Wi-Fi" id="3">
      <field name="Network" type="text">Lantern-5G</field>
      <field name="Password" type="password">quiet-river-meadow-41</field>
    </card>
    <card title="Old thing" deleted="true"><field name="Password" type="password">x</field></card>
    <card title="Login template" template="true"><field name="Login" type="login"></field></card>
    <card title="Weird">
      <field name="Login" type="login">w</field>
      <attachment name="scan.pdf"/>
    </card>
    </database>
    """

    func testXMLMapsKindsFieldsAndKeepsEverything() throws {
        let result = try SafeImporter.parse(data: Data(xml.utf8))
        XCTAssertEqual(result.format, "Safe XML")
        XCTAssertEqual(result.items.count, 4)
        XCTAssertEqual(result.skipped, 2, "template and deleted entries")

        let gmail = try XCTUnwrap(result.items.first { $0.name == "Gmail" })
        XCTAssertEqual(gmail.kind, .login)
        XCTAssertEqual(gmail.username, "alex@example.com")
        XCTAssertEqual(gmail.password, "vX9#kQ2$mT7!pL4z")
        XCTAssertEqual(gmail.website, "https://mail.google.com")
        XCTAssertEqual(gmail.totpSecret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(gmail.notes, "Main & only mailbox")
        XCTAssertEqual(gmail.tags, ["Finance"])
        XCTAssertEqual(gmail.createdAt, Date(timeIntervalSince1970: 1_600_000_000))

        let visa = try XCTUnwrap(result.items.first { $0.name == "Visa" })
        XCTAssertEqual(visa.kind, .card)
        XCTAssertEqual(visa.fields.count, 3)
        XCTAssertEqual(visa.createdAt, Date(timeIntervalSince1970: 1_600_000_100), "millisecond timestamps are understood")
        XCTAssertEqual(visa.fields.first { $0.label == "CVV" }?.type, .secret)

        XCTAssertEqual(result.items.first { $0.name == "Home Wi-Fi" }?.kind, .wifi)
        XCTAssertTrue(result.warnings.contains { $0.contains("attachment") }, "unknown data is reported, not silently dropped")
        XCTAssertEqual(result.counts[.login], 2)
    }

    func testBrokenXMLIsRejectedCleanly() {
        XCTAssertThrowsError(try SafeImporter.parse(data: Data("<database><card title=\"x\">".utf8)))
    }

    func testCSVWithQuotesAndExtraColumns() throws {
        let csv = "\u{FEFF}Name,Login,Password,Website,Notes,Recovery email\r\n"
            + "Amazon,alex@example.com,\"pa,ss\"\"word\",https://amazon.com,\"line one\nline two\",backup@example.com\r\n"
            + "\r\n"
            + "Netflix,alex,hunter2,,,\r\n"
        let result = try SafeImporter.parse(data: Data(csv.utf8))
        XCTAssertEqual(result.items.count, 2)
        let amazon = result.items[0]
        XCTAssertEqual(amazon.password, "pa,ss\"word")
        XCTAssertEqual(amazon.notes, "line one\nline two")
        XCTAssertEqual(amazon.field("Recovery email")?.value, "backup@example.com", "unmapped columns are kept")
        XCTAssertEqual(result.items[1].username, "alex")
    }

    func testCSVFromOtherManagers() throws {
        let chrome = "name,url,username,password,note\nGitHub,https://github.com,alex,s3cr3t-Pass!,\n"
        let r = try SafeImporter.parse(data: Data(chrome.utf8))
        XCTAssertEqual(r.items.first?.website, "https://github.com")
        XCTAssertEqual(r.items.first?.password, "s3cr3t-Pass!")

        let semicolon = "Title;Username;Password\nBank;me;pw1\n"
        XCTAssertEqual(try SafeImporter.parse(data: Data(semicolon.utf8)).items.first?.password, "pw1")
    }

    func testDuplicatesAreSkipped() throws {
        let r = try SafeImporter.parse(data: Data(xml.utf8))
        let (unique, dupes) = SafeImporter.removingDuplicates(r.items, existing: [r.items[0]])
        XCTAssertEqual(dupes, 1)
        XCTAssertEqual(unique.count, r.items.count - 1)
        let (again, d2) = SafeImporter.removingDuplicates(r.items + r.items, existing: [])
        XCTAssertEqual(again.count, r.items.count)
        XCTAssertEqual(d2, r.items.count)
    }

    func testImportEndToEndIntoVault() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        let r = try SafeImporter.parse(data: Data(xml.utf8))
        try await s.importItems(r.items)
        await XCTAssertEqualA(await s.allItems().count, 4)
        let reopened = try VaultSession.open(password: "pw", storage: storage)
        await XCTAssertEqualA(await reopened.allItems().count, 4)
    }

    func testEmptyAndGarbageFiles() {
        XCTAssertThrowsError(try SafeImporter.parse(data: Data()))
        XCTAssertThrowsError(try SafeImporter.parse(data: Data(count: 0)))
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    var dict = [String: Data]()
    func read(_ account: String) -> Data? { dict[account] }
    func write(_ data: Data, account: String) throws { dict[account] = data }
    func delete(_ account: String) { dict[account] = nil }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var seen = [URLRequest]()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let (status, headers, body) = Self.handler?(request) ?? (500, [:], Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DropboxTests: XCTestCase {
    func makeStore(accessExpired: Bool = false) throws -> (DropboxRemoteStore, DropboxAuth) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let secrets = MemorySecrets()
        let tokens = DropboxAuth.Tokens(
            accessToken: "tok", expiresAt: Date().addingTimeInterval(accessExpired ? -10 : 3600), refreshToken: "refresh")
        try secrets.write(JSONEncoder().encode(tokens), account: "dropbox.tokens")
        let auth = DropboxAuth(appKey: "KEY123", store: secrets, session: session)
        StubProtocol.seen = []
        return (DropboxRemoteStore(auth: auth, session: session), auth)
    }

    func testPKCEChallengeMatchesVerifier() {
        let (verifier, challenge) = DropboxAuth.makePKCE()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertFalse(challenge.contains("=") || challenge.contains("+") || challenge.contains("/"))
        XCTAssertEqual(challenge, DropboxAuth.base64URL(Data(SHA256Helper.hash(verifier))))
    }

    func testAuthorizeURL() async throws {
        let (_, auth) = try makeStore()
        let url = try await unwrapA(await auth.authorizeURL(challenge: "abc"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(q("client_id"), "KEY123")
        XCTAssertEqual(q("code_challenge_method"), "S256")
        XCTAssertEqual(q("token_access_type"), "offline")
        XCTAssertEqual(q("redirect_uri"), "db-KEY123://2/token")
        XCTAssertEqual(DropboxAuth.code(fromCallback: URL(string: "db-KEY123://2/token?code=XYZ&state=1")!), "XYZ")
    }

    func testUploadSendsExpectedHeadersAndMapsRev() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { _ in (200, [:], Data(#"{"rev":"abc123"}"#.utf8)) }
        let rev = try await store.upload("x.vitem", data: Data([1, 2, 3]), expectedRev: "old")
        XCTAssertEqual(rev, "abc123")
        let req = try XCTUnwrap(StubProtocol.seen.last)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let arg = try XCTUnwrap(req.value(forHTTPHeaderField: "Dropbox-API-Arg"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: Any])
        XCTAssertEqual(json["path"] as? String, "/x.vitem")
        XCTAssertEqual((json["mode"] as? [String: String])?["update"], "old")
        XCTAssertEqual(json["autorename"] as? Bool, false)
    }

    func testConflictAndNotFoundAreMapped() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { _ in (409, [:], Data(#"{"error_summary":"path/conflict/file/.."}"#.utf8)) }
        do { _ = try await store.upload("x", data: Data(), expectedRev: nil); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .conflict) }
        StubProtocol.handler = { _ in (409, [:], Data(#"{"error_summary":"path/not_found/.."}"#.utf8)) }
        do { _ = try await store.download("x"); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .notFound) }
        StubProtocol.handler = { _ in (429, ["Retry-After": "7"], Data()) }
        do { _ = try await store.listFiles(); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .rateLimited(retryAfter: 7)) }
    }

    func testListPaginatesAndOnlyReturnsFiles() async throws {
        let (store, _) = try makeStore()
        var call = 0
        StubProtocol.handler = { _ in
            call += 1
            if call == 1 {
                return (200, [:], Data(#"{"entries":[{".tag":"file","name":"a.vitem","rev":"r1"},{".tag":"folder","name":"dir"}],"has_more":true,"cursor":"c"}"#.utf8))
            }
            return (200, [:], Data(#"{"entries":[{".tag":"file","name":"header.json","rev":"r2"}],"has_more":false,"cursor":"c2"}"#.utf8))
        }
        let files = try await store.listFiles()
        XCTAssertEqual(files, [RemoteFile(name: "a.vitem", rev: "r1"), RemoteFile(name: "header.json", rev: "r2")])
    }

    func testDownloadReadsRevFromHeader() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { _ in (200, ["Dropbox-API-Result": #"{"rev":"r9","name":"a"}"#], Data("body".utf8)) }
        let result = try await store.download("a")
        XCTAssertEqual(result.rev, "r9")
        XCTAssertEqual(result.data, Data("body".utf8))
    }

    func testExpiredTokenIsRefreshedBeforeCalling() async throws {
        let (store, _) = try makeStore(accessExpired: true)
        StubProtocol.handler = { req in
            if req.url?.host == "api.dropboxapi.com", req.url?.path == "/oauth2/token" {
                return (200, [:], Data(#"{"access_token":"fresh","expires_in":14400}"#.utf8))
            }
            return (200, [:], Data(#"{"entries":[],"has_more":false}"#.utf8))
        }
        _ = try await store.listFiles()
        let last = try XCTUnwrap(StubProtocol.seen.last)
        XCTAssertEqual(last.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func testHeaderEscapesNonASCII() throws {
        let h = try DropboxRemoteStore.argHeader(["path": "/caf\u{00E9}"])
        XCTAssertTrue(h.allSatisfy { $0.isASCII })
        XCTAssertTrue(h.contains("\\u00e9"))
    }

    func testUnlinkedAuthRejects() async throws {
        let auth = DropboxAuth(appKey: "k", store: MemorySecrets())
        do { _ = try await auth.validAccessToken(); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .unauthorized) }
    }
}

import CryptoKit
enum SHA256Helper {
    static func hash(_ s: String) -> [UInt8] { Array(SHA256.hash(data: Data(s.utf8))) }
}
