import Foundation

/// The one file that goes to the cloud: `vault.db`.
///
/// It holds the vault header (key-derivation settings and the wrapped vault key, needed to unlock on a new
/// device) and ONE AES-256-GCM sealed blob with every item. Without the master password it is unreadable.
public enum VaultFile {
    public static let name = "vault.db"

    struct Container: Codable {
        var format: String
        var version: Int
        var header: VaultHeader
        var payload: Data
    }

    struct Payload: Codable {
        var items: [VaultItem]
    }

    static let formatName = "safevault-db"
    static let currentVersion = 2
    static let context = Data("myvault.db.v2".utf8)

    static func decode(_ data: Data) throws -> Container {
        let container: Container
        do { container = try VaultStorage.decoder.decode(Container.self, from: data) } catch { throw VaultError.corrupted }
        guard container.format == formatName else { throw VaultError.corrupted }
        guard container.version <= currentVersion else { throw VaultError.unsupportedVersion(container.version) }
        return container
    }

    /// The vault header stored in a downloaded `vault.db`, as the JSON that `VaultStorage.installDownloadedHeader`
    /// expects. A new device uses it to ask for the master password.
    public static func headerData(from fileData: Data) throws -> Data {
        try VaultStorage.encoder.encode(try decode(fileData).header)
    }
}
