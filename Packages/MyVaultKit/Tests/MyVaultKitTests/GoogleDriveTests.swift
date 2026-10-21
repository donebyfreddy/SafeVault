import XCTest

@testable import MyVaultKit

final class GoogleDriveTests: XCTestCase {
    func makeStore(accessExpired: Bool = false) throws -> (GoogleDriveRemoteStore, GoogleAuth) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let secrets = MemorySecrets()
        let tokens = GoogleAuth.Tokens(accessToken: "gtok", expiresAt: Date().addingTimeInterval(accessExpired ? -10 : 3600), refreshToken: "grefresh")
        try secrets.write(JSONEncoder().encode(tokens), account: "google.tokens")
        let auth = GoogleAuth(clientID: "123456-abcdef.apps.googleusercontent.com", store: secrets, session: session)
        StubProtocol.seen = []
        return (GoogleDriveRemoteStore(auth: auth, session: session), auth)
    }

    func testClientIDValidation() {
        XCTAssertEqual(GoogleAuth.normalizedClientID("  123456-abcdef.apps.googleusercontent.com \n"), "123456-abcdef.apps.googleusercontent.com")
        for bad in ["", "abc", "123456-abcdef", "GOCSPX-secretsecret", "123456-abcdef.apps.googleusercontent.com.evil.com", "https://x.apps.googleusercontent.com"] {
            XCTAssertNil(GoogleAuth.normalizedClientID(bad), bad)
        }
    }

    func testRedirectSchemeAndAuthorizeURL() async throws {
        let (_, auth) = try makeStore()
        await XCTAssertEqualA(await auth.callbackScheme, "com.googleusercontent.apps.123456-abcdef")
        await XCTAssertEqualA(await auth.redirectURI, "com.googleusercontent.apps.123456-abcdef:/oauth2redirect")
        let url = try await unwrapA(await auth.authorizeURL(challenge: "chal"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(q("scope"), "https://www.googleapis.com/auth/drive.appdata", "only the hidden app folder")
        XCTAssertEqual(q("code_challenge_method"), "S256")
        XCTAssertEqual(q("access_type"), "offline")
        XCTAssertEqual(q("response_type"), "code")
        XCTAssertEqual(q("client_id"), "123456-abcdef.apps.googleusercontent.com")
        XCTAssertNil(items.first { $0.name == "client_secret" })
        XCTAssertEqual(GoogleAuth.code(fromCallback: URL(string: "com.googleusercontent.apps.123456-abcdef:/oauth2redirect?code=4/xyz&scope=s")!), "4/xyz")
    }

    func testListPaginatesAndMapsVersionToRev() async throws {
        let (store, _) = try makeStore()
        var call = 0
        StubProtocol.handler = { req in
            call += 1
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer gtok")
            XCTAssertTrue(req.url!.absoluteString.contains("spaces=appDataFolder"))
            if call == 1 {
                return (200, [:], Data(#"{"files":[{"id":"i1","name":"header.json","version":"4"}],"nextPageToken":"p2"}"#.utf8))
            }
            XCTAssertTrue(req.url!.absoluteString.contains("pageToken=p2"))
            return (200, [:], Data(#"{"files":[{"id":"i2","name":"a.vitem","version":7}]}"#.utf8))
        }
        let files = try await store.listFiles()
        XCTAssertEqual(files, [RemoteFile(name: "header.json", rev: "4"), RemoteFile(name: "a.vitem", rev: "7")])
    }

    func testCreateSendsMultipartIntoTheAppDataFolder() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { req in
            if req.httpMethod == "GET" { return (200, [:], Data(#"{"files":[]}"#.utf8)) }  // find: not there yet
            return (200, [:], Data(#"{"id":"new1","version":"1"}"#.utf8))
        }
        let rev = try await store.upload("x.vitem", data: Data("CIPHERTEXT".utf8), expectedRev: nil)
        XCTAssertEqual(rev, "1")
        let post = try XCTUnwrap(StubProtocol.seen.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertTrue(post.url!.absoluteString.contains("uploadType=multipart"))
        XCTAssertTrue(try XCTUnwrap(post.value(forHTTPHeaderField: "Content-Type")).hasPrefix("multipart/related; boundary="))
        let body = String(decoding: try XCTUnwrap(post.httpBody ?? post.bodyStreamData()), as: UTF8.self)
        XCTAssertTrue(body.contains("\"parents\":[\"appDataFolder\"]"))
        XCTAssertTrue(body.contains("\"name\":\"x.vitem\""))
        XCTAssertTrue(body.contains("CIPHERTEXT"))
    }

    func testCreateWhenFileExistsIsAConflict() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { _ in (200, [:], Data(#"{"files":[{"id":"i1","name":"x.vitem","version":"3"}]}"#.utf8)) }
        do { _ = try await store.upload("x.vitem", data: Data(), expectedRev: nil); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .conflict) }
    }

    func testUpdateChecksTheVersionFirst() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { req in
            if req.httpMethod == "GET" { return (200, [:], Data(#"{"files":[{"id":"i1","name":"x.vitem","version":"3"}]}"#.utf8)) }
            return (200, [:], Data(#"{"id":"i1","version":"4"}"#.utf8))
        }
        // Stale revision: nothing may be written.
        StubProtocol.seen = []
        do { _ = try await store.upload("x.vitem", data: Data("new".utf8), expectedRev: "2"); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .conflict) }
        XCTAssertFalse(StubProtocol.seen.contains { $0.httpMethod == "PATCH" })
        // Current revision: PATCH to the file id.
        let rev = try await store.upload("x.vitem", data: Data("new".utf8), expectedRev: "3")
        XCTAssertEqual(rev, "4")
        let patch = try XCTUnwrap(StubProtocol.seen.last)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertTrue(patch.url!.path.hasSuffix("/files/i1"))
    }

    func testUpdateOfMissingFileIsNotFound() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { _ in (200, [:], Data(#"{"files":[]}"#.utf8)) }
        do { _ = try await store.upload("x.vitem", data: Data(), expectedRev: "1"); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .notFound) }
    }

    func testDownloadReturnsBytesAndVersion() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { req in
            if req.url!.absoluteString.contains("alt=media") { return (200, [:], Data("BYTES".utf8)) }
            return (200, [:], Data(#"{"files":[{"id":"i9","name":"a.vitem","version":"12"}]}"#.utf8))
        }
        let r = try await store.download("a.vitem")
        XCTAssertEqual(r.data, Data("BYTES".utf8))
        XCTAssertEqual(r.rev, "12")
    }

    func testFullDriveAndRateLimitAreMapped() async throws {
        let (store, _) = try makeStore()
        StubProtocol.handler = { _ in
            (403, [:], Data(#"{"error":{"code":403,"message":"The user's Drive storage quota has been exceeded.","errors":[{"reason":"storageQuotaExceeded"}]}}"#.utf8))
        }
        do { _ = try await store.listFiles(); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .quotaExceeded) }
        StubProtocol.handler = { _ in (403, [:], Data(#"{"error":{"message":"slow down","errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8)) }
        do { _ = try await store.listFiles(); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .rateLimited(retryAfter: 5)) }
        StubProtocol.handler = { _ in (429, ["Retry-After": "9"], Data()) }
        do { _ = try await store.listFiles(); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .rateLimited(retryAfter: 9)) }
    }

    func testExpiredTokenRefreshesAndKeepsTheRefreshToken() async throws {
        let (store, _) = try makeStore(accessExpired: true)
        StubProtocol.handler = { req in
            if req.url?.host == "oauth2.googleapis.com" { return (200, [:], Data(#"{"access_token":"fresh","expires_in":3599}"#.utf8)) }
            return (200, [:], Data(#"{"files":[]}"#.utf8))
        }
        _ = try await store.listFiles()
        XCTAssertEqual(StubProtocol.seen.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        let tokenCall = try XCTUnwrap(StubProtocol.seen.first { $0.url?.host == "oauth2.googleapis.com" })
        let form = String(decoding: try XCTUnwrap(tokenCall.httpBody ?? tokenCall.bodyStreamData()), as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=grefresh"))
        XCTAssertFalse(form.contains("client_secret"))
    }

    func testDropboxFullIsMappedToTheSameError() {
        XCTAssertEqual(DropboxRemoteStore.mapConflict(Data(#"{"error_summary":"path/insufficient_space/.."}"#.utf8)), .quotaExceeded)
    }
}

extension URLRequest {
    /// URLProtocol receives bodies as streams; read it back for assertions.
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class CloudSwitchTests: XCTestCase {
    func testSwitchingCloudUploadsEverythingToTheNewOne() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let session = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        try await session.upsert(loginItem("A"))
        try await session.upsert(loginItem("B"))

        let first = InMemoryRemote()
        _ = try await SyncEngine(session: session, remote: first).sync()
        await XCTAssertEqualA(try await first.listFiles().count, 1)

        // Move to a second, empty cloud.
        try await session.resetSyncState()
        let second = InMemoryRemote()
        let report = try await SyncEngine(session: session, remote: second).sync()
        XCTAssertEqual(report.pushed, 3)
        await XCTAssertEqualA(try await second.listFiles().count, 1, "everything is in the new cloud, in one file")
    }

    func testSwitchingToACloudThatAlreadyHasTheVaultMergesInsteadOfDuplicating() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let session = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        let item = loginItem("A")
        try await session.upsert(item)
        let cloud = InMemoryRemote()
        _ = try await SyncEngine(session: session, remote: cloud).sync()

        try await session.resetSyncState()  // pretend we are connecting to this same cloud again
        _ = try await SyncEngine(session: session, remote: cloud).sync()
        await XCTAssertEqualA(try await cloud.listFiles().count, 1)
        await XCTAssertEqualA(await session.allItems().count, 1)
        await XCTAssertEqualA(await session.item(item.id)?.name, "A")
    }

    func testFullCloudStopsSyncWithTheQuotaErrorAndKeepsLocalData() async throws {
        actor Full: RemoteStore {
            func listFiles() async throws -> [RemoteFile] { [] }
            func download(_ name: String) async throws -> (data: Data, rev: String) { throw RemoteError.notFound }
            func upload(_ name: String, data: Data, expectedRev: String?) async throws -> String { throw RemoteError.quotaExceeded }
        }
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let session = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        try await session.upsert(loginItem("A"))
        do {
            _ = try await SyncEngine(session: session, remote: Full()).sync()
            XCTFail("expected the quota error")
        } catch {
            XCTAssertEqual(error as? RemoteError, .quotaExceeded)
        }
        await XCTAssertEqualA(await session.allItems().count, 1)
    }
}
