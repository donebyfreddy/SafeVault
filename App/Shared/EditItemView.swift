import MyVaultKit
import SwiftUI

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
