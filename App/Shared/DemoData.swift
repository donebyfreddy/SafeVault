#if DEBUG
import Foundation
import MyVaultKit

/// Fictional data for screenshots and UI work. Only compiled into debug builds and only used with `--demo`.
enum DemoData {
    static func items(now: Date = Date()) -> [VaultItem] {
        func ago(_ days: Double, hours: Double = 0) -> Date { now.addingTimeInterval(-(days * 86_400 + hours * 3_600)) }
        func login(
            _ name: String, _ user: String, _ pass: String, _ site: String, vault: String = "Personal",
            fav: Bool = false, totp: Bool = false, codes: Int = 0, used: Date? = nil, notes: String = "",
            created: Date, modified: Date
        ) -> VaultItem {
            var item = VaultItem(
                kind: .login, name: name, vault: vault,
                fields: [
                    ItemField(label: "Username", value: user, type: .email),
                    ItemField(label: "Password", value: pass, type: .secret),
                    ItemField(label: "Website", value: site, type: .url),
                ],
                notes: notes, favorite: fav, totpSecret: totp ? "JBSWY3DPEHPK3PXP" : nil,
                backupCodes: (0..<codes).map { _ in String(format: "%04d-%04d", Int.random(in: 0...9999), Int.random(in: 0...9999)) },
                createdAt: created, modifiedAt: modified, lastUsedAt: used)
            if fav || totp { item.passwordHistory = [PasswordHistoryEntry(value: "Old-Pass-1", changedAt: ago(200)), PasswordHistoryEntry(value: "Older-Pass-0", changedAt: ago(400))] }
            return item
        }
        let me = "alex.rivera"
        return [
            login("Google", "\(me)@example.com", "vX9#kQ2$mT7!pL4z", "https://accounts.google.com", fav: true, totp: true, codes: 8, used: ago(0, hours: 2), notes: "Main personal account. Used for Mail, Drive and Photos.", created: ago(1050), modified: ago(330)),
            login("Apple ID", "\(me)@example.net", "Hj4!rW8&nB2@cZ6e", "https://appleid.apple.com", fav: true, totp: true, codes: 4, used: ago(1), notes: "Recovery key is stored in the Emergency Kit note.", created: ago(1500), modified: ago(40)),
            login("Dropbox", "\(me)@example.com", "tY7$eM3#qK9!dF5x", "https://www.dropbox.com/login", fav: true, totp: true, codes: 10, used: ago(0, hours: 1), notes: "Hosts the encrypted vault file that syncs between devices.", created: ago(2000), modified: ago(220)),
            login("Netflix", "\(me)@example.com", "pC5&wL8!zR2#hN7v", "https://www.netflix.com/login", fav: true, used: ago(5), notes: "Family plan, shared with two people.", created: ago(900), modified: ago(300)),
            login("Amazon", "\(me)@example.com", "mB6@xQ4$jT9!gS3d", "https://www.amazon.com/ap/signin", used: ago(3), notes: "Prime account. Default address set to home.", created: ago(2400), modified: ago(120)),
            login("Airbnb", "\(me)@example.com", "Summer-Trip-2024", "https://www.airbnb.com/login", used: ago(14), created: ago(800), modified: ago(800)),
            login("Asana", "\(me)@studio.example.org", "kZ3#fD7!yW5&aH8n", "https://app.asana.com", vault: "Work", totp: true, codes: 6, used: ago(0, hours: 5), notes: "Team workspace. Billing handled by the studio.", created: ago(700), modified: ago(90)),
            login("Booking.com", "\(me)@example.com", "rN8!cV2$uE6#bJ4q", "https://account.booking.com", used: ago(30), notes: "Loyalty tier: Genius Level 2.", created: ago(1400), modified: ago(500)),
            login("Discord", "\(me)@example.com", "alex1234", "https://discord.com/login", used: ago(7), notes: "Short password. Replace it with a generated one.", created: ago(1100), modified: ago(1100)),
            login("Dropbox Business", "\(me)@studio.example.org", "Summer-Trip-2024", "https://www.dropbox.com/business", vault: "Work", used: ago(1), notes: "Studio shared drive.", created: ago(600), modified: ago(200)),
            login("Figma", "\(me)@studio.example.org", "gX2@tP9&sL5!mK7w", "https://www.figma.com/login", vault: "Work", used: ago(0, hours: 3), notes: "Design system library owner.", created: ago(850), modified: ago(60)),
            login("Fitness+", "\(me)@example.net", "bQ4!hR7$kV2#nY9c", "https://www.apple.com/apple-fitness-plus", used: ago(4), notes: "Shared through Family Sharing.", created: ago(300), modified: ago(300)),
            VaultItem(
                kind: .card, name: "Visa Platinum",
                fields: [
                    ItemField(label: "Cardholder", value: "ALEX RIVERA"),
                    ItemField(label: "Number", value: "4242 4242 4242 4242", type: .secret),
                    ItemField(label: "Expires", value: "09 / 28", type: .date),
                    ItemField(label: "CVV", value: "123", type: .secret),
                ], notes: "Test card number. Not a real card.", createdAt: ago(500), lastUsedAt: ago(9)),
            VaultItem(
                kind: .wifi, name: "Home Wi-Fi",
                fields: [
                    ItemField(label: "Network", value: "Lantern-5G"),
                    ItemField(label: "Password", value: "quiet-river-meadow-41", type: .secret),
                ], notes: "Guest network uses a separate password.", createdAt: ago(400)),
            VaultItem(
                kind: .identity, name: "Passport",
                fields: [
                    ItemField(label: "Full Name", value: "Alex Rivera"),
                    ItemField(label: "Number", value: "X0000000", type: .secret),
                    ItemField(label: "Expires", value: "14 Aug 2031", type: .date),
                ], notes: "Scans are stored encrypted inside the vault.", createdAt: ago(1200)),
            VaultItem(
                kind: .note, name: "Emergency Kit",
                fields: [ItemField(label: "Recovery Key", value: "DEMO-4F2A-91C7-B05E-3D68", type: .secret)],
                notes: "Print this and keep it somewhere safe. Never keep it only on a device.", createdAt: ago(1000)),
        ]
    }
}

final class DemoBiometricStore: BiometricKeyStore, @unchecked Sendable {
    var keys = [UUID: Data]()
    var biometryName: String { "Face ID" }
    var isAvailable: Bool { true }
    func hasKey(vaultID: UUID) -> Bool { keys[vaultID] != nil }
    func store(key: Data, vaultID: UUID) throws { keys[vaultID] = key }
    func load(vaultID: UUID, reason: String) async throws -> Data {
        guard let k = keys[vaultID] else { throw KeychainError.notStored }
        return k
    }
    func remove(vaultID: UUID) { keys[vaultID] = nil }
}

final class DemoSecretStore: SecretStore, @unchecked Sendable {
    var dict = [String: Data]()
    func read(_ account: String) -> Data? { dict[account] }
    func write(_ data: Data, account: String) throws { dict[account] = data }
    func delete(_ account: String) { dict[account] = nil }
}

enum DemoLaunch {
    static var args: [String] { CommandLine.arguments }
    static var isDemo: Bool { args.contains("--demo") || args.contains("--demo-lock") }

    @MainActor static func makeModel() -> AppModel {
        guard isDemo else { return AppModel() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("myvault-demo-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        let model = AppModel(storage: VaultStorage(root: dir), secrets: DemoSecretStore(), biometrics: DemoBiometricStore())
        model.demoMode = true
        return model
    }

    @MainActor static func applyIfRequested(to model: AppModel) async {
        guard isDemo else { return }
        guard await model.createVault(password: "demo", iterations: 1000), let session = model.session else { return }
        try? await session.importItems(DemoData.items())
        await model.refresh()
        await model.enableBiometrics()
        model.dropboxLinked = true
        model.dropboxEmail = "alex.rivera@example.com"
        model.syncStatus = .idle
        model.lastSync = Date().addingTimeInterval(-300)
        if let nav = args.first(where: { $0.hasPrefix("--nav=") })?.dropFirst(6) {
            switch nav {
            case "security": model.nav = .security
            case "settings": model.nav = .settings
            case "favorites": model.nav = .favorites
            case "cards": model.nav = .category(.card)
            default: break
            }
        }
        if let name = args.first(where: { $0.hasPrefix("--select=") })?.dropFirst(9),
           let item = model.items.first(where: { $0.name.lowercased().hasPrefix(name.lowercased()) }) {
            model.selectedID = item.id
        }
        if args.contains("--demo-lock") { model.lock() }
    }
}
#endif
