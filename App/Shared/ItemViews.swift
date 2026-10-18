import MyVaultKit
import SwiftUI

// MARK: - List row

struct ItemRow: View {
    let item: VaultItem
    var selected = false
    var onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ServiceTile(name: item.name, kind: item.kind, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name.isEmpty ? "Untitled" : item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VT.ink)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Color(hex: 0x7B8AA6) : VT.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onToggleFavorite) {
                Image(systemName: item.favorite ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(item.favorite ? VT.star : Color(hex: 0xBCC4D2))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.favorite ? "Remove \(item.name) from favorites" : "Add \(item.name) to favorites")
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background(selected ? VT.blueSoft : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Detail

struct ItemDetailView: View {
    let item: VaultItem
    /// On the Mac the header carries Edit and the menu; on iPhone they live in the navigation bar.
    var showsHeaderActions = true

    @Environment(AppModel.self) private var model
    @State private var revealed = Set<UUID>()
    @State private var editing: VaultItem?
    @State private var showHistory = false
    @State private var showCodes = false

    private var compact: Bool { !showsHeaderActions }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                fieldsCard
                if let secret = item.totpSecret { TOTPCard(secret: secret, itemID: item.id) }
                extrasCard
                notesCard
                meta
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.top, compact ? 16 : 24)
            .padding(.bottom, compact ? 56 : 24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(VT.detailBackground)
        .onChange(of: item.id) { revealed = [] }
        .sheet(item: $editing) { EditItemView(item: $0, isNew: false) }
        .sheet(isPresented: $showHistory) { HistorySheet(item: item) }
        .sheet(isPresented: $showCodes) { BackupCodesSheet(item: item) }
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Edit") { editing = item }
                ItemMenu(item: item)
            }
            #endif
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ServiceTile(name: item.name, kind: item.kind, size: compact ? 56 : 64)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: compact ? 22 : 26, weight: .bold))
                        .tracking(-0.5)
                        .lineLimit(2)
                    Button { model.toggleFavorite(item.id) } label: {
                        Image(systemName: item.favorite ? "star.fill" : "star")
                            .font(.system(size: 18))
                            .foregroundStyle(item.favorite ? VT.star : Color(hex: 0xBCC4D2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.favorite ? "Remove from favorites" : "Add to favorites")
                }
                HStack(spacing: 8) {
                    Pill(text: item.vault)
                    Pill(text: item.kind.title, foreground: VT.ink2, background: Color(hex: 0xEAEDF4))
                    if item.archived { Pill(text: "Archived", foreground: VT.amber, background: Color(hex: 0xFDF1DA)) }
                }
            }
            Spacer(minLength: 0)
            if showsHeaderActions {
                HStack(spacing: 8) {
                    Button("Edit") { editing = item }.buttonStyle(SoftButtonStyle())
                    ItemMenu(item: item)
                }
            }
        }
    }

    private var fieldsCard: some View {
        VaultCard {
            VStack(spacing: 0) {
                ForEach(Array(item.fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { Divider().overlay(VT.line) }
                    FieldRow(item: item, field: field, revealed: $revealed)
                }
                if item.fields.isEmpty {
                    Text("No fields").foregroundStyle(VT.ink3).padding(18)
                }
            }
        }
    }

    private var extrasCard: some View {
        VaultCard {
            VStack(spacing: 0) {
                if item.kind == .login {
                    ExtraRow(icon: "checkmark.shield", tint: VT.green, title: "Two-Factor Authentication") {
                        StatusPill(text: item.totpSecret != nil ? "Enabled" : "Not set up", good: item.totpSecret != nil)
                    }
                    Divider().overlay(VT.line)
                    ExtraRow(icon: "lifepreserver", tint: VT.violet, title: "Backup Codes", chevron: true, action: { showCodes = true }) {
                        Text(item.backupCodes.isEmpty ? "None saved" : "\(item.backupCodes.count) codes saved")
                    }
                    Divider().overlay(VT.line)
                }
                ExtraRow(icon: "clock.arrow.circlepath", tint: VT.violet, title: item.kind == .login ? "Password History" : "History", chevron: true, action: { showHistory = true }) {
                    Text(historySummary)
                }
            }
        }
    }

    private var historySummary: String {
        let n = item.passwordHistory.count
        let v = item.history.count
        if n == 0, v == 0 { return "No changes yet" }
        var parts = [String]()
        if n > 0 { parts.append("\(n) previous password\(n == 1 ? "" : "s")") }
        if v > 0 { parts.append("\(v) older version\(v == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var notesCard: some View {
        VaultCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Secure Notes").font(.system(size: 14, weight: .semibold))
                } icon: {
                    Image(systemName: "note.text").foregroundStyle(VT.violet)
                }
                Text(item.notes.isEmpty ? "No notes." : item.notes)
                    .font(.system(size: 13.5))
                    .foregroundStyle(item.notes.isEmpty ? VT.ink3 : VT.ink2)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.leading, 28)
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 4) {
            metaRow("Created", item.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
            metaRow("Modified", item.modifiedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
            metaRow("Last Used", item.lastUsedAt.map { $0.formatted(.relative(presentation: .named)).capitalizedFirst } ?? "Never")
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(VT.ink3).frame(width: 88, alignment: .leading)
            Text(value).foregroundStyle(VT.ink2).monospacedDigit()
        }
        .font(.system(size: 13))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct ExtraRow<Trailing: View>: View {
    let icon: String
    var tint: Color = VT.ink2
    let title: String
    var chevron = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint).frame(width: 22)
            Text(title).font(.system(size: 14)).foregroundStyle(VT.ink)
            Spacer(minLength: 8)
            trailing.font(.system(size: 13.5)).foregroundStyle(VT.ink3)
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0xB5BDCB))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

struct FieldRow: View {
    let item: VaultItem
    let field: ItemField
    @Binding var revealed: Set<UUID>
    @Environment(AppModel.self) private var model

    private var isRevealed: Bool { revealed.contains(field.id) }
    private var showsStrength: Bool {
        field.type == .secret && field.label.caseInsensitiveCompare(ItemField.passwordLabel) == .orderedSame && !field.value.isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(field.label)
                .font(.system(size: 13.5))
                .foregroundStyle(VT.ink2)
                .frame(width: 92, alignment: .leading)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 9) {
                value
                if showsStrength {
                    let s = StrengthEstimator.evaluate(field.value)
                    StrengthBar(level: s.level, score: s.score)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if field.type == .secret {
                    IconButton(system: isRevealed ? "eye.slash" : "eye", label: isRevealed ? "Hide \(field.label)" : "Show \(field.label)") {
                        if isRevealed { revealed.remove(field.id) } else { revealed.insert(field.id) }
                    }
                }
                if field.type == .url, let url = Self.url(from: field.value) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 15))
                            .foregroundStyle(VT.ink3).frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Open website")
                } else {
                    IconButton(system: "doc.on.doc", label: "Copy \(field.label)") {
                        model.copy(field.value, label: field.label, itemID: item.id)
                    }
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    @ViewBuilder private var value: some View {
        if field.type == .url, let url = Self.url(from: field.value) {
            Link(field.value, destination: url)
                .font(.system(size: 14)).foregroundStyle(VT.blue).lineLimit(1)
        } else if field.type == .secret && !isRevealed {
            Text("•••••••••••••").font(.system(size: 15)).tracking(1.8).foregroundStyle(VT.ink)
        } else {
            Text(field.value.isEmpty ? "—" : field.value)
                .font(.system(size: 14, design: field.type == .secret ? .monospaced : .default))
                .foregroundStyle(VT.ink)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    static func url(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }
}

struct IconButton: View {
    let system: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15))
                .foregroundStyle(VT.ink3)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct TOTPCard: View {
    let secret: String
    let itemID: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        VaultCard {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = TOTP.code(secret: secret, at: context.date) ?? "------"
                let remaining = TOTP.secondsRemaining(at: context.date)
                HStack(spacing: 12) {
                    Text("One-Time Password")
                        .font(.system(size: 13.5)).foregroundStyle(VT.ink2)
                        .frame(width: 92, alignment: .leading).lineLimit(2)
                    Text(code.prefix(3) + " " + code.suffix(3))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(remaining <= 5 ? VT.red : VT.ink)
                        .contentTransition(.numericText())
                    Spacer()
                    ZStack {
                        Circle().stroke(VT.fill, lineWidth: 3)
                        Circle().trim(from: 0, to: CGFloat(remaining) / 30)
                            .stroke(remaining <= 5 ? VT.red : VT.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(remaining)").font(.system(size: 10, weight: .semibold)).foregroundStyle(VT.ink2).monospacedDigit()
                    }
                    .frame(width: 26, height: 26)
                    IconButton(system: "doc.on.doc", label: "Copy one-time password") {
                        model.copy(code, label: "Code", itemID: itemID)
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .frame(minHeight: 56)
            }
        }
    }
}

struct ItemMenu: View {
    let item: VaultItem
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        Menu {
            Button(item.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "star") { model.toggleFavorite(item.id) }
            Button(item.archived ? "Restore from Archive" : "Archive", systemImage: "archivebox") { model.setArchived(item.id, !item.archived) }
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            #if os(macOS)
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 20)
            #else
            Image(systemName: "ellipsis.circle")
            #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 38, height: 34)
        .background(VT.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(VT.line))
        #endif
        .accessibilityLabel("More options")
        .confirmationDialog("Delete \"\(item.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete(item.id) }
        } message: {
            Text("This also removes it from your other devices after the next sync.")
        }
    }
}

// MARK: - Sheets

struct HistorySheet: View {
    let item: VaultItem
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var shown = Set<Date>()

    var body: some View {
        NavigationStack {
            List {
                if !item.passwordHistory.isEmpty {
                    Section("Previous passwords") {
                        ForEach(item.passwordHistory, id: \.changedAt) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shown.contains(entry.changedAt) ? entry.value : "•••••••••••")
                                        .font(.system(size: 14, design: .monospaced))
                                    Text("Replaced \(entry.changedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                IconButton(system: shown.contains(entry.changedAt) ? "eye.slash" : "eye", label: "Show") {
                                    if shown.contains(entry.changedAt) { shown.remove(entry.changedAt) } else { shown.insert(entry.changedAt) }
                                }
                                IconButton(system: "doc.on.doc", label: "Copy") { model.copy(entry.value, label: "Password") }
                            }
                        }
                    }
                }
                if !item.history.isEmpty {
                    Section("Older versions") {
                        ForEach(item.history, id: \.savedAt) { snap in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(snap.reason).font(.system(size: 13, weight: .medium))
                                Text("\(snap.name) · \(snap.fields.count) fields · \(snap.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Restore this version") {
                                    var restored = item
                                    restored.name = snap.name
                                    restored.fields = snap.fields
                                    restored.notes = snap.notes
                                    restored.appendHistory(item.snapshot(reason: "Before restoring an older version"))
                                    model.save(restored)
                                    dismiss()
                                }
                                .font(.caption)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if item.passwordHistory.isEmpty && item.history.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath", description: Text("Old passwords and replaced versions appear here."))
                }
            }
            .navigationTitle("History")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 460, height: 460)
        #endif
    }
}

struct BackupCodesSheet: View {
    let item: VaultItem
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if item.backupCodes.isEmpty {
                    ContentUnavailableView("No backup codes", systemImage: "lifepreserver", description: Text("Edit the item to paste the recovery codes this service gave you."))
                } else {
                    Section("Use each code once") {
                        ForEach(item.backupCodes, id: \.self) { code in
                            HStack {
                                Text(code).font(.system(size: 15, design: .monospaced))
                                Spacer()
                                IconButton(system: "doc.on.doc", label: "Copy code") { model.copy(code, label: "Code") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Backup Codes")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 400, height: 440)
        #endif
    }
}
