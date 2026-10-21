import XCTest

@testable import MyVaultKit

/// A big vault must stay quick: import, unlock, sync and join on a second device.
final class ScaleTests: XCTestCase {
    func testThousandsOfItemsStayFast() async throws {
        let items = (0..<2000).map { loginItem("Site \($0)", user: "user\($0)@example.com", pass: "pw-\($0)-\(UUID().uuidString.prefix(8))") }
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let remote = InMemoryRemote()

        var t = Date()
        let s = try VaultSession.create(password: "pw", storage: storage, iterations: 1000)
        try await s.importItems(items)
        let importTime = Date().timeIntervalSince(t)

        t = Date()
        let report = try await SyncEngine(session: s, remote: remote).sync()
        let syncTime = Date().timeIntervalSince(t)
        XCTAssertEqual(report.pushed, 2001)
        await XCTAssertEqualA(try await remote.listFiles().count, 1)

        t = Date()
        await s.lock()
        let reopened = try VaultSession.open(password: "pw", storage: storage)
        await XCTAssertEqualA(await reopened.allItems().count, 2000)
        let unlockTime = Date().timeIntervalSince(t)

        let other = makeStorage()
        defer { try? other.destroy() }
        try other.installDownloadedHeader(try VaultFile.headerData(from: try await remote.download(VaultFile.name).data))
        let s2 = try VaultSession.open(password: "pw", storage: other)
        t = Date()
        _ = try await SyncEngine(session: s2, remote: remote).sync()
        let joinTime = Date().timeIntervalSince(t)
        await XCTAssertEqualA(await s2.allItems().count, 2000)

        // One edit afterwards is a quick round trip too.
        var one = try await unwrapA(await s2.item(items[5].id)); one.name = "edited"
        try await s2.upsert(one)
        t = Date()
        _ = try await SyncEngine(session: s2, remote: remote).sync()
        let editTime = Date().timeIntervalSince(t)

        print("SCALE import=\(importTime)s sync=\(syncTime)s unlock=\(unlockTime)s join=\(joinTime)s edit=\(editTime)s")
        for (label, secs) in [("import", importTime), ("sync", syncTime), ("unlock", unlockTime), ("join", joinTime), ("edit", editTime)] {
            XCTAssertLessThan(secs, 6, "\(label) took \(secs)s with 2000 items")
        }
    }
}
