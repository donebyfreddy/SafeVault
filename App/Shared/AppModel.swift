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

enum CloudProvider: String, CaseIterable, Identifiable {
    case folder, dropbox, googleDrive
    var id: String { rawValue }
    /// `folder` is any folder you pick in Files; iCloud Drive is the usual choice.
    var title: String {
        switch self {
        case .folder: "iCloud Drive"
        case .dropbox: "Dropbox"
        case .googleDrive: "Google Drive"
        }
    }
}

@MainActor @Observable
final class AppModel {
    enum Phase { case launching, setup, locked, unlocked }
    enum SyncStatus: Equatable { case notConfigured, idle, syncing, offline, quotaExceeded, failed(String) }

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
    var googleLinked = false
    var folderLinked = false
    var folderName: String?
    private var folderURL: URL?
    private var folderAccess = false
    /// Which cloud keeps the encrypted copy of the vault. You choose it in Settings or when joining a vault.
    var provider: CloudProvider = .dropbox {
        didSet { if provider != oldValue { defaults.set(provider.rawValue, forKey: "syncProvider") } }
    }
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

    /// Stops syncing without disconnecting the cloud. Everything stays on this device until you resume.
    var syncPaused: Bool {
        didSet {
            defaults.set(syncPaused, forKey: "syncPaused")
            if syncPaused {
                syncTask?.cancel()
                pollTask?.cancel()
            } else if syncLinked, phase == .unlocked {
                startPolling()
                scheduleSync(delay: .milliseconds(200))
            }
        }
    }

    /// Look for each site's logo and keep it with the entry. The request goes to the site itself, nowhere else.
    var autoLogos: Bool { didSet { defaults.set(autoLogos, forKey: "autoLogos") } }
    var logosBusy = false

    var autoLockSeconds: Int { didSet { defaults.set(autoLockSeconds, forKey: "autoLockSeconds") } }
    var clipboardSeconds: Int { didSet { defaults.set(clipboardSeconds, forKey: "clipboardSeconds") } }

    // MARK: Dependencies

    let storage: VaultStorage
    let secrets: SecretStore
    let biometrics: BiometricKeyStore
    private(set) var dropbox: DropboxAuth
    private(set) var google: GoogleAuth
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
    var googleConfigured: Bool { GoogleAuth.normalizedClientID(googleClientID) != nil }
    private(set) var googleClientID: String

    var cloudConfigured: Bool {
        switch provider {
        case .folder: true
        case .dropbox: dropboxConfigured
        case .googleDrive: googleConfigured
        }
    }
    var syncLinked: Bool { isLinked(provider) }

    func isLinked(_ p: CloudProvider) -> Bool {
        switch p {
        case .folder: folderLinked
        case .dropbox: dropboxLinked
        case .googleDrive: googleLinked
        }
    }

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
        let gid = UserDefaults.standard.string(forKey: "googleClientID") ?? ""
        self.googleClientID = gid
        self.google = GoogleAuth(clientID: gid, store: store)
        let d = UserDefaults.standard
        self.provider = CloudProvider(rawValue: d.string(forKey: "syncProvider") ?? "") ?? .folder
        self.syncPaused = d.bool(forKey: "syncPaused")
        self.autoLogos = d.object(forKey: "autoLogos") as? Bool ?? true
        self.autoLockSeconds = d.object(forKey: "autoLockSeconds") as? Int ?? 60
        self.clipboardSeconds = d.object(forKey: "clipboardSeconds") as? Int ?? 30
    }

    var biometryName: String { biometrics.biometryName }
    var biometryAvailable: Bool { biometrics.isAvailable }

    // MARK: Launch

    func bootstrap() async {
        guard phase == .launching else { return }
        dropboxLinked = await dropbox.isLinked
        googleLinked = await google.isLinked
        // If the chosen cloud is not connected but the other one is, use the one that works.
        restoreFolder()
        if !syncLinked, let other = CloudProvider.allCases.first(where: { isLinked($0) }) { provider = other }
        syncStatus = syncLinked ? .idle : .notConfigured
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
        // Trust the saved setting. Asking the keychain whether the key is still there can itself trigger a second
        // Face ID prompt; if the key was invalidated, the next real use finds out and falls back to the password.
        biometricEnabled = defaults.bool(forKey: bioKey(header.vaultID))
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

    private var biometricInFlight = false

    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        // One prompt at a time: a second request while Face ID is already open is ignored.
        guard !biometricInFlight else { return false }
        biometricInFlight = true
        defer { biometricInFlight = false }
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
        if defaults.bool(forKey: "syncResetPending") {
            try? await s.resetSyncState()
            defaults.set(false, forKey: "syncResetPending")
        }
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
        if syncLinked, !syncPaused {
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

    /// For a forgotten master password: there is no recovery, so the only way forward is a new vault.
    /// Deletes the vault on this device. Copies in the cloud are not touched.
    func eraseVault() {
        disableBiometrics()
        lock()
        try? storage.destroy()
        defaults.removeObject(forKey: "lastMasterUnlock")
        defaults.removeObject(forKey: "syncResetPending")
        items = []
        engine = nil
        unlockError = nil
        phase = .setup
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
        let fresh = await session.allItems()
        if fresh != items { items = fresh }
        selectFirstIfNeeded()
    }

    func save(_ item: VaultItem, select: Bool = true) {
        if select { selectedID = item.id }
        perform { try await $0.upsert(item) }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await ensureIcon(for: item.id)
        }
    }

    // MARK: Logos

    private func needsIcon(_ item: VaultItem) -> Bool {
        guard autoLogos, item.kind == .login, item.iconCustom != true, item.icon == nil, item.website != nil else { return false }
        // A site that had no logo is not asked again for a month.
        return item.iconCheckedAt.map { Date().timeIntervalSince($0) > 30 * 86_400 } ?? true
    }

    func ensureIcon(for id: UUID) async {
        guard let session, let item = items.first(where: { $0.id == id }), needsIcon(item), let site = item.website else { return }
        let data = await SiteIcon.fetch(website: site)
        guard var fresh = await session.item(id), fresh.iconCustom != true, fresh.icon == nil else { return }
        fresh.icon = data
        fresh.iconCheckedAt = Date()
        try? await session.upsert(fresh, touch: false)
        await refresh()
        scheduleSync()
    }

    /// Looks up the logo of every entry that has a website and no logo yet. A few at a time, in the background.
    @discardableResult
    func fetchMissingIcons() async -> (found: Int, tried: Int) {
        guard let session, !logosBusy else { return (0, 0) }
        let targets = items.filter(needsIcon)
        guard !targets.isEmpty else { return (0, 0) }
        logosBusy = true
        defer { logosBusy = false }
        var found = 0
        var start = 0
        while start < targets.count {
            let chunk = Array(targets[start..<min(start + 4, targets.count)])
            start += 4
            let results = await withTaskGroup(of: (UUID, Data?).self) { group -> [(UUID, Data?)] in
                for item in chunk {
                    guard let site = item.website else { continue }
                    group.addTask { (item.id, await SiteIcon.fetch(website: site)) }
                }
                var all = [(UUID, Data?)]()
                for await r in group { all.append(r) }
                return all
            }
            for (id, data) in results {
                guard var fresh = await session.item(id), fresh.iconCustom != true, fresh.icon == nil else { continue }
                fresh.icon = data
                fresh.iconCheckedAt = Date()
                try? await session.upsert(fresh, touch: false)
                if data != nil { found += 1 }
            }
            if phase != .unlocked { break }
        }
        await refresh()
        scheduleSync()
        return (found, targets.count)
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

    /// The four counters of the iPhone home screen, in a single pass over the items.
    var chipCounts: (all: Int, favorites: Int, logins: Int, cards: Int) {
        var all = 0, favorites = 0, logins = 0, cards = 0
        for item in items where !item.archived {
            all += 1
            if item.favorite { favorites += 1 }
            if item.kind == .login { logins += 1 } else if item.kind == .card { cards += 1 }
        }
        return (all, favorites, logins, cards)
    }

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

    func makeRemote() -> RemoteStore {
        switch provider {
        case .folder: FolderRemoteStore(root: folderURL ?? URL(fileURLWithPath: "/nonexistent-safevault-folder"))
        case .dropbox: DropboxRemoteStore(auth: dropbox)
        case .googleDrive: GoogleDriveRemoteStore(auth: google)
        }
    }

    func scheduleSync(delay: Duration = .seconds(2)) {
        guard syncLinked, !syncPaused, phase == .unlocked, !demoMode else { return }
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
        if syncPaused { syncPaused = false; return }
        guard let session, syncLinked, !syncPaused, !demoMode, syncStatus != .syncing else { return }
        syncStatus = .syncing
        let engine = self.engine ?? SyncEngine(session: session, remote: makeRemote())
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
        } catch RemoteError.quotaExceeded {
            syncStatus = .quotaExceeded
        } catch RemoteError.unauthorized {
            syncStatus = .failed("\(provider.title) needs you to sign in again.")
        } catch VaultError.differentVault {
            syncStatus = .failed("\(provider.title) already holds a different vault. In Settings, choose \"Use the vault from the cloud\" to bring it here, or \"Replace cloud copy with this vault\" to overwrite it.")
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
    }

    var syncDescription: String {
        if syncLinked && syncPaused { return "Sync paused" }
        switch syncStatus {
        case .notConfigured: return "\(provider.title) not connected"
        case .idle: return "Synced with \(provider.title)"
        case .syncing: return "Syncing with \(provider.title)…"
        case .offline: return "Offline · will sync later"
        case .quotaExceeded: return "\(provider.title) is full"
        case .failed: return "Sync problem"
        }
    }

    /// Chooses which cloud keeps the encrypted copy. Everything is uploaded again to the new one; whatever is
    /// already there is merged by the usual conflict rules, so nothing is lost and nothing is duplicated.
    func selectProvider(_ new: CloudProvider) {
        guard new != provider else { return }
        provider = new
        engine = nil
        pollTask?.cancel()
        syncTask?.cancel()
        syncStatus = syncLinked ? .idle : .notConfigured
        lastSync = nil
        if let s = session {
            Task {
                try? await s.resetSyncState()
                if syncLinked { startPolling(); scheduleSync(delay: .milliseconds(200)) }
            }
        } else if storage.hasVault {
            defaults.set(true, forKey: "syncResetPending")  // applied the next time the vault is unlocked
        }
    }

    func connectCloud(authenticate: @escaping (URL, String) async throws -> URL) async {
        switch provider {
        case .folder: break  // chosen with the folder picker, see linkFolder
        case .dropbox: await connectDropbox(authenticate: authenticate)
        case .googleDrive: await connectGoogle(authenticate: authenticate)
        }
    }

    private func isCancelledLogin(_ error: Error) -> Bool {
        (error as NSError).code == 1 && (error as NSError).domain == "com.apple.AuthenticationServices.WebAuthenticationSession"
    }

    private func finishConnecting() {
        syncStatus = .idle
        if phase == .unlocked {
            startPolling()
            scheduleSync(delay: .milliseconds(200))
        }
    }

    private func connectDropbox(authenticate: @escaping (URL, String) async throws -> URL) async {
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
            dropboxEmail = await dropbox.accountEmail()
            finishConnecting()
        } catch {
            if isCancelledLogin(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    private func connectGoogle(authenticate: @escaping (URL, String) async throws -> URL) async {
        guard googleConfigured else {
            errorMessage = "Paste your Google client ID in the \"One-time Google Drive setup\" box first, then press Connect Google Drive again."
            return
        }
        busy = true
        defer { busy = false }
        let (verifier, challenge) = DropboxAuth.makePKCE()
        guard let url = await google.authorizeURL(challenge: challenge) else { return }
        do {
            let callback = try await authenticate(url, await google.callbackScheme)
            guard let code = GoogleAuth.code(fromCallback: callback) else { throw RemoteError.unauthorized }
            try await google.exchange(code: code, verifier: verifier)
            googleLinked = true
            finishConnecting()
        } catch {
            if isCancelledLogin(error) { return }
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
        if provider == .dropbox { engine = nil; syncStatus = .notConfigured }
        return true
    }

    /// Same for the Google OAuth client ID (an "iOS" type client, public, no secret).
    @discardableResult
    func saveGoogleClientID(_ raw: String) -> Bool {
        guard let id = GoogleAuth.normalizedClientID(raw) else {
            errorMessage = "That does not look like a Google client ID. It looks like 123456789-abc123.apps.googleusercontent.com."
            return false
        }
        defaults.set(id, forKey: "googleClientID")
        googleClientID = id
        google = GoogleAuth(clientID: id, store: secrets)
        googleLinked = false
        if provider == .googleDrive { engine = nil; syncStatus = .notConfigured }
        return true
    }

    // MARK: Folder (iCloud Drive)

    #if os(macOS)
    private static let bookmarkCreate: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolve: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreate: URL.BookmarkCreationOptions = []
    private static let bookmarkResolve: URL.BookmarkResolutionOptions = []
    #endif

    /// Uses the folder you picked as the shared place for the encrypted files. The permission to use it is kept
    /// (as a bookmark) so it still works after a restart.
    func linkFolder(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let probe = url.appendingPathComponent(".safevault-probe-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            let bookmark = try url.bookmarkData(options: Self.bookmarkCreate, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: "syncFolderBookmark")
            stopFolderAccess()
            folderURL = url
            folderAccess = scoped
            folderLinked = true
            folderName = url.lastPathComponent
            provider = .folder
            engine = nil
            finishConnecting()
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = "SafeVault cannot save files in that folder. Pick another one, for example a new folder inside iCloud Drive. (\(error.localizedDescription))"
        }
    }

    private func restoreFolder() {
        guard let data = defaults.data(forKey: "syncFolderBookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.bookmarkResolve, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        folderAccess = url.startAccessingSecurityScopedResource()
        folderURL = url
        folderLinked = true
        folderName = url.lastPathComponent
        if stale, let fresh = try? url.bookmarkData(options: Self.bookmarkCreate, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: "syncFolderBookmark")
        }
    }

    private func stopFolderAccess() {
        if folderAccess { folderURL?.stopAccessingSecurityScopedResource() }
        folderAccess = false
        folderURL = nil
    }

    /// Forgets the saved Dropbox app key / Google client ID (and the login made with it), so another one can be entered.
    func forgetAppKey() async {
        switch provider {
        case .dropbox:
            await dropbox.unlink()
            defaults.removeObject(forKey: "dropboxAppKey")
            dropboxAppKey = ""
            dropbox = DropboxAuth(appKey: "", store: secrets)
            dropboxLinked = false
            dropboxEmail = nil
        case .googleDrive:
            await google.unlink()
            defaults.removeObject(forKey: "googleClientID")
            googleClientID = ""
            google = GoogleAuth(clientID: "", store: secrets)
            googleLinked = false
        case .folder:
            return
        }
        syncStatus = .notConfigured
        engine = nil
        pollTask?.cancel()
    }

    /// Wipes SafeVault's files from the cloud and uploads this vault in their place. For when the cloud holds an old
    /// vault whose password is lost. Only SafeVault's own files (vault.db, header.json, <uuid>.vitem) are touched.
    func replaceCloudCopy() async {
        guard syncLinked, let session else { return }
        busy = true
        defer { busy = false }
        do {
            let remote = makeRemote()
            for file in try await remote.listFiles() where file.name == VaultFile.name || file.name == VaultStorage.headerName || VaultStorage.itemID(fromName: file.name) != nil {
                try await remote.deleteFile(file.name)
            }
            engine = nil
            try await session.resetSyncState()
            syncStatus = .idle
            await syncNow()
            showToast("Cloud copy replaced")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Replaces the vault on this device with the one stored in the cloud (for example the one made on the phone).
    /// The cloud vault is checked first, so nothing is erased unless there is something to take its place.
    func useCloudVault() async {
        guard syncLinked else { return }
        busy = true
        defer { busy = false }
        do {
            let remote = makeRemote()
            let names = Set(try await remote.listFiles().map(\.name))
            let header: Data
            if names.contains(VaultFile.name) {
                header = try VaultFile.headerData(from: try await remote.download(VaultFile.name).data)
            } else if names.contains(VaultStorage.headerName) {
                header = try await remote.download(VaultStorage.headerName).data
            } else {
                errorMessage = "There is no SafeVault vault in this \(provider.title) yet, so there is nothing to bring here."
                return
            }
            // Something is there: now it is safe to replace the vault on this device.
            disableBiometrics()
            lock()
            try? storage.destroy()
            for key in ["lastMasterUnlock", "syncResetPending"] { defaults.removeObject(forKey: key) }
            items = []
            engine = nil
            try storage.installDownloadedHeader(header)
            syncStatus = .idle
            phase = .locked
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectCloud() async {
        switch provider {
        case .dropbox:
            await dropbox.unlink()
            dropboxLinked = false
            dropboxEmail = nil
        case .googleDrive:
            await google.unlink()
            googleLinked = false
        case .folder:
            stopFolderAccess()
            defaults.removeObject(forKey: "syncFolderBookmark")
            folderLinked = false
            folderName = nil
        }
        syncStatus = .notConfigured
        engine = nil
        pollTask?.cancel()
    }

    /// For a new device: fetches the vault header from the chosen cloud so the master password can unlock it.
    func fetchVaultFromCloud() async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let remote = makeRemote()
            let names = Set(try await remote.listFiles().map(\.name))
            guard names.contains(VaultFile.name) || names.contains(VaultStorage.headerName) else {
                errorMessage = "There is no SafeVault in this \(provider.title) account yet. Create the vault on your other device first, or create a new one here."
                return false
            }
            if names.contains(VaultFile.name) {
                let file = try await remote.download(VaultFile.name).data
                try storage.installDownloadedHeader(try VaultFile.headerData(from: file))
            } else {  // a vault left by an older version, in one file per item
                try storage.installDownloadedHeader(try await remote.download(VaultStorage.headerName).data)
            }
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
            Task { _ = await fetchMissingIcons() }
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
