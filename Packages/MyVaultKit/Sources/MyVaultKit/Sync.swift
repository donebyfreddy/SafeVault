import Foundation

public struct RemoteFile: Equatable, Sendable {
    public var name: String
    public var rev: String

    public init(name: String, rev: String) {
        self.name = name
        self.rev = rev
    }
}

public enum RemoteError: Error, Equatable, LocalizedError {
    /// The file changed (or already exists) since the revision we know about.
    case conflict
    case notFound
    case unauthorized
    case offline
    case rateLimited(retryAfter: Int)
    /// The cloud account has no space left (or is over its quota), so nothing new can be saved there.
    case quotaExceeded
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .conflict: "The file changed in the cloud while syncing."
        case .notFound: "File not found in the cloud."
        case .unauthorized: "You need to sign in to the cloud again."
        case .offline: "No connection to the cloud."
        case .rateLimited(let s): "The cloud asked to wait \(s) seconds."
        case .quotaExceeded: "Your cloud storage is full. SafeVault keeps working on this device; free some space to sync again."
        case .server(let m): m
        }
    }
}

/// The transport behind sync. Dropbox is one implementation; tests use an in-memory one.
public protocol RemoteStore: Sendable {
    func listFiles() async throws -> [RemoteFile]
    func download(_ name: String) async throws -> (data: Data, rev: String)
    /// With `expectedRev == nil` the file must not exist yet. Otherwise its revision must match.
    /// Both cases throw `RemoteError.conflict` when that is not true.
    func upload(_ name: String, data: Data, expectedRev: String?) async throws -> String
    /// Copies the cloud made when two devices wrote the same file at once. Most clouds never do.
    func conflictCopies() async throws -> [ConflictCopy]
    /// Called once a copy has been merged, so it is not processed again.
    func resolveConflictCopy(_ fileName: String) async throws
    /// Removes a file. Used to clear out the old one-file-per-item layout; a store may ignore it.
    func deleteFile(_ name: String) async throws
}

public extension RemoteStore {
    func conflictCopies() async throws -> [ConflictCopy] { [] }
    func resolveConflictCopy(_ fileName: String) async throws {}
    func deleteFile(_ name: String) async throws {}
}

public struct SyncReport: Equatable, Sendable {
    public var pulled = 0
    public var pushed = 0
    public var conflicts = 0
    public var failed: [String] = []
    public init() {}
}

/// Two-way sync through ONE file, `vault.db`.
///
/// Each sync: if the cloud file changed (or we have changes), download it, merge it item by item with the rule
/// "the most recent edit wins and the other version is kept in that item's history", and upload the result if it
/// differs. A file that cannot be read is never overwritten.
public actor SyncEngine {
    private let session: VaultSession
    private let remote: RemoteStore

    private static let legacyHeader = VaultStorage.headerName

    public init(session: VaultSession, remote: RemoteStore) {
        self.session = session
        self.remote = remote
    }

    public func sync(now: Date = Date()) async throws -> SyncReport {
        var report = SyncReport()
        let name = VaultFile.name
        var files = Dictionary(uniqueKeysWithValues: try await remote.listFiles().map { ($0.name, $0.rev) })

        // Copies the cloud made for simultaneous writes of vault.db (iCloud calls them "vault 2.db").
        for copy in try await remote.conflictCopies() where copy.baseName == name {
            do {
                let outcome = try await session.mergeSyncFile(copy.data)
                report.conflicts += max(1, outcome.conflicts)
                try await remote.resolveConflictCopy(copy.fileName)
            } catch let error as RemoteError where Self.isFatal(error) {
                throw error
            } catch {
                report.failed.append(copy.fileName)
            }
        }

        var legacy = [String]()
        for attempt in 0..<4 {
            let rev = files[name]
            let state = await session.currentState()
            let localChanges = !state.records.isEmpty || state.headerDirty

            // Nothing changed on either side: nothing to do, and nothing to download.
            if let rev, rev == state.remoteRev, !localChanges { break }

            var toUpload = 0
            if let rev {
                let (data, newRev) = try await remote.download(name)
                let outcome = try await session.mergeSyncFile(data)
                report.pulled += outcome.pulled
                report.conflicts += outcome.conflicts
                toUpload = outcome.toUpload
                if !outcome.needsUpload {
                    try await session.updateState { $0.remoteRev = newRev; $0.records = [:]; $0.headerDirty = false }
                    break
                }
            } else {
                // No vault.db yet. If an older version of the app left one file per item, bring those in first.
                if files[Self.legacyHeader] != nil { legacy = try await absorbLegacy(files: files, report: &report) }
                toUpload = await session.allRawItems().count + 1
            }

            let bytes = try await session.exportSyncFile()
            do {
                let newRev = try await remote.upload(name, data: bytes, expectedRev: rev)
                try await session.updateState { $0.remoteRev = newRev; $0.records = [:]; $0.headerDirty = false }
                report.pushed = toUpload
                break
            } catch RemoteError.conflict {
                // Someone wrote in between: look again, merge with what is there now, and retry.
                files = Dictionary(uniqueKeysWithValues: try await remote.listFiles().map { ($0.name, $0.rev) })
            } catch RemoteError.notFound {
                files[name] = nil
            }
            if attempt == 3 { throw RemoteError.conflict }
        }

        if !legacy.isEmpty { await removeLegacy(legacy) }
        try await session.updateState { $0.lastSync = now }
        return report
    }

    private static func isFatal(_ error: RemoteError) -> Bool {
        error == .offline || error == .unauthorized || error == .quotaExceeded
    }

    // MARK: Old layout (header.json + one .vitem per item)

    private func absorbLegacy(files: [String: String], report: inout SyncReport) async throws -> [String] {
        var names = [String]()
        let headerData = try await remote.download(Self.legacyHeader).data
        _ = try await session.adoptRemoteHeader(headerData)  // also refuses a different vault
        names.append(Self.legacyHeader)
        for (file, _) in files {
            guard let id = VaultStorage.itemID(fromName: file) else { continue }
            do {
                let blob = try await remote.download(file).data
                try await session.absorbCopy(try await session.decryptRemote(blob, id: id))
                names.append(file)
                report.pulled += 1
            } catch let error as RemoteError where Self.isFatal(error) {
                throw error
            } catch {
                report.failed.append(file)  // left in place, never deleted
            }
        }
        return names
    }

    /// Deletes the old files, but only once vault.db is confirmed to hold everything.
    private func removeLegacy(_ names: [String]) async {
        guard report(names), let check = try? await remote.download(VaultFile.name),
              await session.syncFileHoldsEverything(check.data) else { return }
        for name in names { try? await remote.deleteFile(name) }
    }

    private func report(_ names: [String]) -> Bool { !names.isEmpty }

    // MARK: Merge

    /// Same data, ignoring bookkeeping (history, last use, edit time).
    static func sameContent(_ a: VaultItem, _ b: VaultItem) -> Bool {
        var x = a, y = b
        x.history = []; y.history = []
        x.lastUsedAt = nil; y.lastUsedAt = nil
        x.icon = nil; y.icon = nil
        x.iconCustom = nil; y.iconCustom = nil
        x.iconCheckedAt = nil; y.iconCheckedAt = nil
        x.modifiedAt = y.modifiedAt
        return x.canonicalBytes == y.canonicalBytes
    }

    /// Two copies with the same data: keep the latest use and the union of the histories, so both devices
    /// end up with an identical item.
    static func mergeSameContent(_ a: VaultItem, _ b: VaultItem) -> VaultItem {
        var m = a.modifiedAt >= b.modifiedAt ? a : b
        m.lastUsedAt = [a.lastUsedAt, b.lastUsedAt].compactMap { $0 }.max()
        m.history = VaultItem.mergedHistory(a.history, b.history)
        applyBestIcon(&m, a, b)
        return m
    }

    /// Both devices must pick the same icon: one you chose beats a downloaded one; otherwise the bigger file wins.
    static func applyBestIcon(_ m: inout VaultItem, _ a: VaultItem, _ b: VaultItem) {
        func rank(_ x: VaultItem) -> (Int, Int) { (x.iconCustom == true ? 1 : 0, x.icon?.count ?? 0) }
        var winner = rank(a) != rank(b) ? (rank(a) > rank(b) ? a : b) : a
        if rank(a) == rank(b), let da = a.icon, let db = b.icon, da != db { winner = da.lexicographicallyPrecedes(db) ? b : a }
        m.icon = winner.icon
        m.iconCustom = winner.iconCustom
        m.iconCheckedAt = [a.iconCheckedAt, b.iconCheckedAt].compactMap { $0 }.max()
    }

    /// The most recent edit wins; the other version is kept in the winner's history.
    static func merge(local: VaultItem, remote: VaultItem) -> (winner: VaultItem, localWon: Bool) {
        if remote.modifiedAt > local.modifiedAt {
            var w = remote
            if !local.deleted { w.appendHistory(local.snapshot(reason: "Replaced by a newer edit from another device", at: local.modifiedAt)) }
            w.history = VaultItem.mergedHistory(w.history, local.history)
            w.lastUsedAt = [local.lastUsedAt, remote.lastUsedAt].compactMap { $0 }.max()
            applyBestIcon(&w, local, remote)
            return (w, false)
        }
        var w = local
        if !remote.deleted { w.appendHistory(remote.snapshot(reason: "Replaced by a newer edit on this device", at: remote.modifiedAt)) }
        w.history = VaultItem.mergedHistory(w.history, remote.history)
        w.lastUsedAt = [local.lastUsedAt, remote.lastUsedAt].compactMap { $0 }.max()
        applyBestIcon(&w, local, remote)
        return (w, true)
    }
}

/// Reference implementation of `RemoteStore`, also used for tests and demos.
public actor InMemoryRemote: RemoteStore {
    private var files: [String: (data: Data, rev: Int)] = [:]
    private var counter = 0
    public var offline = false
    public private(set) var uploadCount = 0

    public init() {}

    public func setOffline(_ value: Bool) { offline = value }

    public func listFiles() async throws -> [RemoteFile] {
        if offline { throw RemoteError.offline }
        return files.map { RemoteFile(name: $0.key, rev: String($0.value.rev)) }
    }

    public func download(_ name: String) async throws -> (data: Data, rev: String) {
        if offline { throw RemoteError.offline }
        guard let f = files[name] else { throw RemoteError.notFound }
        return (f.data, String(f.rev))
    }

    public func upload(_ name: String, data: Data, expectedRev: String?) async throws -> String {
        if offline { throw RemoteError.offline }
        if let expectedRev {
            guard let f = files[name] else { throw RemoteError.notFound }
            guard String(f.rev) == expectedRev else { throw RemoteError.conflict }
        } else if files[name] != nil {
            throw RemoteError.conflict
        }
        counter += 1
        uploadCount += 1
        files[name] = (data, counter)
        return String(counter)
    }

    /// Test helper: overwrite a file as another client would.
    public func forceWrite(_ name: String, data: Data) {
        counter += 1
        files[name] = (data, counter)
    }

    public func removeFile(_ name: String) { files[name] = nil }

    public func deleteFile(_ name: String) async throws {
        if offline { throw RemoteError.offline }
        files[name] = nil
    }
}
