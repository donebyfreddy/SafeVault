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
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .conflict: "The file changed on Dropbox while syncing."
        case .notFound: "File not found on Dropbox."
        case .unauthorized: "Dropbox needs you to sign in again."
        case .offline: "No connection to Dropbox."
        case .rateLimited(let s): "Dropbox asked to wait \(s) seconds."
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
}

public struct SyncReport: Equatable, Sendable {
    public var pulled = 0
    public var pushed = 0
    public var conflicts = 0
    public var failed: [String] = []
    public init() {}
}

public actor SyncEngine {
    private let session: VaultSession
    private let remote: RemoteStore

    public init(session: VaultSession, remote: RemoteStore) {
        self.session = session
        self.remote = remote
    }

    /// Two-way sync. Never deletes a remote file and never discards an edit without keeping a copy in the item's history.
    public func sync(now: Date = Date()) async throws -> SyncReport {
        var report = SyncReport()
        var files = Dictionary(uniqueKeysWithValues: try await remote.listFiles().map { ($0.name, $0.rev) })

        try await syncHeader(&files)

        // Pull
        for (name, rev) in files {
            guard let id = VaultStorage.itemID(fromName: name) else { continue }
            let key = id.uuidString.lowercased()
            let known = await session.currentState().records[key]
            if known?.rev == rev { continue }
            do {
                try await pull(id: id, name: name, report: &report)
            } catch let error as RemoteError where error == .offline || error == .unauthorized {
                throw error
            } catch {
                report.failed.append(name)
            }
        }

        // Anything we think is on the remote but is gone: upload it again rather than lose it.
        let state = await session.currentState()
        for (key, rec) in state.records where rec.rev != nil && !rec.dirty {
            guard let id = UUID(uuidString: key), files[VaultStorage.itemName(id)] == nil else { continue }
            try await session.updateState { $0.records[key] = RecordState(rev: nil, dirty: true) }
        }

        // Push
        let dirty = await session.currentState().records.filter { $0.value.dirty }
        for (key, rec) in dirty {
            guard let id = UUID(uuidString: key) else { continue }
            do {
                try await push(id: id, expectedRev: rec.rev, report: &report)
            } catch let error as RemoteError where error == .offline || error == .unauthorized {
                throw error
            } catch {
                report.failed.append(VaultStorage.itemName(id))
            }
        }

        try await session.updateState { $0.lastSync = now }
        return report
    }

    // MARK: Header

    private func syncHeader(_ files: inout [String: String]) async throws {
        let name = VaultStorage.headerName
        let state = await session.currentState()
        if let rev = files[name] {
            if rev != state.headerRev {
                let (data, newRev) = try await remote.download(name)
                _ = try await session.adoptRemoteHeader(data)
                try await session.updateState { $0.headerRev = newRev }
                files[name] = newRev
            }
            if await session.currentState().headerDirty {
                let data = try await session.headerData()
                let newRev = try await remote.upload(name, data: data, expectedRev: files[name])
                try await session.updateState { $0.headerRev = newRev; $0.headerDirty = false }
                files[name] = newRev
            }
        } else {
            let data = try await session.headerData()
            let newRev = try await remote.upload(name, data: data, expectedRev: nil)
            try await session.updateState { $0.headerRev = newRev; $0.headerDirty = false }
            files[name] = newRev
        }
    }

    // MARK: Items

    private func pull(id: UUID, name: String, report: inout SyncReport) async throws {
        let (blob, rev) = try await remote.download(name)
        let remoteItem = try await session.decryptRemote(blob, id: id)
        let key = id.uuidString.lowercased()
        let record = await session.currentState().records[key]
        let local = await session.rawItem(id)

        guard let local, record?.dirty == true else {
            // Nothing local to protect: take the remote copy.
            try await session.storeSynced(remoteItem, rev: rev, dirty: false)
            report.pulled += 1
            return
        }

        if Self.sameContent(local, remoteItem) {
            try await session.storeSynced(local, rev: rev, dirty: local != remoteItem)
            return
        }
        let (winner, localWon) = Self.merge(local: local, remote: remoteItem)
        try await session.storeSynced(winner, rev: rev, dirty: localWon || winner != remoteItem)
        report.conflicts += 1
        report.pulled += localWon ? 0 : 1
    }

    private func push(id: UUID, expectedRev: String?, report: inout SyncReport) async throws {
        let key = id.uuidString.lowercased()
        let name = VaultStorage.itemName(id)
        var rev = expectedRev
        for attempt in 0..<3 {
            let blob = try await session.encryptedBlob(for: id)
            do {
                let newRev = try await remote.upload(name, data: blob, expectedRev: rev)
                try await session.updateState { $0.records[key] = RecordState(rev: newRev, dirty: false) }
                report.pushed += 1
                return
            } catch RemoteError.conflict {
                // Someone else wrote in between: merge with what is there now and try again.
                let files = try await remote.listFiles()
                if let current = files.first(where: { $0.name == name }) {
                    try await pull(id: id, name: name, report: &report)
                    rev = await session.currentState().records[key]?.rev ?? current.rev
                } else {
                    rev = nil
                }
            } catch RemoteError.notFound {
                rev = nil
            }
            if attempt == 2 { throw RemoteError.conflict }
        }
    }

    // MARK: Merge

    static func sameContent(_ a: VaultItem, _ b: VaultItem) -> Bool {
        var x = a, y = b
        x.history = []; y.history = []
        x.lastUsedAt = nil; y.lastUsedAt = nil
        x.modifiedAt = y.modifiedAt
        return x == y
    }

    /// The most recent edit wins; the other version is kept in the winner's history.
    static func merge(local: VaultItem, remote: VaultItem) -> (winner: VaultItem, localWon: Bool) {
        if remote.modifiedAt > local.modifiedAt {
            var w = remote
            if !local.deleted { w.appendHistory(local.snapshot(reason: "Replaced by a newer edit from another device", at: local.modifiedAt)) }
            w.lastUsedAt = [local.lastUsedAt, remote.lastUsedAt].compactMap { $0 }.max()
            return (w, false)
        }
        var w = local
        if !remote.deleted { w.appendHistory(remote.snapshot(reason: "Replaced by a newer edit on this device", at: remote.modifiedAt)) }
        w.lastUsedAt = [local.lastUsedAt, remote.lastUsedAt].compactMap { $0 }.max()
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
}
