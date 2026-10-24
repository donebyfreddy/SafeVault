import XCTest

@testable import MyVaultKit

/// Writes the `vault.db` that the Chrome extension's JS tests decrypt (Extension/test/fixtures).
/// Run with SAFEVAULT_FIXTURE_DIR=<dir> to regenerate; without it the test only checks the round trip.
final class ExtensionFixtureTests: XCTestCase {
    static let password = "Contraseña ñandú #1 \u{FB01}"  // "ﬁ" ligature: NFKC turns it into "fi"

    func testFixtureVault() async throws {
        let storage = makeStorage()
        defer { try? storage.destroy() }
        let s = try VaultSession.create(password: Self.password, storage: storage)  // 600k iterations, as shipped
        try await s.upsert(VaultItem(name: "Example", fields: [
            ItemField(label: "Username", value: "alex@example.com", type: .email),
            ItemField(label: "Password", value: "vX9#kQ2$mT7!pL4z ñ✓", type: .secret),
            ItemField(label: "Website", value: "https://www.example.com/login", type: .url),
        ]))
        try await s.upsert(VaultItem(name: "Local form", fields: [
            ItemField(label: "Username", value: "tester", type: .text),
            ItemField(label: "Password", value: "form-pass-123", type: .secret),
            ItemField(label: "Website", value: "localhost:8799", type: .url),
        ]))
        try await s.upsert(VaultItem(name: "Old", fields: [
            ItemField(label: "Username", value: "gone", type: .text),
            ItemField(label: "Password", value: "gone", type: .secret),
            ItemField(label: "Website", value: "https://example.com", type: .url),
        ], archived: true))
        try await s.upsert(VaultItem(kind: .card, name: "Bank card", fields: [
            ItemField(label: "Number", value: "4111111111111111", type: .secret),
            ItemField(label: "Website", value: "https://example.com", type: .url),
        ]))
        let file = try await s.exportSyncFile()
        XCTAssertNoThrow(try VaultFile.decode(file))
        if let dir = ProcessInfo.processInfo.environment["SAFEVAULT_FIXTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try file.write(to: URL(fileURLWithPath: dir).appendingPathComponent("vault.db"))
            try Data(Self.password.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("password.txt"))
        }
    }
}
