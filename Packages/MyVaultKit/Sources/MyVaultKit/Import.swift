import Foundation

public struct ImportResult: Sendable {
    public var items: [VaultItem] = []
    public var warnings: [String] = []
    /// Entries that were templates or already deleted in the source app.
    public var skipped = 0
    public var format = "unknown"

    public var counts: [ItemKind: Int] {
        Dictionary(grouping: items, by: \.kind).mapValues(\.count)
    }
}

/// Reads exports from Safe (SafeInCloud) in XML or CSV, plus the usual `name,url,username,password` CSVs
/// from other password managers. Nothing from the file is ever dropped silently: fields that do not map
/// to something specific are kept as plain fields, and surprises are reported in `warnings`.
public enum SafeImporter {
    public static func parse(data: Data, now: Date = Date()) throws -> ImportResult {
        guard let text = decode(data) else { throw VaultError.invalidInput("The file is not readable text.") }
        let head = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if head.hasPrefix("<") { return try parseXML(data: Data(text.utf8), now: now) }
        return try parseCSV(text, now: now)
    }

    /// Removes entries that are already in the vault (same kind, name, username and password).
    public static func removingDuplicates(_ new: [VaultItem], existing: [VaultItem]) -> (unique: [VaultItem], duplicates: Int) {
        var seen = Set(existing.filter { !$0.deleted }.map(fingerprint))
        var unique = [VaultItem]()
        for item in new where seen.insert(fingerprint(item)).inserted { unique.append(item) }
        return (unique, new.count - unique.count)
    }

    static func fingerprint(_ i: VaultItem) -> String {
        "\(i.kind.rawValue)|\(i.name.lowercased())|\(i.username ?? "")|\(i.password ?? "")|\(i.fields.map(\.value).joined(separator: ","))"
    }

    private static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: XML

    static func parseXML(data: Data, now: Date) throws -> ImportResult {
        let delegate = SafeXMLDelegate(now: now)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw VaultError.invalidInput("The XML file could not be read: \(parser.parserError?.localizedDescription ?? "unknown error").")
        }
        var result = delegate.result
        result.format = "Safe XML"
        if result.items.isEmpty && result.skipped == 0 {
            result.warnings.append("The file has no entries. Is it the XML export from Safe?")
        }
        return result
    }

    // MARK: CSV

    static func parseCSV(_ text: String, now: Date) throws -> ImportResult {
        let rows = CSV.parse(text)
        guard let header = rows.first, rows.count > 0 else { throw VaultError.invalidInput("The CSV file is empty.") }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        func index(_ synonyms: [String]) -> Int? {
            for s in synonyms { if let i = names.firstIndex(of: s) { return i } }
            return nil
        }
        let nameIdx = index(["name", "title", "item", "site", "account", "label"]) ?? 0
        let userIdx = index(["login", "username", "user name", "user", "login name", "login username", "email"])
        let passIdx = index(["password", "pass", "login password"])
        let urlIdx = index(["website", "url", "web site", "login uri", "link", "login url"])
        let notesIdx = index(["notes", "note", "comments", "memo", "extra"])
        let totpIdx = index(["totp", "otp", "one time password", "one-time password", "2fa", "login totp", "otpauth"])
        let known = Set([nameIdx, userIdx, passIdx, urlIdx, notesIdx, totpIdx].compactMap { $0 })

        var result = ImportResult()
        result.format = "CSV"
        if passIdx == nil && userIdx == nil {
            result.warnings.append("No password or username column found. Entries are imported as notes with every column kept.")
        }

        for (n, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func cell(_ i: Int?) -> String {
                guard let i, i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var fields = [ItemField]()
            if !cell(userIdx).isEmpty { fields.append(ItemField(label: ItemField.usernameLabel, value: cell(userIdx), type: cell(userIdx).contains("@") ? .email : .text)) }
            if !cell(passIdx).isEmpty { fields.append(ItemField(label: ItemField.passwordLabel, value: cell(passIdx), type: .secret)) }
            if !cell(urlIdx).isEmpty { fields.append(ItemField(label: ItemField.websiteLabel, value: cell(urlIdx), type: .url)) }

            var totp: String? = nil
            if !cell(totpIdx).isEmpty {
                if let secret = TOTP.normalizedSecret(from: cell(totpIdx)) { totp = secret } else {
                    fields.append(ItemField(label: "One-time password", value: cell(totpIdx), type: .secret))
                    result.warnings.append("Row \(n + 2): the one-time password is not a valid secret, kept as a plain field.")
                }
            }
            for (i, value) in row.enumerated() where !known.contains(i) {
                let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty, i < header.count else { continue }
                let label = header[i].trimmingCharacters(in: .whitespacesAndNewlines)
                fields.append(ItemField(label: label.isEmpty ? "Column \(i + 1)" : label, value: v, type: inferType(label: label, value: v)))
            }

            var item = VaultItem(
                kind: .login, name: cell(nameIdx).isEmpty ? "Untitled" : cell(nameIdx),
                fields: fields, notes: cell(notesIdx), totpSecret: totp, createdAt: now)
            item.kind = Kinds.infer(name: item.name, fields: item.fields, notes: item.notes, hasPassword: item.password != nil)
            result.items.append(item)
        }
        return result
    }

    static func inferType(label: String, value: String) -> FieldType {
        let l = label.lowercased()
        if l.contains("password") || l.contains("pin") || l.contains("secret") || l.contains("cvv") || l.contains("cvc") { return .secret }
        if l.contains("mail") { return .email }
        if l.contains("phone") || l.contains("tel") { return .phone }
        if l.contains("url") || l.contains("website") || value.lowercased().hasPrefix("http") { return .url }
        return .text
    }
}

enum Kinds {
    /// Safe stores everything as free-form "cards", so the type has to be guessed from what is inside.
    static func infer(name: String, fields: [ItemField], notes: String, hasPassword: Bool) -> ItemKind {
        let labels = fields.map { $0.label.lowercased() }
        let joined = ([name.lowercased()] + labels).joined(separator: " ")
        if labels.contains(where: { $0.contains("card number") || $0 == "number" && labels.contains(where: { $0.contains("expir") }) || $0.contains("cvv") || $0.contains("cvc") }) { return .card }
        if joined.contains("credit card") || joined.contains("debit card") { return .card }
        if joined.contains("wi-fi") || joined.contains("wifi") || labels.contains(where: { $0.contains("ssid") || $0.contains("network") }) { return .wifi }
        if joined.contains("passport") || joined.contains("driver") || joined.contains("licence") || labels.contains(where: { $0.contains("passport") || $0.contains("id number") || $0.contains("date of birth") }) { return .identity }
        if !hasPassword && !fields.contains(where: { $0.label.caseInsensitiveCompare(ItemField.usernameLabel) == .orderedSame }) && fields.allSatisfy({ $0.type != .url }) && !notes.isEmpty && fields.isEmpty { return .note }
        return .login
    }
}

// MARK: - XML delegate

private final class SafeXMLDelegate: NSObject, XMLParserDelegate {
    var result = ImportResult()
    let now: Date

    private var labels = [String: String]()
    private var card: CardBuilder?
    private var currentField: (name: String, type: String)?
    private var text = ""
    private var inNotes = false
    private var inLabelID = false
    private var unknownTags = Set<String>()

    private struct CardBuilder {
        var title = "Untitled"
        var id: UUID
        var timestamp: Date
        var deleted = false
        var template = false
        var fields: [(name: String, type: String, value: String)] = []
        var notes = ""
        var labelIDs: [String] = []
    }

    init(now: Date) { self.now = now }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "label":
            if let id = a["id"], let n = a["name"] { labels[id] = n }
        case "card":
            var c = CardBuilder(id: UUID(), timestamp: now)
            c.title = a["title"] ?? "Untitled"
            c.deleted = a["deleted"] == "true"
            c.template = a["template"] == "true"
            if let ts = a["time_stamp"], var secs = Double(ts) {
                if secs > 1e11 { secs /= 1000 }  // milliseconds
                c.timestamp = Date(timeIntervalSince1970: secs)
            }
            card = c
        case "field":
            guard card != nil else { return }
            currentField = (a["name"] ?? "", a["type"] ?? "text")
            text = ""
        case "notes":
            inNotes = true
            text = ""
        case "label_id":
            inLabelID = true
            text = ""
        case "database", "root", "labels", "cards":
            break
        default:
            if card != nil, unknownTags.insert(name).inserted {
                result.warnings.append("The element <\(name)> is not recognised and was ignored. If something is missing, send a sample export so the importer can be extended.")
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "field":
            if let f = currentField { card?.fields.append((f.name, f.type, text.trimmingCharacters(in: .whitespacesAndNewlines))) }
            currentField = nil
        case "notes" where inNotes:
            card?.notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
            inNotes = false
        case "label_id" where inLabelID:
            card?.labelIDs.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            inLabelID = false
        case "card":
            if let c = card { finish(c) }
            card = nil
        default: break
        }
    }

    private func finish(_ c: CardBuilder) {
        if c.template || c.deleted { result.skipped += 1; return }

        var fields = [ItemField]()
        var totp: String? = nil
        var sawPassword = false
        for f in c.fields where !f.value.isEmpty {
            let type = f.type.lowercased()
            let lname = f.name.lowercased()
            if type.contains("one_time") || type.contains("totp") || type == "otp" || lname.contains("one-time") || lname.contains("one time") || lname == "totp" {
                if let secret = TOTP.normalizedSecret(from: f.value), totp == nil { totp = secret; continue }
                result.warnings.append("\"\(c.title)\": the one-time password field is not a valid secret, kept as a plain field.")
                fields.append(ItemField(label: f.name, value: f.value, type: .secret))
                continue
            }
            switch type {
            case "login":
                fields.append(ItemField(label: fields.contains { $0.label == ItemField.usernameLabel } ? f.name : ItemField.usernameLabel, value: f.value, type: .text))
            case "password":
                let first = !sawPassword
                sawPassword = true
                fields.append(ItemField(label: first ? ItemField.passwordLabel : f.name, value: f.value, type: .secret))
            case "website":
                fields.append(ItemField(label: fields.contains { $0.label == ItemField.websiteLabel } ? f.name : ItemField.websiteLabel, value: f.value, type: .url))
            case "pin", "secret", "cvv": fields.append(ItemField(label: f.name, value: f.value, type: .secret))
            case "email": fields.append(ItemField(label: f.name, value: f.value, type: .email))
            case "phone": fields.append(ItemField(label: f.name, value: f.value, type: .phone))
            case "expiry", "date": fields.append(ItemField(label: f.name, value: f.value, type: .date))
            default: fields.append(ItemField(label: f.name.isEmpty ? "Field" : f.name, value: f.value, type: SafeImporter.inferType(label: f.name, value: f.value)))
            }
        }

        let kind = Kinds.infer(name: c.title, fields: fields, notes: c.notes, hasPassword: sawPassword)
        let tags = c.labelIDs.compactMap { labels[$0] }
        var item = VaultItem(
            id: UUID(), kind: kind, name: c.title, fields: fields, notes: c.notes, tags: tags,
            totpSecret: totp, createdAt: c.timestamp, modifiedAt: c.timestamp)
        item.vault = "Personal"
        result.items.append(item)
    }
}

// MARK: - CSV

enum CSV {
    /// RFC 4180 with the usual tolerance: quoted fields, doubled quotes, CRLF or LF, and `;` or `,` as separator.
    static func parse(_ input: String) -> [[String]] {
        let text = input.hasPrefix("\u{FEFF}") ? String(input.dropFirst()) : input
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let sep: Character = firstLine.filter({ $0 == ";" }).count > firstLine.filter({ $0 == "," }).count ? ";" : ","

        var rows = [[String]]()
        var row = [String]()
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        var i = 0
        chars.append("\n")
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else if c == "\r" {
                // handled with the following \n or ends the row on its own
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.append(c) }
            i += 1
        }
        return rows
    }
}
