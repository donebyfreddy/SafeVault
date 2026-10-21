import Foundation
import LocalAuthentication
import Security

public protocol SecretStore: Sendable {
    func read(_ account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func delete(_ account: String)
}

public enum KeychainError: Error, LocalizedError, Equatable {
    case status(OSStatus)
    case biometryUnavailable
    case userCancelled
    case notStored

    public var errorDescription: String? {
        switch self {
        case .status(let s):
            if s == errSecMissingEntitlement {
                return "This build is not signed with an Apple Developer team, so the Keychain is not available. Choose your team in Xcode (Signing & Capabilities) and run again."
            }
            return "Keychain error \(s)."
        case .biometryUnavailable: return "Face ID / Touch ID is not available or not set up on this device."
        case .userCancelled: return "Authentication was cancelled."
        case .notStored: return "Biometric unlock is not set up yet."
        }
    }
}

/// Generic secrets (such as the Dropbox refresh token) in the Keychain.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.myvault.secrets") {
        self.service = service
    }

    private func base(_ account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func read(_ account: String) -> Data? {
        for dp in [true, false] {
            var q = base(account, dataProtection: dp)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data { return data }
        }
        return nil
    }

    public func write(_ data: Data, account: String) throws {
        // Prefer the data-protection keychain; unsigned macOS builds fall back to the file keychain.
        var lastStatus: OSStatus = errSecSuccess
        for dp in [true, false] {
            let query = base(account, dataProtection: dp)
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
            }
            if status == errSecSuccess { return }
            lastStatus = status
        }
        throw KeychainError.status(lastStatus)
    }

    public func delete(_ account: String) {
        for dp in [true, false] { SecItemDelete(base(account, dataProtection: dp) as CFDictionary) }
    }
}

/// Keeps the vault key behind Face ID / Touch ID, so unlocking does not need the master password.
public protocol BiometricKeyStore: Sendable {
    var biometryName: String { get }
    var isAvailable: Bool { get }
    func hasKey(vaultID: UUID) -> Bool
    func store(key: Data, vaultID: UUID) throws
    func load(vaultID: UUID, reason: String) async throws -> Data
    func remove(vaultID: UUID)
}

public final class KeychainBiometricStore: BiometricKeyStore {
    private let service = "com.myvault.biometric"

    public init() {}

    public var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    public var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private func query(_ vaultID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID.uuidString.lowercased(),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func hasKey(vaultID: UUID) -> Bool {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        var q = query(vaultID)
        q[kSecUseAuthenticationContext as String] = ctx
        q[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
        #if os(macOS)
        return legacyExists(vaultID)
        #else
        return false
        #endif
    }

    public func store(key: Data, vaultID: UUID) throws {
        remove(vaultID: vaultID)
        var error: Unmanaged<CFError>?
        // `biometryCurrentSet`: enrolling a new face or finger invalidates the key.
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error)
        else { throw KeychainError.biometryUnavailable }
        var q = query(vaultID)
        q[kSecValueData as String] = key
        q[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(q as CFDictionary, nil)
        #if os(macOS)
        // An ad-hoc signed Mac app (no Apple team) cannot use the biometric-protected keychain. Keep the key in
        // the normal keychain instead and ask for Touch ID in the app before it is read.
        if status == errSecMissingEntitlement { try storeLegacy(key: key, vaultID: vaultID); return }
        #endif
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    #if os(macOS)
    private func legacyQuery(_ vaultID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.myvault.biometric.legacy",
            kSecAttrAccount as String: vaultID.uuidString.lowercased(),
        ]
    }

    private func legacyExists(_ vaultID: UUID) -> Bool {
        var q = legacyQuery(vaultID)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    private func storeLegacy(key: Data, vaultID: UUID) throws {
        SecItemDelete(legacyQuery(vaultID) as CFDictionary)
        var q = legacyQuery(vaultID)
        q[kSecValueData as String] = key
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private func loadLegacy(vaultID: UUID, reason: String) async throws -> Data {
        let context = LAContext()
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) {
            throw KeychainError.userCancelled
        } catch {
            throw KeychainError.biometryUnavailable
        }
        var q = legacyQuery(vaultID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            throw status == errSecItemNotFound ? KeychainError.notStored : KeychainError.status(status)
        }
        return data
    }
    #endif

    public func load(vaultID: UUID, reason: String) async throws -> Data {
        #if os(macOS)
        if legacyExists(vaultID) { return try await loadLegacy(vaultID: vaultID, reason: reason) }
        #endif
        let q0 = query(vaultID)
        return try await Task.detached(priority: .userInitiated) {
            let ctx = LAContext()
            ctx.localizedReason = reason
            var q = q0
            q[kSecUseAuthenticationContext as String] = ctx
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            switch status {
            case errSecSuccess:
                guard let data = out as? Data else { throw KeychainError.notStored }
                return data
            case errSecItemNotFound: throw KeychainError.notStored
            case errSecUserCanceled, errSecAuthFailed: throw KeychainError.userCancelled
            default: throw KeychainError.status(status)
            }
        }.value
    }

    public func remove(vaultID: UUID) {
        SecItemDelete(query(vaultID) as CFDictionary)
        #if os(macOS)
        SecItemDelete(legacyQuery(vaultID) as CFDictionary)
        #endif
    }
}
