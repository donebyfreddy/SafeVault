import XCTest

@testable import MyVaultKit

func makeStorage() -> VaultStorage {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("myvault-test-\(UUID().uuidString)")
    return VaultStorage(root: dir)
}

func loginItem(_ name: String, user: String = "alex@example.com", pass: String = "vX9#kQ2$mT7!pL4z") -> VaultItem {
    VaultItem(name: name, fields: [
        ItemField(label: "Username", value: user, type: .email),
        ItemField(label: "Password", value: pass, type: .secret),
        ItemField(label: "Website", value: "https://example.com", type: .url),
    ])
}

final class SessionTests: XCTestCase {
    func testCreateStoreReopen() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        let item = loginItem("Google")
        try await s.upsert(item)
        await s.lock()
        await XCTAssertEqualA(await s.allItems().count, 0, "locking clears memory")

        let again = try VaultSession.open(password: "pw", storage: storage)
        let loaded = try await unwrapA(await again.item(item.id))
        XCTAssertEqual(loaded.name, "Google")
        XCTAssertEqual(loaded.password, "vX9#kQ2$mT7!pL4z")
        XCTAssertEqual(loaded.username, "alex@example.com")
        XCTAssertThrowsError(try VaultSession.open(password: "nope", storage: storage))
    }

    func testNothingReadableOnDisk() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        try await s.upsert(loginItem("TopSecretName", pass: "PlainTextCanary-123"))
        let all = try FileManager.default.subpathsOfDirectory(atPath: storage.root.path)
        for rel in all {
            let url = storage.root.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertFalse(text.contains("TopSecretName"), rel)
            XCTAssertFalse(text.contains("PlainTextCanary"), rel)
            XCTAssertFalse(text.contains("alex@example.com"), rel)
        }
    }

    func testDeleteLeavesScrubbedTombstone() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        var item = loginItem("Old")
        item.notes = "private"
        try await s.upsert(item)
        try await s.delete(item.id)
        await XCTAssertNilA(await s.item(item.id))
        await XCTAssertTrueA(await s.allItems().isEmpty)
        let raw = try await unwrapA(await s.rawItem(item.id))
        XCTAssertTrue(raw.deleted)
        XCTAssertTrue(raw.fields.isEmpty)
        XCTAssertEqual(raw.notes, "")

        let reopened = try VaultSession.open(password: "pw", storage: storage)
        await XCTAssertTrueA(await reopened.allItems().isEmpty)
    }

    func testTamperedRecordIsSkippedNotFatal() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        let a = loginItem("A"), b = loginItem("B")
        try await s.upsert(a)
        try await s.upsert(b)
        var blob = try storage.readBlob(id: a.id)
        blob[blob.count - 1] ^= 0xFF
        try storage.writeBlob(blob, id: a.id)

        let reopened = try VaultSession.open(password: "pw", storage: storage)
        await XCTAssertEqualA(await reopened.allItems().map(\.name), ["B"])
        await XCTAssertEqualA(await reopened.unreadableItems, [a.id])
    }

    func testRecordCannotBeSwappedForAnother() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        let a = loginItem("A"), b = loginItem("B")
        try await s.upsert(a)
        try await s.upsert(b)
        try storage.writeBlob(try storage.readBlob(id: a.id), id: b.id)  // B's file now holds A's record
        let reopened = try VaultSession.open(password: "pw", storage: storage)
        await XCTAssertEqualA(await reopened.allItems().map(\.name), ["A"])
    }

    func testBiometricStyleOpenWithKey() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        try await s.upsert(loginItem("A"))
        let keyData = try await s.vaultKeyData()
        let viaKey = try VaultSession.open(vaultKeyData: keyData, storage: storage)
        await XCTAssertEqualA(await viaKey.allItems().count, 1)
        XCTAssertThrowsError(try VaultSession.open(vaultKeyData: VaultCrypto.randomBytes(32), storage: storage))
        XCTAssertThrowsError(try VaultSession.open(vaultKeyData: Data(count: 5), storage: storage))
    }

    func testChangePasswordKeepsItems() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "old", storage: storage, iterations: 1000)
        try await s.upsert(loginItem("A"))
        try await s.changePassword(old: "old", new: "new", iterations: 1000)
        XCTAssertThrowsError(try VaultSession.open(password: "old", storage: storage))
        let reopened = try VaultSession.open(password: "new", storage: storage)
        await XCTAssertEqualA(await reopened.allItems().count, 1)
        await XCTAssertTrueA(await reopened.currentState().headerDirty)
    }

    func testBackupAndRestore() async throws {
        let src = makeStorage(), dst = makeStorage()
        defer { try? src.destroy(); try? dst.destroy() }
        let s = try VaultSession.create(password: "pw", storage: src, iterations: 1000)
        try await s.upsert(loginItem("A"))
        try await s.upsert(loginItem("B"))
        let backup = try await s.exportBackup()
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("alex@example.com"))

        try VaultSession.restoreBackup(backup, into: dst)
        let restored = try VaultSession.open(password: "pw", storage: dst)
        await XCTAssertEqualA(await restored.allItems().map(\.name), ["A", "B"])
        XCTAssertThrowsError(try VaultSession.restoreBackup(backup, into: dst), "never overwrite an existing vault")
        XCTAssertThrowsError(try VaultSession.restoreBackup(Data("junk".utf8), into: makeStorage()))
    }

    func testPasswordHistoryAndSubtitle() {
        var item = loginItem("X")
        item.setPassword("new-password-1")
        item.setPassword("new-password-2")
        XCTAssertEqual(item.passwordHistory.map(\.value), ["new-password-1", "vX9#kQ2$mT7!pL4z"])
        XCTAssertEqual(item.password, "new-password-2")
        XCTAssertEqual(item.subtitle, "alex@example.com")
        let card = VaultItem(kind: .card, name: "Visa", fields: [ItemField(label: "Number", value: "4242424242424242", type: .secret)])
        XCTAssertEqual(card.subtitle, "•••• 4242")
    }
}
