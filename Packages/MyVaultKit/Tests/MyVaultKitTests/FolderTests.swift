import XCTest

@testable import MyVaultKit

final class FolderTests: XCTestCase {
    func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("myvault-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testNames() {
        XCTAssertEqual(FolderRemoteStore.canonicalName(of: ".header.json.icloud"), "header.json")
        XCTAssertEqual(FolderRemoteStore.canonicalName(of: "header.json"), "header.json")
        let id = UUID().uuidString.lowercased()
        XCTAssertEqual(FolderRemoteStore.conflictBaseName(of: "\(id) 2.vitem"), "\(id).vitem")
        XCTAssertEqual(FolderRemoteStore.conflictBaseName(of: "\(id) (1).vitem"), "\(id).vitem")
        XCTAssertEqual(FolderRemoteStore.conflictBaseName(of: "header 2.json"), "header.json")
        XCTAssertEqual(FolderRemoteStore.conflictBaseName(of: ".\(id) 3.vitem.icloud"), "\(id).vitem")
        XCTAssertEqual(FolderRemoteStore.conflictBaseName(of: "vault 2.db"), "vault.db")
        XCTAssertNil(FolderRemoteStore.conflictBaseName(of: "\(id).vitem"))
        XCTAssertNil(FolderRemoteStore.conflictBaseName(of: "notes 2.txt"))
        XCTAssertNil(FolderRemoteStore.conflictBaseName(of: "holiday photo 2.vitem"))
    }

    func testListUploadDownloadSemantics() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FolderRemoteStore(root: dir)
        try Data("x".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("photo.jpg"))
        let id = UUID().uuidString.lowercased()
        let name = "\(id).vitem"

        await XCTAssertEqualA(try await store.listFiles(), [], "unrelated files are ignored")
        let rev1 = try await store.upload(name, data: Data("one".utf8), expectedRev: nil)
        do { _ = try await store.upload(name, data: Data(), expectedRev: nil); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .conflict) }
        do { _ = try await store.upload(name, data: Data(), expectedRev: "stale"); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .conflict) }
        do { _ = try await store.upload("\(UUID().uuidString.lowercased()).vitem", data: Data(), expectedRev: "1-1"); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .notFound) }

        try await Task.sleep(for: .milliseconds(20))
        let rev2 = try await store.upload(name, data: Data("two-two".utf8), expectedRev: rev1)
        XCTAssertNotEqual(rev1, rev2)
        let got = try await store.download(name)
        XCTAssertEqual(got.data, Data("two-two".utf8))
        XCTAssertEqual(got.rev, rev2)
        await XCTAssertEqualA(try await store.listFiles(), [RemoteFile(name: name, rev: rev2)])
        do { _ = try await store.download("\(UUID().uuidString.lowercased()).vitem"); XCTFail() } catch { await XCTAssertEqualA(error as? RemoteError, .notFound) }
    }

    func testMissingFolderGivesAClearError() async {
        let store = FolderRemoteStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)"))
        do { _ = try await store.listFiles(); XCTFail() } catch { await XCTAssertTrueA((error as? RemoteError).map { if case .server = $0 { true } else { false } } ?? false) }
    }

    func testResolveMovesTheCopyAndNeverDeletesIt() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FolderRemoteStore(root: dir)
        let id = UUID().uuidString.lowercased()
        try Data("loser".utf8).write(to: dir.appendingPathComponent("\(id) 2.vitem"))
        let copies = try await store.conflictCopies()
        XCTAssertEqual(copies.map(\.baseName), ["\(id).vitem"])
        XCTAssertEqual(copies.first?.data, Data("loser".utf8))
        await XCTAssertEqualA(try await store.listFiles(), [], "a conflict copy is not a normal file")
        try await store.resolveConflictCopy(copies[0].fileName)
        await XCTAssertEqualA(try await store.conflictCopies(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Resolved conflicts/\(id) 2.vitem").path))
    }

    // MARK: Two devices through one shared folder (what iCloud Drive does for you)

    func testTwoDevicesSyncThroughAFolder() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let remote = FolderRemoteStore(root: dir)

        let a = makeStorage(), b = makeStorage()
        defer { try? a.destroy(); try? b.destroy() }
        let sa = try VaultSession.create(password: "pw", storage: a, iterations: 1000)
        var item = loginItem("Google")
        try await sa.upsert(item)
        _ = try await SyncEngine(session: sa, remote: remote).sync()
        await XCTAssertEqualA(try await remote.listFiles().count, 1)

        let header = try VaultFile.headerData(from: try await remote.download(VaultFile.name).data)
        try b.installDownloadedHeader(header)
        let sb = try VaultSession.open(password: "pw", storage: b)
        _ = try await SyncEngine(session: sb, remote: remote).sync()
        await XCTAssertEqualA(await sb.allItems().map(\.name), ["Google"])

        item = try await unwrapA(await sb.item(item.id))
        item.setPassword("changed-on-B-1234")
        try await sb.upsert(item)
        _ = try await SyncEngine(session: sb, remote: remote).sync()
        _ = try await SyncEngine(session: sa, remote: remote).sync()
        await XCTAssertEqualA(await sa.item(item.id)?.password, "changed-on-B-1234")
    }

    func testICloudStyleConflictCopyIsMergedAndKept() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let remote = FolderRemoteStore(root: dir)
        let a = makeStorage(), b = makeStorage()
        defer { try? a.destroy(); try? b.destroy() }

        let sa = try VaultSession.create(password: "pw", storage: a, iterations: 1000)
        let base = loginItem("Shared", pass: "base-password-1")
        try await sa.upsert(base)
        _ = try await SyncEngine(session: sa, remote: remote).sync()
        try b.installDownloadedHeader(try VaultFile.headerData(from: try await remote.download(VaultFile.name).data))
        let sb = try VaultSession.open(password: "pw", storage: b)
        _ = try await SyncEngine(session: sb, remote: remote).sync()

        // B edits and syncs; A edited earlier but its vault.db landed as an iCloud "conflict copy".
        var onB = try await unwrapA(await sb.item(base.id))
        onB.setPassword("B-newest-edit-77", at: Date())
        try await sb.upsert(onB, touch: false)
        _ = try await SyncEngine(session: sb, remote: remote).sync()

        var onA = try await unwrapA(await sa.item(base.id))
        onA.setPassword("A-older-edit-11", at: Date(timeIntervalSinceNow: -120))
        try await sa.upsert(onA, touch: false)
        try await sa.exportSyncFile().write(to: dir.appendingPathComponent("vault 2.db"))

        let report = try await SyncEngine(session: sb, remote: remote).sync()
        XCTAssertGreaterThanOrEqual(report.conflicts, 1)
        let merged = try await unwrapA(await sb.item(base.id))
        XCTAssertEqual(merged.password, "B-newest-edit-77", "the most recent edit wins")
        XCTAssertTrue(merged.history.contains { $0.fields.contains { $0.value == "A-older-edit-11" } }, "the other edit is kept")
        await XCTAssertEqualA(try await remote.conflictCopies(), [], "the copy was set aside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Resolved conflicts/vault 2.db").path))
    }

    func testDeleteFileRemovesIt() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let remote = FolderRemoteStore(root: dir)
        _ = try await remote.upload("header.json", data: Data("x".utf8), expectedRev: nil)
        try await remote.deleteFile("header.json")
        await XCTAssertEqualA(try await remote.listFiles(), [])
        try await remote.deleteFile("header.json")  // deleting what is not there is fine
    }
}
