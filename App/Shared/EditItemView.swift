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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $item.name)
                    Picker("Vault", selection: $item.vault) {
                        ForEach(model.vaultNames, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Favorite", isOn: $item.favorite)
                }

                Section {
                    HStack(spacing: 14) {
                        ServiceTile(name: item.name, kind: item.kind, icon: item.icon, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.iconCustom == true ? "Your own image" : item.icon != nil ? "From the website" : "Automatic")
                                .font(.system(size: 14, weight: .medium))
                            Text(item.icon == nil ? "The logo appears by itself when the entry has a website." : "Shown in lists and in the entry.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    #if os(iOS)
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose your own image…", systemImage: "photo") }
                    #else
                    Button { choosingImage = true } label: { Label("Choose your own image…", systemImage: "photo") }
                    #endif
                    if item.iconCustom == true {
                        Button { item.icon = nil; item.iconCustom = nil; item.iconCheckedAt = nil } label: {
                            Label("Use the website's logo instead", systemImage: "globe")
                        }
                    }
                    if item.icon != nil {
                        Button(role: .destructive) { item.icon = nil; item.iconCustom = false; item.iconCheckedAt = Date() } label: {
                            Label("Remove logo", systemImage: "trash")
                        }
                    }
                    if let logoProblem { Text(logoProblem).font(.caption).foregroundStyle(VT.red) }
                } header: {
                    Text("Logo")
                }
                .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
                    guard case .success(let url) = result else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    useImage(try? Data(contentsOf: url))
                }
                #if os(iOS)
                .onChange(of: photo) { _, picked in
                    Task { useImage(try? await picked?.loadTransferable(type: Data.self)) }
                }
                #endif

                Section("Details") {
                    ForEach($item.fields) { $field in
                        FieldEditor(field: $field, shown: $shown) {
                            item.fields.removeAll { $0.id == field.id }
                        }
                    }
                    Menu {
                        Button("Text") { addField(.text, "Field") }
                        Button("Password") { addField(.secret, "Password") }
                        Button("Website") { addField(.url, "Website") }
                        Button("Email") { addField(.email, "Email") }
                        Button("Phone") { addField(.phone, "Phone") }
                    } label: {
                        Label("Add field", systemImage: "plus.circle")
                    }
                }

                if item.kind == .login {
                    Section {
                        TextField("Secret key or otpauth:// link", text: $totpText)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    } header: {
                        Text("One-time password (2FA)")
                    } footer: {
                        if totpInvalid {
                            Text("That does not look like a valid secret key.").foregroundStyle(VT.red)
                        } else {
                            Text("Paste the setup key a website shows next to its QR code. The app then shows the 6-digit codes.")
                        }
                    }

                    Section {
                        TextEditor(text: $codesText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 70)
                    } header: {
                        Text("Backup codes")
                    } footer: {
                        Text("One code per line.")
                    }
                }

                Section("Notes") {
                    TextEditor(text: $item.notes).frame(minHeight: 80)
                }

                Section("Tags") {
                    TextField("Comma separated", text: $tagsText)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
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
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 540, minHeight: 640, idealHeight: 700)
        #endif
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
    var onDelete: () -> Void

    private var hidden: Bool { field.type == .secret && !shown.contains(field.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Label", text: $field.label)
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
                        SecureField("Value", text: $field.value)
                    } else {
                        TextField("Value", text: $field.value)
                            .font(.system(size: 14, design: field.type == .secret ? .monospaced : .default))
                    }
                }
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(field.type == .email ? .emailAddress : field.type == .url ? .URL : field.type == .phone ? .phonePad : .default)
                #endif

                if field.type == .secret {
                    IconButton(system: hidden ? "eye" : "eye.slash", label: "Show or hide") {
                        if hidden { shown.insert(field.id) } else { shown.remove(field.id) }
                    }
                    if field.label.caseInsensitiveCompare(ItemField.passwordLabel) == .orderedSame {
                        IconButton(system: "wand.and.stars", label: "Generate a strong password") {
                            field.value = PasswordGenerator.generate()
                            shown.insert(field.id)
                        }
                    }
                }
            }
            if field.type == .secret, field.label.caseInsensitiveCompare(ItemField.passwordLabel) == .orderedSame, !field.value.isEmpty {
                let s = StrengthEstimator.evaluate(field.value)
                StrengthBar(level: s.level, score: s.score)
            }
        }
        .padding(.vertical, 2)
    }
}
