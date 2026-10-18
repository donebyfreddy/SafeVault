import Foundation

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case login, card, note, identity, wifi

    public var title: String {
        switch self {
        case .login: "Login"
        case .card: "Credit Card"
        case .note: "Secure Note"
        case .identity: "Identity"
        case .wifi: "Wi-Fi"
        }
    }
}

public enum FieldType: String, Codable, Sendable {
    case text, secret, url, email, phone, date
}

public struct ItemField: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var value: String
    public var type: FieldType

    public init(id: UUID = UUID(), label: String, value: String, type: FieldType = .text) {
        self.id = id
        self.label = label
        self.value = value
        self.type = type
    }

    public static let usernameLabel = "Username"
    public static let passwordLabel = "Password"
    public static let websiteLabel = "Website"
}

public struct PasswordHistoryEntry: Codable, Hashable, Sendable {
    public var value: String
    public var changedAt: Date

    public init(value: String, changedAt: Date = Date()) {
        self.value = value
        self.changedAt = changedAt
    }
}

/// An earlier version of an item, kept when a sync conflict or an edit replaces it.
public struct ItemSnapshot: Codable, Hashable, Sendable {
    public var savedAt: Date
    public var reason: String
    public var name: String
    public var fields: [ItemField]
    public var notes: String

    public init(savedAt: Date = Date(), reason: String, name: String, fields: [ItemField], notes: String) {
        self.savedAt = savedAt
        self.reason = reason
        self.name = name
        self.fields = fields
        self.notes = notes
    }
}

public struct VaultItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ItemKind
    public var name: String
    public var vault: String
    public var fields: [ItemField]
    public var notes: String
    public var tags: [String]
    public var favorite: Bool
    public var archived: Bool
    public var totpSecret: String?
    public var backupCodes: [String]
    public var passwordHistory: [PasswordHistoryEntry]
    public var history: [ItemSnapshot]
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastUsedAt: Date?
    /// Tombstone: the item was deleted but the record is kept so the deletion syncs.
    public var deleted: Bool

    public static let maxHistory = 20

    public init(
        id: UUID = UUID(),
        kind: ItemKind = .login,
        name: String,
        vault: String = "Personal",
        fields: [ItemField] = [],
        notes: String = "",
        tags: [String] = [],
        favorite: Bool = false,
        archived: Bool = false,
        totpSecret: String? = nil,
        backupCodes: [String] = [],
        passwordHistory: [PasswordHistoryEntry] = [],
        history: [ItemSnapshot] = [],
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        deleted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.vault = vault
        self.fields = fields
        self.notes = notes
        self.tags = tags
        self.favorite = favorite
        self.archived = archived
        self.totpSecret = totpSecret
        self.backupCodes = backupCodes
        self.passwordHistory = passwordHistory
        self.history = history
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
        self.deleted = deleted
    }

    // MARK: Convenience

    public func field(_ label: String) -> ItemField? {
        fields.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    public var username: String? {
        let v = field(ItemField.usernameLabel)?.value ?? fields.first(where: { $0.type == .email })?.value
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// The main password of the item (login password, Wi-Fi password), if any.
    public var password: String? {
        let v = field(ItemField.passwordLabel)?.value
            ?? fields.first(where: { $0.type == .secret && $0.label.lowercased().contains("password") })?.value
        return (v?.isEmpty ?? true) ? nil : v
    }

    public var website: String? {
        let v = field(ItemField.websiteLabel)?.value ?? fields.first(where: { $0.type == .url })?.value
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// Secondary line shown in lists.
    public var subtitle: String {
        if let username { return username }
        switch kind {
        case .card:
            if let n = fields.first(where: { $0.label.lowercased().contains("number") })?.value, n.count >= 4 {
                return "•••• \(n.suffix(4))"
            }
        case .note:
            let line = notes.split(separator: "\n").first.map(String.init) ?? ""
            if !line.isEmpty { return line }
        default: break
        }
        return fields.first(where: { $0.type != .secret && !$0.value.isEmpty })?.value ?? kind.title
    }

    // MARK: Mutation

    public mutating func touch(_ date: Date = Date()) { modifiedAt = date }

    /// Sets the main password, remembering the previous one in the history.
    public mutating func setPassword(_ newValue: String, at date: Date = Date()) {
        if let idx = fields.firstIndex(where: { $0.label.caseInsensitiveCompare(ItemField.passwordLabel) == .orderedSame }) {
            let old = fields[idx].value
            if !old.isEmpty, old != newValue {
                passwordHistory.insert(PasswordHistoryEntry(value: old, changedAt: date), at: 0)
                if passwordHistory.count > 50 { passwordHistory.removeLast(passwordHistory.count - 50) }
            }
            fields[idx].value = newValue
        } else {
            fields.append(ItemField(label: ItemField.passwordLabel, value: newValue, type: .secret))
        }
        modifiedAt = date
    }

    public func snapshot(reason: String, at date: Date = Date()) -> ItemSnapshot {
        ItemSnapshot(savedAt: date, reason: reason, name: name, fields: fields, notes: notes)
    }

    public mutating func appendHistory(_ snap: ItemSnapshot) {
        history.insert(snap, at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
    }
}
