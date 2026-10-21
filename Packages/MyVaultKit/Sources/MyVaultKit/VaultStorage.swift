import Foundation

public struct RecordState: Codable, Equatable, Sendable {
    public var rev: String?
    public var dirty: Bool

    public init(rev: String? = nil, dirty: Bool = false) {
        self.rev = rev
        self.dirty = dirty
    }
}

/// Bookkeeping for sync. Contains only random ids and revision strings, never content.
public struct SyncState: Codable, Equatable, Sendable {
    public var records: [String: RecordState] = [:]
    public var headerRev: String?
    public var headerDirty: Bool = false
    public var lastSync: Date?
    /// Revision of vault.db the last time we synced with it, so an unchanged file is not downloaded again.
    public var remoteRev: String?

    public init() {}
}

/// Files on disk. Everything secret is already encrypted before it gets here.
///
///     header.json            KDF parameters + wrapped vault key
///     items/<uuid>.vitem     one AES-GCM encrypted record per item
///     syncstate.json         sync bookkeeping
public final class VaultStorage: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default

    public static let headerName = "header.json"
    public static func itemName(_ id: UUID) -> String { "\(id.uuidString.lowercased()).vitem" }
    public static func itemID(fromName name: String) -> UUID? {
        guard name.hasSuffix(".vitem") else { return nil }
        return UUID(uuidString: String(name.dropLast(6)))
    }

    public init(root: URL) {
        self.root = root
    }

    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("MyVault", isDirectory: true)
    }

    var itemsDir: URL { root.appendingPathComponent("items", isDirectory: true) }
    var headerURL: URL { root.appendingPathComponent(Self.headerName) }
    var stateURL: URL { root.appendingPathComponent("syncstate.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private func ensureDirs() throws {
        try fm.createDirectory(at: itemsDir, withIntermediateDirectories: true)
    }

    public var hasVault: Bool { fm.fileExists(atPath: headerURL.path) }

    public func loadHeader() throws -> VaultHeader? {
        guard hasVault else { return nil }
        return try Self.decoder.decode(VaultHeader.self, from: Data(contentsOf: headerURL))
    }

    public func saveHeader(_ header: VaultHeader) throws {
        try ensureDirs()
        try Self.encoder.encode(header).write(to: headerURL, options: .atomic)
    }

    func headerData() throws -> Data { try Data(contentsOf: headerURL) }

    func writeHeaderData(_ data: Data) throws {
        try ensureDirs()
        try data.write(to: headerURL, options: .atomic)
    }

    func listItemBlobs() throws -> [(id: UUID, data: Data)] {
        guard fm.fileExists(atPath: itemsDir.path) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: itemsDir.path)
        return try names.compactMap { name in
            guard let id = Self.itemID(fromName: name) else { return nil }
            return (id, try Data(contentsOf: itemsDir.appendingPathComponent(name)))
        }
    }

    func writeBlob(_ data: Data, id: UUID) throws {
        try ensureDirs()
        try data.write(to: itemsDir.appendingPathComponent(Self.itemName(id)), options: .atomic)
    }

    func readBlob(id: UUID) throws -> Data {
        try Data(contentsOf: itemsDir.appendingPathComponent(Self.itemName(id)))
    }

    func loadState() -> SyncState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? Self.decoder.decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    func saveState(_ state: SyncState) throws {
        try ensureDirs()
        try Self.encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Wipes the local copy. Used when disconnecting or resetting; Dropbox is untouched.
    public func destroy() throws {
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
    }

    /// Puts a header downloaded from Dropbox in place, so this device can unlock an existing vault.
    public func installDownloadedHeader(_ data: Data) throws {
        let header = try Self.decoder.decode(VaultHeader.self, from: data)
        guard header.version <= VaultHeader.currentVersion else { throw VaultError.unsupportedVersion(header.version) }
        try writeHeaderData(data)
    }
}
