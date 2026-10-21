import XCTest

@testable import MyVaultKit

/// Two simulated devices that share one in-memory "cloud", which holds a single vault.db.
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

    /// A fresh device joins an existing vault: the header comes out of vault.db, then the master password unlocks it.
    func deviceB() async throws -> Device {
        let storage = makeStorage()
        let file = try await remote.download(VaultFile.name).data
        try storage.installDownloadedHeader(try VaultFile.headerData(from: file))
        let s = try VaultSession.open(password: "pw", storage: storage)
        return Device(storage: storage, session: s, engine: SyncEngine(session: s, remote: remote))
    }

    func testTheCloudHoldsExactlyOneFileAndItIsUnreadable() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        for n in 1...25 { try await a.session.upsert(loginItem("Site \(n)", user: "canary-user-\(n)@example.com", pass: "PlainTextCanary-\(n)")) }
        let report = try await a.engine.sync()
        XCTAssertEqual(report.pushed, 26)
        let files = try await remote.listFiles()
        XCTAssertEqual(files.map(\.name), ["vault.db"], "25 items, one file")
        let text = String(decoding: try await remote.download("vault.db").data, as: UTF8.self)
        for needle in ["Site 1", "canary-user", "PlainTextCanary", "example.com"] { XCTAssertFalse(text.contains(needle), needle) }
        let again = try await a.engine.sync()
        XCTAssertEqual(again.pushed, 0, "nothing changed, nothing uploaded")
        await XCTAssertEqualA(await remote.uploadCount, 1)
    }

    func testUnchangedCloudIsNotDownloadedAgain() async throws {
        actor Counting: RemoteStore {
            let inner = InMemoryRemote()
            var downloads = 0
            func listFiles() async throws -> [RemoteFile] { try await inner.listFiles() }
            func download(_ name: String) async throws -> (data: Data, rev: String) { downloads += 1; return try await inner.download(name) }
            func upload(_ name: String, data: Data, expectedRev: String?) async throws -> String { try await inner.upload(name, data: data, expectedRev: expectedRev) }
        }
        let counting = Counting()
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        try await s.upsert(loginItem("A"))
        let engine = SyncEngine(session: s, remote: counting)
        _ = try await engine.sync()
        for _ in 0..<5 { _ = try await engine.sync() }
        await XCTAssertEqualA(await counting.downloads, 0, "polling an unchanged vault costs only a listing")
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
        await XCTAssertEqualA(await remote.uploadCount, 2)
    }

    func testConflictKeepsNewestAndKeepsTheOtherInHistory() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        var base = loginItem("Shared", pass: "base-password-1")
        base.createdAt = Date(timeIntervalSinceNow: -600)
        base.modifiedAt = base.createdAt
        try await a.session.upsert(base, touch: false)
        _ = try await a.engine.sync()
        let b = try await deviceB()
        defer { try? b.storage.destroy() }
        _ = try await b.engine.sync()

        var onA = try await unwrapA(await a.session.item(base.id))
        onA.setPassword("A-wrote-this-first", at: Date(timeIntervalSinceNow: -60))
        try await a.session.upsert(onA, touch: false)
        var onB = try await unwrapA(await b.session.item(base.id))
        onB.setPassword("B-wrote-this-later", at: Date())
        try await b.session.upsert(onB, touch: false)

        _ = try await a.engine.sync()
        let reportB = try await b.engine.sync()
        XCTAssertGreaterThanOrEqual(reportB.conflicts, 1)
        let winner = try await unwrapA(await b.session.item(base.id))
        XCTAssertEqual(winner.password, "B-wrote-this-later")
        XCTAssertTrue(winner.history.contains { $0.fields.contains { $0.value == "A-wrote-this-first" } }, "the losing edit is kept")

        _ = try await a.engine.sync()
        let converged = try await unwrapA(await a.session.item(base.id))
        XCTAssertEqual(converged.password, "B-wrote-this-later")
        // Both devices settle on the same item and stop uploading.
        XCTAssertEqual(converged.canonicalBytes, winner.canonicalBytes)
        let quiet = try await b.engine.sync()
        XCTAssertEqual(quiet.pushed, 0)
        XCTAssertEqual(converged.history.filter { $0.fields.contains { $0.value == "A-wrote-this-first" } }.count, 1, "no duplicate history")
    }

    func testTwoDevicesEditingDifferentItemsKeepBothEdits() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        let x = loginItem("X"), y = loginItem("Y")
        try await a.session.upsert(x)
        try await a.session.upsert(y)
        _ = try await a.engine.sync()
        let b = try await deviceB()
        defer { try? b.storage.destroy() }
        _ = try await b.engine.sync()

        var ax = try await unwrapA(await a.session.item(x.id)); ax.name = "X edited on A"
        try await a.session.upsert(ax)
        var by = try await unwrapA(await b.session.item(y.id)); by.name = "Y edited on B"
        try await b.session.upsert(by)

        _ = try await a.engine.sync()
        _ = try await b.engine.sync()  // merges A's edit and adds its own on top
        _ = try await a.engine.sync()
        for d in [a, b] { await XCTAssertEqualA(await d.session.allItems().map(\.name).sorted(), ["X edited on A", "Y edited on B"]) }
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

        try await a.session.delete(item.id)
        var edited = try await unwrapA(await b.session.item(item.id))
        edited.name = "Keep (edited later)"
        edited.modifiedAt = Date(timeIntervalSinceNow: 120)
        try await b.session.upsert(edited, touch: false)

        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()
        await XCTAssertEqualA(await a.session.allItems().map(\.name), ["Keep (edited later)"])
    }

    func testFileRemovedFromCloudIsUploadedAgain() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        try await a.session.upsert(loginItem("Precious"))
        _ = try await a.engine.sync()
        await remote.removeFile(VaultFile.name)
        try await a.session.upsert(loginItem("Another"))
        let report = try await a.engine.sync()
        XCTAssertEqual(report.pushed, 3)
        await XCTAssertEqualA(try await remote.listFiles().map(\.name), ["vault.db"])
    }

    func testUnreadableCloudFileIsNeverOverwritten() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        let item = loginItem("Safe")
        try await a.session.upsert(item)
        _ = try await a.engine.sync()
        await remote.forceWrite(VaultFile.name, data: Data("garbage".utf8))
        try await a.session.upsert(loginItem("Edited meanwhile"))
        do { _ = try await a.engine.sync(); XCTFail("must refuse") } catch { await XCTAssertEqualA(error as? VaultError, .corrupted) }
        await XCTAssertEqualA(try await remote.download(VaultFile.name).data, Data("garbage".utf8), "the cloud file was left alone")
        await XCTAssertEqualA(await a.session.allItems().count, 2, "local data is untouched")
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

    func testDifferentVaultIsRefusedAndNotOverwritten() async throws {
        let a = try deviceA()
        defer { try? a.storage.destroy() }
        _ = try await a.engine.sync()
        let before = try await remote.download(VaultFile.name).data
        let other = makeStorage()
        defer { try? other.destroy() }
        let s = try VaultSession.create(password: "pw", storage: other, iterations: 1000)
        try await s.upsert(loginItem("Mine"))
        do { _ = try await SyncEngine(session: s, remote: remote).sync(); XCTFail() } catch { await XCTAssertEqualA(error as? VaultError, .differentVault) }
        await XCTAssertEqualA(try await remote.download(VaultFile.name).data, before)
    }

    // MARK: Moving from the old one-file-per-item layout

    func testOldPerItemFilesAreMergedIntoVaultDbAndRemoved() async throws {
        // What the first versions of the app left in the cloud.
        let old = makeStorage()
        defer { try? old.destroy() }
        let oldSession = try VaultSession.create(password: "pw", storage: old, iterations: 1000)
        let items = [loginItem("Old A"), loginItem("Old B"), loginItem("Old C")]
        for i in items { try await oldSession.upsert(i) }
        _ = try await remote.upload("header.json", data: try await oldSession.headerData(), expectedRev: nil)
        for i in items { _ = try await remote.upload(VaultStorage.itemName(i.id), data: try await oldSession.encryptedBlob(for: i.id), expectedRev: nil) }
        await XCTAssertEqualA(try await remote.listFiles().count, 4)

        // The same vault on a device that has the new app.
        let storage = makeStorage()
        defer { try? storage.destroy() }
        try storage.installDownloadedHeader(try await remote.download("header.json").data)
        let s = try VaultSession.open(password: "pw", storage: storage)
        let report = try await SyncEngine(session: s, remote: remote).sync()
        XCTAssertEqual(report.failed, [])
        await XCTAssertEqualA(await s.allItems().map(\.name).sorted(), ["Old A", "Old B", "Old C"])
        await XCTAssertEqualA(try await remote.listFiles().map(\.name), ["vault.db"], "the clutter is gone")

        // And another device reads it from the single file.
        let other = makeStorage()
        defer { try? other.destroy() }
        try other.installDownloadedHeader(try VaultFile.headerData(from: try await remote.download("vault.db").data))
        let s2 = try VaultSession.open(password: "pw", storage: other)
        _ = try await SyncEngine(session: s2, remote: remote).sync()
        await XCTAssertEqualA(await s2.allItems().count, 3)
    }

    func testOldFilesAreKeptIfAnItemCannotBeRead() async throws {
        let old = makeStorage()
        defer { try? old.destroy() }
        let oldSession = try VaultSession.create(password: "pw", storage: old, iterations: 1000)
        let good = loginItem("Good"), bad = loginItem("Bad")
        try await oldSession.upsert(good)
        try await oldSession.upsert(bad)
        _ = try await remote.upload("header.json", data: try await oldSession.headerData(), expectedRev: nil)
        _ = try await remote.upload(VaultStorage.itemName(good.id), data: try await oldSession.encryptedBlob(for: good.id), expectedRev: nil)
        _ = try await remote.upload(VaultStorage.itemName(bad.id), data: Data("damaged".utf8), expectedRev: nil)

        let storage = makeStorage()
        defer { try? storage.destroy() }
        try storage.installDownloadedHeader(try await remote.download("header.json").data)
        let s = try VaultSession.open(password: "pw", storage: storage)
        let report = try await SyncEngine(session: s, remote: remote).sync()
        XCTAssertEqual(report.failed, [VaultStorage.itemName(bad.id)])
        let names = try await remote.listFiles().map(\.name)
        XCTAssertTrue(names.contains(VaultStorage.itemName(bad.id)), "a file that could not be read is never deleted")
        XCTAssertTrue(names.contains("vault.db"))
    }
}
