import MyVaultKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct EditItemView: View {
    @State var item: VaultItem
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var original: VaultItem
    @State private var totpText: String
    @State private var codesText: String
    @State private var tagsText: String
    @State private var shown = Set<UUID>()
    @State private var choosingImage = false
    @State private var choosingPhoto = false
    @State private var logoProblem: String?
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

    init(item: VaultItem, isNew: Bool) {
        _item = State(initialValue: item)
        _original = State(initialValue: item)
        _totpText = State(initialValue: item.totpSecret ?? "")
        _codesText = State(initialValue: item.backupCodes.joined(separator: "\n"))
        _tagsText = State(initialValue: item.tags.joined(separator: ", "))
        self.isNew = isNew
    }

    private var totpInvalid: Bool {
        !totpText.trimmingCharacters(in: .whitespaces).isEmpty && TOTP.normalizedSecret(from: totpText) == nil
    }

    private enum Tab: String, CaseIterable {
        case details = "Details", notes = "Notes", security = "2FA", more = "More"
    }

    @State private var tab = Tab.details
    @State private var choosingLook = false

    private var tabs: [Tab] { item.kind == .login ? Tab.allCases : [.details, .notes, .more] }

    private var website: String? { item.website }

    /// Usernames already used in other entries, most common first.
    private var knownUsernames: [String] {
        var counts = [String: Int]()
        for other in model.items where other.id != item.id {
            if let u = other.username { counts[u, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    Picker("Section", selection: $tab) {
                        ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch tab {
                    case .details: detailsTab
                    case .notes: card { TextEditor(text: $item.notes).frame(minHeight: 160).scrollContentBackground(.hidden) }
                    case .security: securityTab
                    case .more: moreTab
                    }
                }
                .padding(16)
            }
            .background(VT.detailBackground)
            .navigationTitle(isNew ? "New \(item.kind.title)" : "Edit \(original.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(item.name.trimmingCharacters(in: .whitespaces).isEmpty || totpInvalid)
                }
            }
            .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                useImage(try? Data(contentsOf: url))
            }
            #if os(iOS)
            .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, picked in
                Task { useImage(try? await picked?.loadTransferable(type: Data.self)) }
            }
            #endif
            .sheet(isPresented: $choosingLook) {
                LookPicker(name: item.name, kind: item.kind, symbol: $item.tileSymbol, color: $item.tileColor)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 600, idealHeight: 680)
        #endif
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VT.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(VT.line))
    }

    private var header: some View {
        HStack(spacing: 14) {
            TextField("Name", text: $item.name)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(VT.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(VT.line))
            Menu {
                Button { useWebsiteLogo() } label: { Label("Use the website's logo", systemImage: "globe") }
                    .disabled(website == nil)
                Button { choosingLook = true } label: { Label("Choose a symbol or colour…", systemImage: "paintpalette") }
                #if os(iOS)
                Button { choosingPhoto = true } label: { Label("Use your own image…", systemImage: "photo") }
                #else
                Button { choosingImage = true } label: { Label("Use your own image…", systemImage: "photo") }
                #endif
            } label: {
                ServiceTile(name: item.name, kind: item.kind, icon: item.icon, symbol: item.tileSymbol, color: item.tileColor, size: 56)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill").font(.system(size: 18))
                            .foregroundStyle(VT.blue, VT.surface).offset(x: 5, y: 5)
                    }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Change the logo")
        }
    }

    private var detailsTab: some View {
        VStack(spacing: 12) {
            if let logoProblem { Text(logoProblem).font(.caption).foregroundStyle(VT.red) }
            card {
                ForEach(Array($item.fields.enumerated()), id: \.element.id) { index, $field in
                    if index > 0 { Divider().padding(.vertical, 10) }
                    FieldEditor(field: $field, shown: $shown, suggestions: knownUsernames) {
                        item.fields.removeAll { $0.id == field.id }
                    }
                }
                if !item.fields.isEmpty { Divider().padding(.vertical, 10) }
                Menu {
                    Button("Text") { addField(.text, "Field") }
                    Button("Password") { addField(.secret, "Password") }
                    Button("Website") { addField(.url, "Website") }
                    Button("Email") { addField(.email, "Email") }
                    Button("Phone") { addField(.phone, "Phone") }
                } label: {
                    Label("Add field", systemImage: "plus.circle.fill").font(.system(size: 14, weight: .medium))
                }
                .menuStyle(.button).buttonStyle(.plain).foregroundStyle(VT.blue)
            }
        }
    }

    private var securityTab: some View {
        VStack(spacing: 12) {
            card {
                Text("One-time password (2FA)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Secret key or otpauth:// link", text: $totpText)
                    .textFieldStyle(.plain).padding(.top, 6)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Text(totpInvalid ? "That does not look like a valid secret key." : "Paste the setup key a website shows next to its QR code. The app then shows the 6-digit codes.")
                    .font(.caption).foregroundStyle(totpInvalid ? VT.red : .secondary).padding(.top, 6)
            }
            card {
                Text("Backup codes").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextEditor(text: $codesText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
                Text("One code per line.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var moreTab: some View {
        VStack(spacing: 12) {
            card {
                Picker("Vault", selection: $item.vault) {
                    ForEach(model.vaultNames, id: \.self) { Text($0).tag($0) }
                }
                Divider().padding(.vertical, 8)
                Toggle("Favorite", isOn: $item.favorite)
            }
            card {
                Text("Tags").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Comma separated", text: $tagsText).textFieldStyle(.plain).padding(.top, 6)
            }
        }
    }

    private func useWebsiteLogo() {
        item.icon = nil
        item.iconCustom = nil
        item.iconCheckedAt = nil
        item.tileSymbol = nil
        item.tileColor = nil
    }

    /// Shrinks a chosen picture to a small PNG and keeps it as this entry's own logo.
    private func useImage(_ data: Data?) {
        guard let data, let png = SiteIcon.normalize(imageData: data, maxDimension: 128, maxBytes: 40_000) else {
            logoProblem = "That image could not be used. Try a PNG or JPEG that is at least 16 pixels wide."
            return
        }
        logoProblem = nil
        item.icon = png
        item.iconCustom = true
        item.tileSymbol = nil
        item.tileColor = nil
    }

    private func addField(_ type: FieldType, _ label: String) {
        item.fields.append(ItemField(label: label, value: "", type: type))
    }

    private func save() {
        var result = item
        result.name = item.name.trimmingCharacters(in: .whitespaces)
        // Drop rows that were left empty so templates do not leave blank fields behind.
        result.fields = item.fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        result.totpSecret = TOTP.normalizedSecret(from: totpText)
        result.backupCodes = codesText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        result.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // A different website means a different logo (unless you chose the image yourself).
        if result.iconCustom != true, original.website != result.website {
            result.icon = nil
            result.iconCheckedAt = nil
        }
        // Changing the password keeps the old one in the history.
        if let old = original.password, !old.isEmpty, let new = result.password, new != old {
            result.passwordHistory.insert(PasswordHistoryEntry(value: old), at: 0)
        }
        // Keep a copy of what was there before, so an accidental edit can be undone.
        if !isNew, (original.fields != result.fields || original.notes != result.notes || original.name != result.name) {
            result.appendHistory(original.snapshot(reason: "Edited on this device"))
        }
        model.save(result)
        dismiss()
    }
}

private struct FieldEditor: View {
    @Binding var field: ItemField
    @Binding var shown: Set<UUID>
    var suggestions: [String] = []
    var onDelete: () -> Void
    @FocusState private var focused: Bool

    private var isPassword: Bool { field.type == .secret && field.label.caseInsensitiveCompare(ItemField.passwordLabel) == .orderedSame }
    private var isUsername: Bool { field.label.caseInsensitiveCompare(ItemField.usernameLabel) == .orderedSame || field.type == .email }
    private var hidden: Bool { field.type == .secret && !shown.contains(field.id) }

    /// Usernames from other entries that start with what has been typed so far.
    private var matches: [String] {
        guard isUsername, focused else { return [] }
        let typed = field.value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return [] }
        return Array(suggestions.filter { $0.lowercased().hasPrefix(typed) && $0.lowercased() != typed }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $field.label)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(VT.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(field.label)")
            }
            HStack(spacing: 8) {
                Group {
                    if hidden {
                        SecureField("", text: $field.value, prompt: Text(isPassword ? "Tap to suggest a password" : "Value"))
                    } else {
                        TextField("", text: $field.value, prompt: Text("Value"))
                            .font(.system(size: 15, design: field.type == .secret ? .monospaced : .default))
                    }
                }
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(field.type == .email ? .emailAddress : field.type == .url ? .URL : field.type == .phone ? .phonePad : .default)
                #endif

                if field.type == .secret {
                    IconButton(system: hidden ? "eye" : "eye.slash", label: "Show or hide") {
                        if hidden { shown.insert(field.id) } else { shown.remove(field.id) }
                    }
                    if isPassword {
                        IconButton(system: "wand.and.stars", label: "Generate a strong password") { suggest() }
                    }
                }
            }
            if isPassword, field.value.isEmpty {
                Button { suggest() } label: {
                    Label("Suggest a strong password", systemImage: "wand.and.stars")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(VT.blueSoft, in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(VT.blue)
            }
            if !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(matches, id: \.self) { m in
                        Button { field.value = m; focused = false } label: {
                            Text(m).font(.system(size: 13)).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(VT.blueSoft, in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(VT.blue)
                    }
                }
            }
            if isPassword, !field.value.isEmpty {
                let s = StrengthEstimator.evaluate(field.value)
                StrengthBar(level: s.level, score: s.score)
            }
        }
    }

    private func suggest() {
        field.value = PasswordGenerator.generate()
        shown.insert(field.id)
    }
}

/// Pick a symbol and a colour for an entry's tile.
private struct LookPicker: View {
    let name: String
    let kind: ItemKind
    @Binding var symbol: String?
    @Binding var color: UInt32?
    @Environment(\.dismiss) private var dismiss

    private let colors: [UInt32] = [0x2F73F2, 0x7A68E8, 0x1FB16B, 0xF08A24, 0xE5566D, 0x14A3B8, 0x5B6475, 0x1D1D1F, 0xC47A0A, 0xD6409F]
    private let symbols = ["key.fill", "lock.fill", "envelope.fill", "creditcard.fill", "cart.fill", "house.fill", "briefcase.fill", "graduationcap.fill",
                           "gamecontroller.fill", "play.rectangle.fill", "music.note", "airplane", "car.fill", "heart.fill", "cross.case.fill", "banknote.fill",
                           "wifi", "phone.fill", "globe", "star.fill"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ServiceTile(name: name, kind: kind, symbol: symbol, color: color ?? 0x2F73F2, size: 72)
                    swatches
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(symbols, id: \.self) { s in
                            Button { symbol = s; if color == nil { color = 0x2F73F2 } } label: {
                                Image(systemName: s).font(.system(size: 20)).frame(maxWidth: .infinity, minHeight: 46)
                                    .background(symbol == s ? VT.blueSoft : VT.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(symbol == s ? VT.blue : VT.line))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("Use the first letter instead") { symbol = nil }.buttonStyle(.plain).foregroundStyle(VT.blue)
                }
                .padding(18)
            }
            .background(VT.detailBackground)
            .navigationTitle("Symbol and colour")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 420, height: 520)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private var swatches: some View {
        HStack(spacing: 10) {
            ForEach(colors, id: \.self) { c in
                Button { color = c } label: {
                    Circle().fill(Color(hex: c)).frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(.white, lineWidth: color == c ? 3 : 0))
                        .overlay(Circle().strokeBorder(color == c ? VT.blue : .clear, lineWidth: 1.5).padding(-3))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
