import MyVaultKit
import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum Nav: Hashable {
    case all, favorites, recent
    case vault(String)
    case category(ItemKind)
    case security, archived, settings
}

struct PendingDatabase {
    var url: URL
    var data: Data
}

struct ImportPreview {
    var result: ImportResult
    var unique: [VaultItem]
    var duplicates: Int
    var fileName: String
    var url: URL
    /// False for Safe's own live database: it must never be offered for deletion.
    var deletable = true
}

@MainActor @Observable
final class AppModel {
    enum Phase { case launching, setup, locked, unlocked }
    enum SyncStatus: Equatable { case notConfigured, idle, syncing, offline, failed(String) }

    // MARK: State

    var phase: Phase = .launching
    var items: [VaultItem] = []
    var nav: Nav = .all {
        didSet {
            guard nav != oldValue else { return }
            searchText = ""
            selectFirstIfNeeded()
        }
    }
    var selectedID: UUID?
    var searchText = ""
    var syncStatus: SyncStatus = .notConfigured
    var lastSync: Date?
    var dropboxLinked = false
    var dropboxEmail: String?
    var biometricEnabled = false
    var toast: String?
    var errorMessage: String?
    var unlockError: String?
    var busy = false
    /// UI requests coming from menu commands or other screens.
    var openItemRequest: UUID?
    var focusSearchTick = 0
    var newItemRequest: ItemKind?
    /// Debug screenshots only: turns off network sync.
    var demoMode = false
    var importPreview: ImportPreview?
    /// Safe's encrypted database, waiting for its master password.
    var pendingDatabase: PendingDatabase?
    var databaseError: String?
    /// Set after a successful import so the app can remind you to delete the plain-text file.
    var importedFile: URL?

    var autoLockSeconds: Int { didSet { defaults.set(autoLockSeconds, forKey: "autoLockSeconds") } }
    var clipboardSeconds: Int { didSet { defaults.set(clipboardSeconds, forKey: "clipboardSeconds") } }

    // MARK: Dependencies

    let storage: VaultStorage
    let secrets: SecretStore
    let biometrics: BiometricKeyStore
    private(set) var dropbox: DropboxAuth
    private(set) var session: VaultSession?
    private var engine: SyncEngine?
    private var lockTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var leftAt: Date?
    private let defaults = UserDefaults.standard

    static let masterRecheckDays = 7.0

    var dropboxConfigured: Bool { !dropboxAppKey.isEmpty }
    private(set) var dropboxAppKey: String

    init(storage: VaultStorage? = nil, secrets: SecretStore? = nil, biometrics: BiometricKeyStore? = nil) {
        let root = (try? VaultStorage.defaultRoot()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("MyVault")
        self.storage = storage ?? VaultStorage(root: root)
        let store = secrets ?? KeychainSecretStore()
        self.secrets = store
        self.biometrics = biometrics ?? KeychainBiometricStore()
        let built = (Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String) ?? ""
        let builtKey = built.hasPrefix("$(") ? "" : built
        // A key typed into the app is used when none was built in.
        let appKey = builtKey.isEmpty ? (UserDefaults.standard.string(forKey: "dropboxAppKey") ?? "") : builtKey
        self.dropboxAppKey = appKey
        self.dropbox = DropboxAuth(appKey: appKey, store: store)
        let d = UserDefaults.standard
        self.autoLockSeconds = d.object(forKey: "autoLockSeconds") as? Int ?? 60
        self.clipboardSeconds = d.object(forKey: "clipboardSeconds") as? Int ?? 30
    }

    var biometryName: String { biometrics.biometryName }
    var biometryAvailable: Bool { biometrics.isAvailable }

    // MARK: Launch

    func bootstrap() async {
        guard phase == .launching else { return }
        dropboxLinked = await dropbox.isLinked
        syncStatus = dropboxLinked ? .idle : .notConfigured
        refreshBiometricFlag()
        phase = storage.hasVault ? .locked : .setup
        if dropboxLinked { Task { dropboxEmail = await dropbox.accountEmail() } }
        #if DEBUG
        await DemoLaunch.applyIfRequested(to: self)
        #endif
    }

    private func bioKey(_ id: UUID) -> String { "biometric.\(id.uuidString.lowercased())" }

    private func refreshBiometricFlag() {
        guard let header = try? storage.loadHeader() else { biometricEnabled = false; return }
        biometricEnabled = defaults.bool(forKey: bioKey(header.vaultID)) && biometrics.hasKey(vaultID: header.vaultID)
    }

    // MARK: Create / unlock / lock

    @discardableResult
    func createVault(password: String, iterations: Int = VaultCrypto.defaultIterations) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let storage = self.storage
            let s = try await Task.detached { try VaultSession.create(password: password, storage: storage, iterations: iterations) }.value
            await adopt(s, viaPassword: true)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func unlock(password: String) async -> Bool {
        busy = true
        unlockError = nil
        defer { busy = false }
        do {
            let storage = self.storage
            let s = try await Task.detached { try VaultSession.open(password: password, storage: storage) }.value
            await adopt(s, viaPassword: true)
            return true
        } catch {
            unlockError = error.localizedDescription
            return false
        }
    }

    /// Whether Face ID / Touch ID can be offered right now. After a few days the master password is required again.
    var biometricUnlockOffered: Bool {
        guard biometricEnabled else { return false }
        guard let last = defaults.object(forKey: "lastMasterUnlock") as? Date else { return false }
        return Date().timeIntervalSince(last) < Self.masterRecheckDays * 86_400
    }

    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard biometricUnlockOffered, let header = try? storage.loadHeader() else {
            if biometricEnabled { unlockError = "For your security, enter your master password." }
            return false
        }
        unlockError = nil
        do {
            let data = try await biometrics.load(vaultID: header.vaultID, reason: "Unlock SafeVault")
            let storage = self.storage
            let s = try await Task.detached { try VaultSession.open(vaultKeyData: data, storage: storage) }.value
            await adopt(s, viaPassword: false)
            return true
        } catch KeychainError.userCancelled {
            return false
        } catch KeychainError.notStored {
            biometricEnabled = false
            unlockError = "\(biometryName) was reset. Enter your master password to set it up again."
            return false
        } catch {
            unlockError = error.localizedDescription
            return false
        }
    }

    private func adopt(_ s: VaultSession, viaPassword: Bool) async {
        session = s
        engine = nil
        items = await s.allItems()
        lastSync = await s.lastSync
        if viaPassword { defaults.set(Date(), forKey: "lastMasterUnlock") }
        refreshBiometricFlag()
        phase = .unlocked
        selectFirstIfNeeded()
        let unreadable = await s.unreadableItems.count
        if unreadable > 0 {
            errorMessage = "\(unreadable) item(s) could not be read and were left untouched. They may be damaged. Syncing again may repair them."
        }
        if dropboxLinked {
            syncStatus = .idle
            startPolling()
            scheduleSync(delay: .milliseconds(300))
        }
    }

    func lock() {
        lockTask?.cancel()
        syncTask?.cancel()
        pollTask?.cancel()
        let s = session
        session = nil
        engine = nil
        Task { await s?.lock() }
        items = []
        selectedID = nil
        searchText = ""
        importPreview = nil
        unlockError = nil
        if phase == .unlocked { phase = .locked }
    }

    // MARK: Biometrics

    @discardableResult
    func enableBiometrics() async -> Bool {
        guard let session else { return false }
        do {
            let header = await session.vaultID
            try biometrics.store(key: try await session.vaultKeyData(), vaultID: header)
            defaults.set(true, forKey: bioKey(header))
            defaults.set(Date(), forKey: "lastMasterUnlock")
            biometricEnabled = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            biometricEnabled = false
            return false
        }
    }

    func disableBiometrics() {
        guard let header = try? storage.loadHeader() else { return }
        biometrics.remove(vaultID: header.vaultID)
        defaults.set(false, forKey: bioKey(header.vaultID))
        biometricEnabled = false
    }

    // MARK: Editing

    func perform(_ work: @escaping (VaultSession) async throws -> Void) {
        guard let session else { return }
        Task {
            do {
                try await work(session)
                await refresh()
                scheduleSync()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard let session else { return }
        items = await session.allItems()
        selectFirstIfNeeded()
    }

    func save(_ item: VaultItem, select: Bool = true) {
        if select { selectedID = item.id }
        perform { try await $0.upsert(item) }
    }

    func delete(_ id: UUID) {
        let next = visibleItems.first { $0.id != id }?.id
        perform { try await $0.delete(id) }
        if selectedID == id { selectedID = next }
    }

    func toggleFavorite(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.favorite.toggle()
        perform { try await $0.upsert(item) }
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.archived = archived
        perform { try await $0.upsert(item) }
        showToast(archived ? "Archived" : "Restored")
    }

    func newItem(kind: ItemKind) -> VaultItem {
        var item = VaultItem(kind: kind, name: "")
        switch kind {
        case .login:
            item.fields = [
                ItemField(label: "Username", value: "", type: .text),
                ItemField(label: "Password", value: "", type: .secret),
                ItemField(label: "Website", value: "", type: .url),
            ]
        case .card:
            item.fields = [
                ItemField(label: "Cardholder", value: ""),
                ItemField(label: "Number", value: "", type: .secret),
                ItemField(label: "Expires", value: "", type: .date),
                ItemField(label: "CVV", value: "", type: .secret),
            ]
        case .identity:
            item.fields = [
                ItemField(label: "Full Name", value: ""),
                ItemField(label: "Number", value: "", type: .secret),
                ItemField(label: "Expires", value: "", type: .date),
            ]
        case .wifi:
            item.fields = [
                ItemField(label: "Network", value: ""),
                ItemField(label: "Password", value: "", type: .secret),
            ]
        case .note:
            break
        }
        if case .vault(let name) = nav { item.vault = name }
        return item
    }

    // MARK: Filtering

    var visibleItems: [VaultItem] {
        let base = items(for: nav)
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return items.filter { !$0.archived }.filter {
            "\($0.name) \($0.subtitle) \($0.website ?? "") \($0.tags.joined(separator: " "))".lowercased().contains(q)
        }
    }

    func items(for nav: Nav) -> [VaultItem] {
        let live = items.filter { !$0.archived }
        switch nav {
        case .all, .settings, .security: return live
        case .favorites: return live.filter(\.favorite)
        case .recent:
            return Array(live.filter { $0.lastUsedAt != nil }.sorted { $0.lastUsedAt! > $1.lastUsedAt! }.prefix(10))
        case .vault(let name): return live.filter { $0.vault == name }
        case .category(let kind): return live.filter { $0.kind == kind }
        case .archived: return items.filter(\.archived)
        }
    }

    func count(for nav: Nav) -> Int { items(for: nav).count }

    var vaultNames: [String] {
        let names = Set(items.map(\.vault)).union(["Personal", "Work"])
        return names.sorted()
    }

    func selectFirstIfNeeded() {
        if let id = selectedID, visibleItems.contains(where: { $0.id == id }) { return }
        selectedID = visibleItems.first?.id
    }

    var selectedItem: VaultItem? { items.first { $0.id == selectedID } }

    var report: SecurityReport { SecurityAudit.run(items) }

    // MARK: Sync

    func scheduleSync(delay: Duration = .seconds(2)) {
        guard dropboxLinked, phase == .unlocked, !demoMode else { return }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await syncNow()
            }
        }
    }

    func syncNow() async {
        guard let session, dropboxLinked, !demoMode, syncStatus != .syncing else { return }
        syncStatus = .syncing
        let engine = self.engine ?? SyncEngine(session: session, remote: DropboxRemoteStore(auth: dropbox))
        self.engine = engine
        do {
            let report = try await engine.sync()
            await refresh()
            lastSync = await session.lastSync
            syncStatus = .idle
            if !report.failed.isEmpty {
                syncStatus = .failed("\(report.failed.count) file(s) could not be synced.")
            }
        } catch RemoteError.offline {
            syncStatus = .offline
        } catch RemoteError.unauthorized {
            syncStatus = .failed("Dropbox needs you to sign in again.")
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
    }

    var syncDescription: String {
        switch syncStatus {
        case .notConfigured: return "Dropbox not connected"
        case .idle: return "Synced with Dropbox"
        case .syncing: return "Syncing with Dropbox…"
        case .offline: return "Offline · will sync later"
        case .failed: return "Sync problem"
        }
    }

    func connectDropbox(authenticate: @escaping (URL, String) async throws -> URL) async {
        guard dropboxConfigured else {
            errorMessage = "Paste your Dropbox app key in the \"One-time Dropbox setup\" box first, then press Connect Dropbox again."
            return
        }
        busy = true
        defer { busy = false }
        let (verifier, challenge) = DropboxAuth.makePKCE()
        guard let url = await dropbox.authorizeURL(challenge: challenge) else { return }
        do {
            let callback = try await authenticate(url, await dropbox.callbackScheme)
            guard let code = DropboxAuth.code(fromCallback: callback) else { throw RemoteError.unauthorized }
            try await dropbox.exchange(code: code, verifier: verifier)
            dropboxLinked = true
            syncStatus = .idle
            dropboxEmail = await dropbox.accountEmail()
            if phase == .unlocked {
                startPolling()
                scheduleSync(delay: .milliseconds(200))
            }
        } catch {
            if (error as NSError).code == 1, (error as NSError).domain == "com.apple.AuthenticationServices.WebAuthenticationSession" { return }  // cancelled
            errorMessage = error.localizedDescription
        }
    }

    /// Lets you paste your Dropbox app key in the app instead of rebuilding it into the project.
    /// The key is public (the login uses PKCE, with no secret), so it is kept in the app's settings.
    @discardableResult
    func saveDropboxAppKey(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 8, key.count <= 40, key.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            errorMessage = "That does not look like a Dropbox app key. It is a short mix of letters and numbers shown in the App Console, under Settings."
            return false
        }
        defaults.set(key, forKey: "dropboxAppKey")
        dropboxAppKey = key
        dropbox = DropboxAuth(appKey: key, store: secrets)
        dropboxLinked = false
        engine = nil
        syncStatus = .notConfigured
        return true
    }

    func disconnectDropbox() async {
        await dropbox.unlink()
        dropboxLinked = false
        dropboxEmail = nil
        syncStatus = .notConfigured
        engine = nil
        pollTask?.cancel()
    }

    /// For a new device: fetches the vault header from Dropbox so the master password can unlock it.
    func fetchVaultFromDropbox() async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let remote = DropboxRemoteStore(auth: dropbox)
            guard try await remote.listFiles().contains(where: { $0.name == VaultStorage.headerName }) else {
                errorMessage = "There is no SafeVault in this Dropbox account yet. Create the vault on your other device first, or create a new one here."
                return false
            }
            let (data, _) = try await remote.download(VaultStorage.headerName)
            try storage.installDownloadedHeader(data)
            phase = .locked
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: Import / export

    func prepareImport(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "db" || SafeInCloudDatabase.looksLikeDatabase(data) {
                databaseError = nil
                pendingDatabase = PendingDatabase(url: url, data: data)
                return
            }
            let result = try SafeImporter.parse(data: data)
            let (unique, dupes) = SafeImporter.removingDuplicates(result.items, existing: items)
            importPreview = ImportPreview(result: result, unique: unique, duplicates: dupes, fileName: url.lastPathComponent, url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reads Safe's own database file with Safe's master password. The password is used once and never stored.
    func openSafeDatabase(password: String) async -> Bool {
        guard let pending = pendingDatabase else { return false }
        busy = true
        defer { busy = false }
        do {
            let data = pending.data
            let result = try await Task.detached { try SafeImporter.parse(safeDatabase: data, password: password) }.value
            let (unique, dupes) = SafeImporter.removingDuplicates(result.items, existing: items)
            importPreview = ImportPreview(
                result: result, unique: unique, duplicates: dupes,
                fileName: pending.url.lastPathComponent, url: pending.url, deletable: false)
            pendingDatabase = nil
            databaseError = nil
            return true
        } catch VaultError.wrongPassword {
            databaseError = "That is not the master password of this Safe database. Use the one you type in Safe."
        } catch {
            databaseError = "This file could not be read as a Safe database (\(error.localizedDescription)). Export it from Safe as XML and import that instead."
        }
        return false
    }

    func confirmImport() async {
        guard let preview = importPreview, let session else { return }
        importPreview = nil
        do {
            try await session.importItems(preview.unique)
            await refresh()
            scheduleSync(delay: .milliseconds(500))
            showToast("Imported \(preview.unique.count) items")
            if preview.deletable { importedFile = preview.url }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves the imported plain-text file to the Trash (Mac) or deletes it (iPhone), if the system allows it.
    func deleteImportedFile() {
        guard let url = importedFile else { return }
        importedFile = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            #if os(macOS)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            #else
            try FileManager.default.removeItem(at: url)
            #endif
            showToast("File deleted")
        } catch {
            errorMessage = "The file could not be deleted automatically. Please delete \"\(url.lastPathComponent)\" yourself: it contains your passwords in plain text."
        }
    }

    func makeBackup() async -> Data? {
        guard let session else { return nil }
        do { return try await session.exportBackup() } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func restoreBackup(from url: URL) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try VaultSession.restoreBackup(try Data(contentsOf: url), into: storage)
            phase = .locked
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func changeMasterPassword(old: String, new: String) async -> Bool {
        guard let session else { return false }
        busy = true
        defer { busy = false }
        do {
            try await Task.detached { try await session.changePassword(old: old, new: new) }.value
            defaults.set(Date(), forKey: "lastMasterUnlock")
            scheduleSync(delay: .milliseconds(300))
            showToast("Master password changed")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: App lifecycle

    func appLeft() {
        guard phase == .unlocked else { return }
        if leftAt == nil { leftAt = Date() }
        lockTask?.cancel()
        let seconds = autoLockSeconds
        if seconds <= 0 { lock(); return }
        lockTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            lock()
        }
    }

    func appReturned() {
        lockTask?.cancel()
        defer { leftAt = nil }
        if phase == .unlocked, let t = leftAt, Date().timeIntervalSince(t) >= Double(autoLockSeconds) {
            lock()
        } else if phase == .unlocked {
            scheduleSync(delay: .milliseconds(300))
        }
    }

    // MARK: Feedback

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toast == text { toast = nil }
        }
    }

    func copy(_ value: String, label: String, itemID: UUID? = nil) {
        Clipboard.copy(value, clearAfter: clipboardSeconds)
        showToast("\(label) copied")
        if let itemID { perform { try await $0.markUsed(itemID) } }
    }
}

enum Clipboard {
    @MainActor static func copy(_ value: String, clearAfter seconds: Int) {
        #if canImport(UIKit)
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if seconds > 0 { options[.expirationDate] = Date().addingTimeInterval(TimeInterval(seconds)) }
        UIPasteboard.general.setItems([["public.utf8-plain-text": value]], options: options)
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        // Tell clipboard managers not to record it.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        if seconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
                if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            }
        }
        #endif
    }
}
