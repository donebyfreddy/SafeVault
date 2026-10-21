import Foundation

/// A copy of a file that the cloud made when two devices wrote the same file at the same time
/// (iCloud Drive calls them "name 2.ext"). They are kept, never deleted, and merged by the sync engine.
public struct ConflictCopy: Sendable, Equatable {
    public var fileName: String
    /// The name the file should have had: `header.json` or `<uuid>.vitem`.
    public var baseName: String
    public var data: Data

    public init(fileName: String, baseName: String, data: Data) {
        self.fileName = fileName
        self.baseName = baseName
        self.data = data
    }
}

/// Keeps the encrypted files in an ordinary folder. Pick a folder in iCloud Drive (or Dropbox, Google Drive,
/// OneDrive... anything that shows up in Files) and that service carries the files to your other devices.
///
/// Files are read and written through `NSFileCoordinator`, as iCloud requires, and files that exist only in the
/// cloud are downloaded first. The revision of a file is its size and modification time.
public final class FolderRemoteStore: RemoteStore, @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default

    public static let resolvedFolderName = "Resolved conflicts"

    /// How long to wait for iCloud to deliver a file that is not on this device yet.
    public var downloadTimeout: TimeInterval = 30

    public init(root: URL) {
        self.root = root
    }

    // MARK: Names

    /// `.name.icloud` is how older iCloud versions show a file that is not downloaded; the real name is `name`.
    static func canonicalName(of fileName: String) -> String {
        if fileName.hasPrefix("."), fileName.hasSuffix(".icloud"), fileName.count > 8 {
            return String(fileName.dropFirst().dropLast(7))
        }
        return fileName
    }

    static func isOurs(_ name: String) -> Bool {
        name == VaultFile.name || name == VaultStorage.headerName || VaultStorage.itemID(fromName: name) != nil
    }

    /// `"<uuid> 2.vitem"` or `"header 2.json"` (also "(1)" style) → the name the file should have had.
    static func conflictBaseName(of fileName: String) -> String? {
        let name = canonicalName(of: fileName)
        let pattern = #"^(header|vault|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?: \d+| \(\d+\))\.(json|vitem|db)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let base = Range(m.range(at: 1), in: name), let ext = Range(m.range(at: 2), in: name) else { return nil }
        let candidate = "\(name[base]).\(name[ext])"
        let lower = candidate.lowercased()
        guard Self.isOurs(lower) else { return nil }
        return lower
    }

    // MARK: RemoteStore

    public func listFiles() async throws -> [RemoteFile] {
        var result = [RemoteFile]()
        for entry in try entries() where Self.isOurs(entry.name) {
            try await ensureDownloaded(entry.name)
            result.append(RemoteFile(name: entry.name, rev: try rev(of: root.appendingPathComponent(entry.name))))
        }
        return result
    }

    public func download(_ name: String) async throws -> (data: Data, rev: String) {
        try await ensureDownloaded(name)
        let url = root.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { throw RemoteError.notFound }
        return (try coordinatedRead(url), try rev(of: url))
    }

    public func upload(_ name: String, data: Data, expectedRev: String?) async throws -> String {
        let url = root.appendingPathComponent(name)
        try await ensureDownloaded(name)
        let exists = fm.fileExists(atPath: url.path)
        if let expectedRev {
            guard exists else { throw RemoteError.notFound }
            guard try rev(of: url) == expectedRev else { throw RemoteError.conflict }
        } else if exists {
            throw RemoteError.conflict
        }
        try coordinatedWrite(url, data: data)
        return try rev(of: url)
    }

    public func conflictCopies() async throws -> [ConflictCopy] {
        var copies = [ConflictCopy]()
        for entry in try entries() {
            guard let base = Self.conflictBaseName(of: entry.name) else { continue }
            try await ensureDownloaded(entry.name)
            copies.append(ConflictCopy(fileName: entry.name, baseName: base, data: try coordinatedRead(root.appendingPathComponent(entry.name))))
        }
        return copies
    }

    public func deleteFile(_ name: String) async throws {
        for candidate in [name, ".\(name).icloud"] {
            let url = root.appendingPathComponent(candidate)
            guard fm.fileExists(atPath: url.path) else { continue }
            var coordError: NSError?
            var failure: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { target in
                do { try fm.removeItem(at: target) } catch { failure = error }
            }
            if let error = coordError ?? failure { throw RemoteError.server(error.localizedDescription) }
        }
    }

    /// Moves a handled conflict copy into "Resolved conflicts" instead of deleting it.
    public func resolveConflictCopy(_ fileName: String) async throws {
        let source = root.appendingPathComponent(fileName)
        let folder = root.appendingPathComponent(Self.resolvedFolderName, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(fileName)
        if fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(fileName)")
        }
        var coordError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordError
        ) { from, to in
            do { try fm.moveItem(at: from, to: to) } catch { failure = error }
        }
        if let error = coordError ?? failure { throw RemoteError.server(error.localizedDescription) }
    }

    // MARK: Files

    private struct Entry { var name: String }

    private func entries() throws -> [Entry] {
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: root.path)
        } catch {
            throw RemoteError.server("The sync folder cannot be read. Choose it again in Settings.")
        }
        // A placeholder and the real file can both be listed; keep one entry per real name.
        var seen = Set<String>()
        return names.compactMap { raw in
            let name = Self.canonicalName(of: raw)
            return seen.insert(name).inserted ? Entry(name: name) : nil
        }
    }

    /// Size and modification time in milliseconds. Changes whenever the content is rewritten.
    private func rev(of url: URL) throws -> String {
        // URL objects cache file attributes; without this a revision read after a write would be the old one.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let ms = Int(((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
        return "\(values.fileSize ?? 0)-\(ms)"
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordError { throw RemoteError.server(coordError.localizedDescription) }
        switch result {
        case .success(let data): return data
        case .failure(let error): throw RemoteError.server(error.localizedDescription)
        case nil: throw RemoteError.server("The file could not be read.")
        }
    }

    private func coordinatedWrite(_ url: URL, data: Data) throws {
        var coordError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do { try data.write(to: writeURL, options: .atomic) } catch { failure = error }
        }
        if let error = coordError ?? failure { throw RemoteError.server(error.localizedDescription) }
    }

    /// Makes sure a file that lives only in iCloud is on this device before it is read.
    private func ensureDownloaded(_ name: String) async throws {
        let url = root.appendingPathComponent(name)
        let placeholder = root.appendingPathComponent(".\(name).icloud")
        let hasPlaceholder = fm.fileExists(atPath: placeholder.path)

        func isReady() -> Bool {
            guard fm.fileExists(atPath: url.path) else { return false }
            guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                  v.isUbiquitousItem == true else { return true }  // an ordinary file
            return v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded
        }

        if !hasPlaceholder, !fm.fileExists(atPath: url.path) { return }  // not there at all: nothing to wait for
        if !hasPlaceholder, isReady() { return }

        try? fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(downloadTimeout)
        while Date() < deadline {
            if isReady(), !fm.fileExists(atPath: placeholder.path) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RemoteError.server("iCloud has not finished downloading \"\(name)\" yet. Try again in a moment.")
    }
}
