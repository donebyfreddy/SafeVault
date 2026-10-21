import CryptoKit
import Foundation

/// An unlocked vault. Holds the vault key and the decrypted items in memory only.
public actor VaultSession {
    public let storage: VaultStorage
    private var vaultKey: SymmetricKey?
    private var header: VaultHeader
    private var items: [UUID: VaultItem] = [:]
    private var state: SyncState
    /// Records that could not be decrypted (damaged or tampered). They are left on disk untouched.
    public private(set) var unreadableItems: [UUID] = []

    /// `requireReadable`: fail if records exist but none can be decrypted, which means the key is wrong.
    private init(storage: VaultStorage, header: VaultHeader, key: SymmetricKey, requireReadable: Bool = false) throws {
        let loaded = try Self.decryptAll(storage: storage, key: key)
        if requireReadable, loaded.total > 0, loaded.items.isEmpty { throw VaultError.corrupted }
        self.storage = storage
        self.header = header
        self.vaultKey = key
        self.state = storage.loadState()
        self.items = loaded.items
        self.unreadableItems = loaded.bad
    }

    // MARK: Opening

    public static func create(
        password: String, storage: VaultStorage, iterations: Int = VaultCrypto.defaultIterations
    ) throws -> VaultSession {
        guard !storage.hasVault else { throw VaultError.alreadyExists }
        let (header, key) = try VaultCrypto.makeHeader(password: password, iterations: iterations)
        try storage.saveHeader(header)
        var fresh = SyncState()
        fresh.headerDirty = true
        try storage.saveState(fresh)
        return try VaultSession(storage: storage, header: header, key: key)
    }

    public static func open(password: String, storage: VaultStorage) throws -> VaultSession {
        guard let header = try storage.loadHeader() else { throw VaultError.notFound }
        let key = try VaultCrypto.unlock(password: password, header: header)
        return try VaultSession(storage: storage, header: header, key: key)
    }

    /// Used by biometric unlock, which restores the vault key from the Keychain.
    public static func open(vaultKeyData: Data, storage: VaultStorage) throws -> VaultSession {
        guard let header = try storage.loadHeader() else { throw VaultError.notFound }
        guard vaultKeyData.count == 32 else { throw VaultError.corrupted }
        return try VaultSession(storage: storage, header: header, key: SymmetricKey(data: vaultKeyData), requireReadable: true)
    }

    private static func decryptAll(storage: VaultStorage, key: SymmetricKey) throws -> (items: [UUID: VaultItem], bad: [UUID], total: Int) {
        var items = [UUID: VaultItem]()
        var bad = [UUID]()
        let blobs = try storage.listItemBlobs()
        for (id, blob) in blobs {
            do {
                let plain = try VaultCrypto.open(blob, key: key, context: VaultCrypto.itemContext(id))
                let item = try VaultStorage.decoder.decode(VaultItem.self, from: plain)
                guard item.id == id else { bad.append(id); continue }
                items[id] = item
            } catch {
                bad.append(id)
            }
        }
        return (items, bad, blobs.count)
    }

    // MARK: State

    public var isUnlocked: Bool { vaultKey != nil }
    public var vaultID: UUID { header.vaultID }

    /// The raw vault key, for storing behind biometrics. Handle with care.
    public func vaultKeyData() throws -> Data {
        guard let key = vaultKey else { throw VaultError.corrupted }
        return key.withUnsafeBytes { Data($0) }
    }

    /// Drops the key and the decrypted items from memory.
    public func lock() {
        vaultKey = nil
        items.removeAll()
    }

    public func allItems(includeArchived: Bool = true) -> [VaultItem] {
        items.values.filter { !$0.deleted && (includeArchived || !$0.archived) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func item(_ id: UUID) -> VaultItem? {
        items[id].flatMap { $0.deleted ? nil : $0 }
    }

    public var lastSync: Date? { state.lastSync }

    // MARK: Editing

    public func upsert(_ item: VaultItem, touch: Bool = true) throws {
        var item = item
        if touch { item.touch() }
        try persist(item, markDirty: true)
    }

    /// Records that an item was used (copied, opened). Does not count as an edit.
    public func markUsed(_ id: UUID, at date: Date = Date()) throws {
        guard var item = items[id], !item.deleted else { return }
        item.lastUsedAt = date
        try persist(item, markDirty: true)
    }

    /// Deletes an item. A scrubbed tombstone stays behind so the deletion reaches other devices.
    public func delete(_ id: UUID) throws {
        guard var item = items[id] else { throw VaultError.notFound }
        item.deleted = true
        item.fields = []
        item.notes = ""
        item.tags = []
        item.totpSecret = nil
        item.backupCodes = []
        item.passwordHistory = []
        item.history = []
        item.touch()
        try persist(item, markDirty: true)
    }

    /// Adds many items at once (importing). Returns how many were stored.
    @discardableResult
    public func importItems(_ new: [VaultItem]) throws -> Int {
        // One bookkeeping write for the whole batch instead of one per item.
        for item in new { try persist(item, markDirty: false) }
        for item in new { state.records[item.id.uuidString.lowercased()] = RecordState(rev: nil, dirty: true) }
        try storage.saveState(state)
        return new.count
    }

    public func changePassword(old: String, new: String, iterations: Int = VaultCrypto.defaultIterations) throws {
        header = try VaultCrypto.changePassword(header: header, oldPassword: old, newPassword: new, iterations: iterations)
        try storage.saveHeader(header)
        state.headerDirty = true
        try storage.saveState(state)
    }

    private func persist(_ item: VaultItem, markDirty: Bool) throws {
        guard let key = vaultKey else { throw VaultError.corrupted }
        let plain = try VaultStorage.encoder.encode(item)
        let blob = try VaultCrypto.seal(plain, key: key, context: VaultCrypto.itemContext(item.id))
        try storage.writeBlob(blob, id: item.id)
        items[item.id] = item
        if markDirty {
            var rec = state.records[item.id.uuidString.lowercased()] ?? RecordState()
            rec.dirty = true
            state.records[item.id.uuidString.lowercased()] = rec
            try storage.saveState(state)
        }
    }

    // MARK: Backup

    private struct Backup: Codable {
        var format: String
        var version: Int
        var header: VaultHeader
        var items: [String: Data]
    }

    /// An encrypted copy of the whole vault in one file. Still needs the master password.
    public func exportBackup() throws -> Data {
        var blobs = [String: Data]()
        for (id, blob) in try storage.listItemBlobs() { blobs[id.uuidString.lowercased()] = blob }
        let backup = Backup(format: "myvault-backup", version: 1, header: header, items: blobs)
        return try VaultStorage.encoder.encode(backup)
    }

    /// Restores a backup into an empty storage. Unlock afterwards with the backup's master password.
    public static func restoreBackup(_ data: Data, into storage: VaultStorage) throws {
        guard !storage.hasVault else { throw VaultError.alreadyExists }
        let backup: Backup
        do { backup = try VaultStorage.decoder.decode(Backup.self, from: data) } catch { throw VaultError.corrupted }
        guard backup.format == "myvault-backup" else { throw VaultError.corrupted }
        guard backup.version <= 1 else { throw VaultError.unsupportedVersion(backup.version) }
        for (key, blob) in backup.items {
            guard let id = UUID(uuidString: key) else { continue }
            try storage.writeBlob(blob, id: id)
        }
        try storage.saveHeader(backup.header)
        var fresh = SyncState()
        fresh.headerDirty = true
        for key in backup.items.keys { fresh.records[key] = RecordState(rev: nil, dirty: true) }
        try storage.saveState(fresh)
    }

    // MARK: vault.db

    public struct MergeOutcome: Sendable, Equatable {
        /// Items that came from the cloud and changed what we have.
        public var pulled = 0
        /// Items whose two versions differed and were merged.
        public var conflicts = 0
        /// Items (or the header) that the cloud copy does not have yet.
        public var toUpload = 0
        public var needsUpload: Bool { toUpload > 0 }
    }

    /// Everything, sealed in one blob, ready to be uploaded as `vault.db`.
    public func exportSyncFile() throws -> Data {
        guard let key = vaultKey else { throw VaultError.corrupted }
        let list = items.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let sealed = try VaultCrypto.seal(try VaultStorage.encoder.encode(VaultFile.Payload(items: list)), key: key, context: VaultFile.context)
        let container = VaultFile.Container(format: VaultFile.formatName, version: VaultFile.currentVersion, header: header, payload: sealed)
        return try VaultStorage.encoder.encode(container)
    }

    /// Merges a downloaded `vault.db` into what we have. Throws, changing nothing, if the file cannot be read
    /// with our key or belongs to another vault: the caller must then NOT upload over it.
    public func mergeSyncFile(_ data: Data) throws -> MergeOutcome {
        guard let key = vaultKey else { throw VaultError.corrupted }
        let container = try VaultFile.decode(data)
        guard container.header.vaultID == header.vaultID else { throw VaultError.differentVault }
        let plain = try VaultCrypto.open(container.payload, key: key, context: VaultFile.context)
        let remoteItems: [VaultItem]
        do { remoteItems = try VaultStorage.decoder.decode(VaultFile.Payload.self, from: plain).items } catch { throw VaultError.corrupted }

        var outcome = MergeOutcome()
        let remote = container.header
        // Dates that went through a file can differ in the last bit, so "newer" means newer by over a millisecond.
        let dt = remote.updatedAt.timeIntervalSince(header.updatedAt)
        if remote.revision > header.revision || (remote.revision == header.revision && dt > 0.001) {
            header = remote  // a newer master password from another device
            try storage.saveHeader(header)
        } else if remote.revision < header.revision || (remote.revision == header.revision && dt < -0.001) {
            outcome.toUpload += 1
        }

        var remoteByID = [UUID: VaultItem]()
        for r in remoteItems { remoteByID[r.id] = r }
        for r in remoteItems {
            guard let local = items[r.id] else {
                try persist(r, markDirty: false)
                outcome.pulled += 1
                continue
            }
            if local.canonicalBytes == r.canonicalBytes { continue }
            let merged: VaultItem
            if SyncEngine.sameContent(local, r) {
                merged = SyncEngine.mergeSameContent(local, r)
            } else {
                merged = SyncEngine.merge(local: local, remote: r).winner
                outcome.conflicts += 1
            }
            if merged.canonicalBytes != local.canonicalBytes {
                try persist(merged, markDirty: false)
                if merged.modifiedAt >= local.modifiedAt, merged.fields != local.fields || merged.name != local.name { outcome.pulled += 1 }
            }
        }
        for (id, local) in items where remoteByID[id]?.canonicalBytes != local.canonicalBytes { outcome.toUpload += 1 }
        return outcome
    }

    /// Whether a downloaded vault.db can be read and holds every item we have. Used before deleting old files.
    public func syncFileHoldsEverything(_ data: Data) -> Bool {
        guard let key = vaultKey, let container = try? VaultFile.decode(data),
              let plain = try? VaultCrypto.open(container.payload, key: key, context: VaultFile.context),
              let payload = try? VaultStorage.decoder.decode(VaultFile.Payload.self, from: plain) else { return false }
        let ids = Set(payload.items.map(\.id))
        return items.keys.allSatisfy { ids.contains($0) }
    }

    // MARK: Sync hooks (used by SyncEngine)

    func currentState() -> SyncState { state }

    /// Merges a version found in a conflict copy into the item we have. The result is marked to upload.
    func absorbCopy(_ remote: VaultItem) throws {
        guard let local = items[remote.id] else { try persist(remote, markDirty: true); return }
        if SyncEngine.sameContent(local, remote) { return }
        try persist(SyncEngine.merge(local: local, remote: remote).winner, markDirty: true)
    }

    /// Forget what is known about the cloud copy: every item and the header are uploaded again, and anything
    /// already there is merged by the normal conflict rules. Used when switching to another cloud.
    public func resetSyncState() throws {
        var fresh = SyncState()
        fresh.headerDirty = true
        fresh.lastSync = nil
        for id in items.keys { fresh.records[id.uuidString.lowercased()] = RecordState(rev: nil, dirty: true) }
        state = fresh
        try storage.saveState(fresh)
    }

    func updateState(_ change: (inout SyncState) -> Void) throws {
        change(&state)
        try storage.saveState(state)
    }

    func rawItem(_ id: UUID) -> VaultItem? { items[id] }

    func allRawItems() -> [VaultItem] { Array(items.values) }

    func encryptedBlob(for id: UUID) throws -> Data { try storage.readBlob(id: id) }

    func decryptRemote(_ blob: Data, id: UUID) throws -> VaultItem {
        guard let key = vaultKey else { throw VaultError.corrupted }
        let plain = try VaultCrypto.open(blob, key: key, context: VaultCrypto.itemContext(id))
        let item = try VaultStorage.decoder.decode(VaultItem.self, from: plain)
        guard item.id == id else { throw VaultError.corrupted }
        return item
    }

    /// Stores an item that came from (or was merged with) the remote copy.
    func storeSynced(_ item: VaultItem, rev: String, dirty: Bool) throws {
        try persist(item, markDirty: false)
        state.records[item.id.uuidString.lowercased()] = RecordState(rev: rev, dirty: dirty)
        try storage.saveState(state)
    }

    func currentHeader() -> VaultHeader { header }

    func headerData() throws -> Data { try storage.headerData() }

    /// Adopts a header from the remote when it is newer. The vault key stays the same.
    func adoptRemoteHeader(_ data: Data) throws -> Bool {
        let remote = try VaultStorage.decoder.decode(VaultHeader.self, from: data)
        guard remote.vaultID == header.vaultID else { throw VaultError.differentVault }
        guard remote.revision > header.revision || (remote.revision == header.revision && remote.updatedAt > header.updatedAt) else { return false }
        try storage.writeHeaderData(data)
        header = remote
        return true
    }
}
