import XCTest

@testable import MyVaultKit

/// Two simulated devices that share one in-memory "Dropbox".
final class SyncTests: XCTestCase {
    struct Device {
        let storage: VaultStorage
        let session: VaultSession
        let engine: SyncEngine
    }

    let remote = InMemoryRemote()

    func deviceA() throws -> Device {
        let storage = makeStorage()
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        return Device(storage: storage, session: s, engine: SyncEngine(session: s, remote: remote))
    }

    /// A fresh device joins an existing vault: header comes from the remote, then the master password unlocks it.
    func deviceB() async throws -> Device {
        let storage = makeStorage()
        let (header, _) = try await remote.download(VaultStorage.headerName)
        try storage.installDownloadedHeader(header)
        let s = try VaultSession.open(password: "pw", storage: storage)
        return Device(storage: storage, session: s, engine: SyncEngine(session: s, remote: remote))
    }

    func testFirstDeviceUploadsHeaderAndItems() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        try await a.session.upsert(loginItem("Google"))
        let report = try await a.engine.sync()
        XCTAssertEqual(report.pushed, 1)
        let names = try await remote.listFiles().map(\.name).sorted()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains("header.json"))
        // The remote holds only ciphertext.
        for f in try await remote.listFiles() where f.name.hasSuffix(".vitem") {
            let text = String(decoding: try await remote.download(f.name).data, as: UTF8.self)
            XCTAssertFalse(text.contains("Google"))
        }
        let second = try await a.engine.sync()
        XCTAssertEqual(second.pushed, 0, "nothing changed, nothing uploaded")
    }

    func testSecondDeviceSeesItemsAndEditsRoundTrip() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        var item = loginItem("Google")
        try await a.session.upsert(item)
        _ = try await a.engine.sync()

        let b = try await deviceB()
        defer { try? b.storage.destroy() }
        let first = try await b.engine.sync()
        XCTAssertEqual(first.pulled, 1)
        await XCTAssertEqualA(await b.session.allItems().map(\.name), ["Google"])

        item = try await unwrapA(await b.session.item(item.id))
        item.setPassword("changed-on-B-1234")
        try await b.session.upsert(item)
        _ = try await b.engine.sync()
        let pulled = try await a.engine.sync()
        XCTAssertEqual(pulled.pulled, 1)
        await XCTAssertEqualA(await a.session.item(item.id)?.password, "changed-on-B-1234")
    }

    func testOfflineEditsSurviveAndSyncLater() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        try await a.session.upsert(loginItem("One"))
        _ = try await a.engine.sync()

        await remote.setOffline(true)
        try await a.session.upsert(loginItem("Two"))
        do {
            _ = try await a.engine.sync()
            XCTFail("expected offline error")
        } catch {
            XCTAssertEqual(error as? RemoteError, .offline)
        }
        await XCTAssertEqualA(await a.session.allItems().count, 2, "local data is untouched")

        await remote.setOffline(false)
        let report = try await a.engine.sync()
        XCTAssertEqual(report.pushed, 1)
    }

    func testConflictKeepsNewestAndKeepsTheOtherInHistory() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        let base = loginItem("Shared", pass: "base-password-1")
        try await a.session.upsert(base)
        _ = try await a.engine.sync()
        let b = try await deviceB()
        defer { try? b.storage.destroy() }
        _ = try await b.engine.sync()

        // Both edit the same item while offline from each other.
        var onA = try await unwrapA(await a.session.item(base.id))
        onA.setPassword("A-wrote-this-first", at: Date(timeIntervalSinceNow: -60))
        try await a.session.upsert(onA, touch: false)

        var onB = try await unwrapA(await b.session.item(base.id))
        onB.setPassword("B-wrote-this-later", at: Date())
        try await b.session.upsert(onB, touch: false)

        _ = try await a.engine.sync()  // A pushes first
        let reportB = try await b.engine.sync()  // B collides
        XCTAssertGreaterThanOrEqual(reportB.conflicts, 1)
        let winner = try await unwrapA(await b.session.item(base.id))
        XCTAssertEqual(winner.password, "B-wrote-this-later")
        XCTAssertTrue(
            winner.history.contains { $0.fields.contains { $0.value == "A-wrote-this-first" } },
            "the losing edit is kept, never discarded")

        _ = try await a.engine.sync()
        let converged = try await unwrapA(await a.session.item(base.id))
        XCTAssertEqual(converged.password, "B-wrote-this-later")
        XCTAssertFalse(converged.history.isEmpty)
    }

    func testDeletionPropagates() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        let item = loginItem("Temp")
        try await a.session.upsert(item)
        _ = try await a.engine.sync()
        let b = try await deviceB()
        defer { try? b.storage.destroy() }
        _ = try await b.engine.sync()
        await XCTAssertEqualA(await b.session.allItems().count, 1)

        try await a.session.delete(item.id)
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        await XCTAssertTrueA(await b.session.allItems().isEmpty)
    }

    func testEditBeatsStaleDeleteOnlyIfNewer() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        let item = loginItem("Keep")
        try await a.session.upsert(item)
        _ = try await a.engine.sync()
        let b = try await deviceB()
        defer { try? b.storage.destroy() }
        _ = try await b.engine.sync()

        try await a.session.delete(item.id)  // older
        var edited = try await unwrapA(await b.session.item(item.id))
        edited.name = "Keep (edited later)"
        edited.modifiedAt = Date(timeIntervalSinceNow: 120)
        try await b.session.upsert(edited, touch: false)

        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()
        await XCTAssertEqualA(await a.session.allItems().map(\.name), ["Keep (edited later)"])
    }

    func testFileRemovedFromRemoteIsUploadedAgain() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        let item = loginItem("Precious")
        try await a.session.upsert(item)
        _ = try await a.engine.sync()
        await remote.removeFile(VaultStorage.itemName(item.id))
        let report = try await a.engine.sync()
        XCTAssertEqual(report.pushed, 1)
        await XCTAssertTrueA(try await remote.listFiles().contains { $0.name == VaultStorage.itemName(item.id) })
    }

    func testCorruptRemoteRecordIsReportedAndLocalDataKept() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        let item = loginItem("Safe")
        try await a.session.upsert(item)
        _ = try await a.engine.sync()
        await remote.forceWrite(VaultStorage.itemName(item.id), data: Data("garbage".utf8))
        let report = try await a.engine.sync()
        XCTAssertEqual(report.failed, [VaultStorage.itemName(item.id)])
        await XCTAssertEqualA(await a.session.item(item.id)?.name, "Safe")
    }

    func testPasswordChangeReachesOtherDevice() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        try await a.session.upsert(loginItem("X"))
        _ = try await a.engine.sync()
        let b = try await deviceB()
        defer { try? b.storage.destroy() }
        _ = try await b.engine.sync()

        try await a.session.changePassword(old: "pw", new: "new-master", iterations: 1000)
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        await b.session.lock()
        XCTAssertThrowsError(try VaultSession.open(password: "pw", storage: b.storage))
        XCTAssertNoThrow(try VaultSession.open(password: "new-master", storage: b.storage))
    }

    func testDifferentVaultIsRefused() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        _ = try await a.engine.sync()
        let other = makeStorage()
        defer { try? other.destroy() }
        let s = try VaultSession.create(password: "pw", storage: other, iterations: 1000)
        let engine = SyncEngine(session: s, remote: remote)
        do {
            _ = try await engine.sync()
            XCTFail("must not merge two different vaults")
        } catch {
            XCTAssertEqual(error as? VaultError, .differentVault)
        }
    }
}
