import CommonCrypto
import CryptoKit
import Foundation

public enum VaultError: Error, Equatable, LocalizedError {
    case wrongPassword
    case corrupted
    case unsupportedVersion(Int)
    case differentVault
    case notFound
    case alreadyExists
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: "The master password is incorrect."
        case .corrupted: "The vault data is damaged or has been modified."
        case .unsupportedVersion(let v): "This vault was created by a newer version of the app (format \(v))."
        case .differentVault: "The vault in Dropbox is a different vault from the one on this device."
        case .notFound: "Item not found."
        case .alreadyExists: "A vault already exists here."
        case .invalidInput(let m): m
        }
    }
}

public struct KDFParams: Codable, Equatable, Sendable {
    public var algorithm: String
    public var iterations: Int
    public var salt: Data

    public init(algorithm: String = "pbkdf2-hmac-sha256", iterations: Int, salt: Data) {
        self.algorithm = algorithm
        self.iterations = iterations
        self.salt = salt
    }
}

/// Small, non-secret file stored next to the encrypted items. It holds the KDF
/// parameters and the vault key, encrypted with a key derived from the master password.
public struct VaultHeader: Codable, Equatable, Sendable {
    public var version: Int
    public var vaultID: UUID
    public var kdf: KDFParams
    public var wrappedKey: Data
    public var createdAt: Date
    public var updatedAt: Date
    /// Increases every time the header changes (a new master password). Decides which copy is newer.
    public var revision: Int

    public static let currentVersion = 1
}

public enum VaultCrypto {
    /// OWASP 2023 guidance for PBKDF2-HMAC-SHA256.
    public static let defaultIterations = 600_000

    private static let wrapContext = Data("myvault.key.v1".utf8)

    public static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "Secure random generator failed")
        return data
    }

    public static func deriveKey(password: String, params: KDFParams) throws -> SymmetricKey {
        guard params.algorithm == "pbkdf2-hmac-sha256", params.iterations > 0 else {
            throw VaultError.corrupted
        }
        // NFKC so the same password typed on different keyboards derives the same key.
        let pw = Array(password.precomposedStringWithCompatibilityMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = params.salt.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.map { Int8(bitPattern: $0) }, pw.count,
                salt.bindMemory(to: UInt8.self).baseAddress, params.salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(params.iterations),
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else { throw VaultError.corrupted }
        return SymmetricKey(data: derived)
    }

    /// Creates a brand-new vault key wrapped by the master password.
    public static func makeHeader(
        password: String,
        iterations: Int = defaultIterations,
        vaultID: UUID = UUID(),
        now: Date = Date()
    ) throws -> (header: VaultHeader, vaultKey: SymmetricKey) {
        guard !password.isEmpty else { throw VaultError.invalidInput("The master password cannot be empty.") }
        let vaultKey = SymmetricKey(size: .bits256)
        let params = KDFParams(iterations: iterations, salt: randomBytes(16))
        let wrapper = try deriveKey(password: password, params: params)
        let keyData = vaultKey.withUnsafeBytes { Data($0) }
        let wrapped = try seal(keyData, key: wrapper, context: wrapContext)
        let header = VaultHeader(
            version: VaultHeader.currentVersion, vaultID: vaultID, kdf: params,
            wrappedKey: wrapped, createdAt: now, updatedAt: now, revision: 0
        )
        return (header, vaultKey)
    }

    public static func unlock(password: String, header: VaultHeader) throws -> SymmetricKey {
        guard header.version <= VaultHeader.currentVersion else { throw VaultError.unsupportedVersion(header.version) }
        let wrapper = try deriveKey(password: password, params: header.kdf)
        do {
            let keyData = try open(header.wrappedKey, key: wrapper, context: wrapContext)
            guard keyData.count == 32 else { throw VaultError.corrupted }
            return SymmetricKey(data: keyData)
        } catch VaultError.corrupted {
            // GCM authentication failing here means the derived key was wrong.
            throw VaultError.wrongPassword
        }
    }

    /// Re-wraps the same vault key under a new password. Items do not need re-encrypting.
    public static func changePassword(
        header: VaultHeader, oldPassword: String, newPassword: String,
        iterations: Int = defaultIterations, now: Date = Date()
    ) throws -> VaultHeader {
        let vaultKey = try unlock(password: oldPassword, header: header)
        guard !newPassword.isEmpty else { throw VaultError.invalidInput("The master password cannot be empty.") }
        let params = KDFParams(iterations: iterations, salt: randomBytes(16))
        let wrapper = try deriveKey(password: newPassword, params: params)
        let keyData = vaultKey.withUnsafeBytes { Data($0) }
        var updated = header
        updated.kdf = params
        updated.wrappedKey = try seal(keyData, key: wrapper, context: wrapContext)
        updated.updatedAt = now
        updated.revision = header.revision + 1
        return updated
    }

    // MARK: AES-256-GCM

    public static func seal(_ data: Data, key: SymmetricKey, context: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: context)
        guard let combined = box.combined else { throw VaultError.corrupted }
        return Data([1]) + combined
    }

    public static func open(_ blob: Data, key: SymmetricKey, context: Data) throws -> Data {
        guard let version = blob.first else { throw VaultError.corrupted }
        guard version == 1 else { throw VaultError.unsupportedVersion(Int(version)) }
        do {
            let box = try AES.GCM.SealedBox(combined: blob.dropFirst())
            return try AES.GCM.open(box, using: key, authenticating: context)
        } catch {
            throw VaultError.corrupted
        }
    }

    /// Items are bound to their id so a record cannot be swapped for another one.
    static func itemContext(_ id: UUID) -> Data { Data("myvault.item.\(id.uuidString.lowercased())".utf8) }
}
