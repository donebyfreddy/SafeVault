import AuthenticationServices
import MyVaultKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Generator

struct GeneratorView: View {
    @Environment(AppModel.self) private var model
    @State private var options = GeneratorOptions()
    @State private var password = PasswordGenerator.generate()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VaultCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(password)
                            .font(.system(size: 22, weight: .medium, design: .monospaced))
                            .foregroundStyle(VT.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        let s = StrengthEstimator.evaluate(password)
                        StrengthBar(level: s.level, score: s.score)
                        HStack(spacing: 10) {
                            Button { model.copy(password, label: "Password") } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(SoftButtonStyle(prominent: true))
                            Button { regenerate() } label: { Label("Generate another", systemImage: "arrow.clockwise") }
                                .buttonStyle(SoftButtonStyle())
                        }
                    }
                }

                VaultCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Length").font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text("\(options.length)").monospacedDigit().foregroundStyle(VT.ink2)
                        }
                        Slider(value: Binding(get: { Double(options.length) }, set: { options.length = Int($0); regenerate() }), in: 8...64, step: 1)
                        Divider().overlay(VT.line)
                        toggle("Lowercase letters", \.lowercase)
                        toggle("Uppercase letters", \.uppercase)
                        toggle("Numbers", \.digits)
                        toggle("Symbols", \.symbols)
                        toggle("Avoid look-alike characters (O, 0, l, 1)", \.avoidAmbiguous)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 56)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(VT.detailBackground)
        .navigationTitle("Generator")
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<GeneratorOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { options[keyPath: keyPath] }, set: { options[keyPath: keyPath] = $0; regenerate() }))
            .font(.system(size: 14))
            .tint(VT.green)
    }

    private func regenerate() { password = PasswordGenerator.generate(options) }
}

// MARK: - Security Center

struct SecurityCenterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let report = model.report
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                #if os(macOS)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Security Center").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                    Text("Checked on this device. Nothing leaves it.").font(.system(size: 13)).foregroundStyle(VT.ink3)
                }
                #endif

                VaultCard(padding: 20) {
                    HStack(spacing: 22) {
                        ScoreRing(score: report.score)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(headline(report)).font(.system(size: 17, weight: .bold))
                            Text(report.issueCount == 0
                                 ? "Your passwords are strong, unique and protected."
                                 : "\(report.issueCount) item\(report.issueCount == 1 ? "" : "s") could be stronger. Nothing has left this device unencrypted.")
                                .font(.system(size: 13.5)).foregroundStyle(VT.ink2).lineSpacing(2)
                        }
                    }
                }

                HStack(spacing: 12) {
                    StatCard(icon: "exclamationmark.triangle", tint: VT.red, soft: Color(hex: 0xFDEBEA), value: report.weak.count, label: "Weak passwords")
                    StatCard(icon: "arrow.2.squarepath", tint: Color(hex: 0xC98307), soft: Color(hex: 0xFDF1DA), value: report.reused.count, label: "Reused passwords")
                    StatCard(icon: "shield", tint: VT.violet, soft: VT.violetSoft, value: report.withoutTwoFactor.count, label: "No two-factor")
                }

                issueSection("Weak passwords", ids: report.weak, hint: "Replace them with generated ones.")
                issueSection("Reused passwords", ids: report.reused, hint: "Each account should have its own password.")
                issueSection("Two-factor not set up", ids: report.withoutTwoFactor, hint: "Add a one-time password or backup codes.")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 56)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(VT.detailBackground)
        .navigationTitle("Security")
    }

    private func headline(_ r: SecurityReport) -> String {
        r.score >= 90 ? "Your vault is in great shape" : r.score >= 70 ? "Your vault is in good shape" : "Your vault needs attention"
    }

    @ViewBuilder private func issueSection(_ title: String, ids: [UUID], hint: String) -> some View {
        let items = ids.compactMap { id in model.items.first { $0.id == id } }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(hint).font(.system(size: 12.5)).foregroundStyle(VT.ink3)
                }
                .padding(.horizontal, 4)
                VaultCard {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().overlay(VT.line).padding(.leading, 62) }
                            Button {
                                model.nav = .all
                                model.selectedID = item.id
                                #if os(iOS)
                                model.openItemRequest = item.id
                                #endif
                            } label: {
                                HStack(spacing: 12) {
                                    ServiceTile(name: item.name, kind: item.kind, size: 34)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(VT.ink)
                                        Text(item.subtitle).font(.system(size: 12)).foregroundStyle(VT.ink3)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0xB5BDCB))
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 54)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct ScoreRing: View {
    let score: Int

    var body: some View {
        ZStack {
            Circle().stroke(VT.fill, lineWidth: 11)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(score >= 70 ? VT.green : score >= 40 ? VT.amber : VT.red, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(score)").font(.system(size: 34, weight: .bold)).tracking(-1)
                Text("of 100").font(.system(size: 12)).foregroundStyle(VT.ink3)
            }
        }
        .frame(width: 124, height: 124)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Security score \(score) out of 100")
    }
}

private struct StatCard: View {
    let icon: String
    let tint: Color
    let soft: Color
    let value: Int
    let label: String

    var body: some View {
        VaultCard(padding: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 30, height: 30).background(soft, in: Circle())
                Text("\(value)").font(.system(size: 28, weight: .bold)).tracking(-0.8).padding(.top, 8)
                Text(label).font(.system(size: 12.5)).foregroundStyle(VT.ink2).lineLimit(2, reservesSpace: true)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var importing = false
    @State private var exportDoc: BackupDocument?
    @State private var changingPassword = false
    @State private var confirmDisconnect = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Security") {
                Toggle(isOn: Binding(
                    get: { model.biometricEnabled },
                    set: { on in
                        if on { Task { await model.enableBiometrics() } } else { model.disableBiometrics() }
                    })
                ) {
                    Label("Unlock with \(model.biometryName)", systemImage: model.biometryName == "Touch ID" ? "touchid" : "faceid")
                }
                .tint(VT.green)
                .disabled(!model.biometryAvailable)
                if !model.biometryAvailable {
                    Text("\(model.biometryName) is not available on this device. You can always unlock with your master password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(selection: $model.autoLockSeconds) {
                    Text("Immediately").tag(0)
                    Text("After 1 minute").tag(60)
                    Text("After 5 minutes").tag(300)
                    Text("After 15 minutes").tag(900)
                } label: {
                    Label("Auto-lock", systemImage: "lock.rotation")
                }
                Picker(selection: $model.clipboardSeconds) {
                    Text("Never").tag(0)
                    Text("After 15 seconds").tag(15)
                    Text("After 30 seconds").tag(30)
                    Text("After 2 minutes").tag(120)
                } label: {
                    Label("Clear clipboard", systemImage: "doc.on.clipboard")
                }
                Button { changingPassword = true } label: { Label("Change master password…", systemImage: "key") }
            }

            Section {
                if model.dropboxLinked {
                    LabeledContent {
                        StatusPill(text: "Connected")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dropbox")
                            if let email = model.dropboxEmail { Text(email).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    LabeledContent("Last sync") {
                        Text(syncText)
                    }
                    Button { Task { await model.syncNow() } } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(model.syncStatus == .syncing)
                    Button(role: .destructive) { confirmDisconnect = true } label: { Label("Disconnect Dropbox…", systemImage: "link.badge.plus") }
                } else {
                    Button {
                        Task { await model.connectDropbox { url, scheme in try await webAuth.authenticate(using: url, callbackURLScheme: scheme) } }
                    } label: { Label("Connect Dropbox", systemImage: "link") }
                    if !model.dropboxConfigured { DropboxSetupCard() }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Only encrypted data is stored in your Dropbox, inside the app folder you created. Dropbox can never read it.")
            }

            Section("Data") {
                Button { importing = true } label: { Label("Import from Safe…", systemImage: "square.and.arrow.down") }
                Button {
                    Task {
                        if let data = await model.makeBackup() { exportDoc = BackupDocument(data: data) }
                    }
                } label: { Label("Export encrypted backup…", systemImage: "square.and.arrow.up") }
                LabeledContent("Items") { Text("\(model.items.count)").monospacedDigit() }
            }

            Section {
                Button(role: .destructive) { model.lock() } label: { Label("Lock now", systemImage: "lock") }
            } footer: {
                Text("SafeVault 1.0 · Encrypted with AES-256-GCM. Your master password never leaves this device.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(VT.detailBackground)
        .safeAreaPadding(.bottom, 24)
        .navigationTitle("Settings")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.xml, .commaSeparatedText, .plainText, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.prepareImport(from: url) }
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }), document: exportDoc, contentType: .myVaultBackup, defaultFilename: "SafeVault backup \(Date().formatted(.iso8601.year().month().day()))") { _ in
            exportDoc = nil
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
        .confirmationDialog("Disconnect Dropbox?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await model.disconnectDropbox() } }
        } message: {
            Text("Your data stays on this device and in Dropbox. It just stops syncing.")
        }
    }

    private var syncText: String {
        switch model.syncStatus {
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .failed(let m): return m
        default: return model.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Never"
        }
    }
}

extension UTType {
    static let myVaultBackup = UTType(exportedAs: "com.myvault.backup", conformingTo: .json)
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.myVaultBackup, .json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var old = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Current master password", text: $old)
                    SecureField("New master password", text: $new)
                    SecureField("Repeat new master password", text: $confirm)
                } footer: {
                    if let error { Text(error).foregroundStyle(VT.red) }
                    else { Text("Your items are not re-encrypted. Other devices ask for the new password after they sync.") }
                }
                if !new.isEmpty {
                    let s = StrengthEstimator.evaluate(new)
                    Section { StrengthBar(level: s.level, score: s.score) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Change Master Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") {
                        guard new == confirm else { error = "The new passwords do not match."; return }
                        Task {
                            if await model.changeMasterPassword(old: old, new: new) { dismiss() }
                            else { error = "The current password is not correct." }
                        }
                    }
                    .disabled(old.isEmpty || new.count < 8 || model.busy)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 380)
        #endif
    }
}

// MARK: - Dropbox app key setup

/// Guides through creating the Dropbox app once, and takes its key. After that, "Connect Dropbox" opens the
/// browser for the normal Dropbox login (OAuth 2 with PKCE).
struct DropboxSetupCard: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""

    private var redirect: String { "db-\(key.trimmingCharacters(in: .whitespaces))://2/token" }

    var body: some View {
        VaultCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label("One-time Dropbox setup", systemImage: "link.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Open the Dropbox App Console and press **Create app**: *Scoped access*, then **App folder**, any name.")
                    step(2, "Permissions tab: tick `files.metadata.read`, `files.content.read` and `files.content.write`, then **Submit**.")
                    step(3, "Settings tab: copy the **App key** and paste it below. Then add the redirect URI shown below under *Redirect URIs*.")
                }
                Link(destination: URL(string: "https://www.dropbox.com/developers/apps/create")!) {
                    Label("Open Dropbox App Console", systemImage: "arrow.up.forward.square")
                        .font(.system(size: 13, weight: .medium))
                }
                TextField("App key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if key.trimmingCharacters(in: .whitespaces).count >= 8 {
                    HStack(spacing: 8) {
                        Text(redirect)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(VT.ink2)
                            .textSelection(.enabled).lineLimit(2)
                        Spacer(minLength: 0)
                        IconButton(system: "doc.on.doc", label: "Copy redirect URI") {
                            Clipboard.copy(redirect, clearAfter: 0)
                            model.showToast("Redirect URI copied")
                        }
                    }
                    .padding(10)
                    .background(VT.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Button("Save key") { model.saveDropboxAppKey(key) }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(key.trimmingCharacters(in: .whitespaces).count < 8)
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(VT.blue, in: Circle())
            Text(text).font(.system(size: 12.5)).foregroundStyle(VT.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Safe database password

struct SafeDatabasePasswordSheet: View {
    let pending: PendingDatabase
    @Environment(AppModel.self) private var model
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(pending.url.lastPathComponent, systemImage: "externaldrive")
                    SecureField("Safe master password", text: $password)
                        .onSubmit(go)
                } footer: {
                    if let error = model.databaseError {
                        Text(error).foregroundStyle(VT.red)
                    } else {
                        Text("This is Safe's own encrypted database. The password is only used now to read it, then forgotten. The original file is never changed or deleted.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Open Safe database")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.pendingDatabase = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: go).disabled(password.isEmpty || model.busy)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 300)
        #endif
    }

    private func go() {
        guard !password.isEmpty, !model.busy else { return }
        Task { _ = await model.openSafeDatabase(password: password) }
    }
}

// MARK: - Import preview

struct ImportPreviewSheet: View {
    let preview: ImportPreview
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VaultCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(preview.fileName, systemImage: "doc.text").font(.system(size: 14, weight: .semibold))
                            Text("Detected: \(preview.result.format)").font(.caption).foregroundStyle(VT.ink3)
                            Divider().overlay(VT.line)
                            ForEach(ItemKind.allCases, id: \.self) { kind in
                                let n = preview.unique.filter { $0.kind == kind }.count
                                if n > 0 {
                                    HStack {
                                        Text(kind.title)
                                        Spacer()
                                        Text("\(n)").monospacedDigit().foregroundStyle(VT.ink2)
                                    }
                                    .font(.system(size: 14))
                                }
                            }
                            Divider().overlay(VT.line)
                            HStack {
                                Text("Will be added").fontWeight(.semibold)
                                Spacer()
                                Text("\(preview.unique.count)").monospacedDigit().fontWeight(.semibold)
                            }
                            .font(.system(size: 14))
                            if preview.duplicates > 0 {
                                Text("\(preview.duplicates) already in your vault, skipped.").font(.caption).foregroundStyle(VT.ink3)
                            }
                            if preview.result.skipped > 0 {
                                Text("\(preview.result.skipped) deleted entries or templates, skipped.").font(.caption).foregroundStyle(VT.ink3)
                            }
                        }
                    }

                    if !preview.result.warnings.isEmpty {
                        VaultCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Worth a look", systemImage: "exclamationmark.triangle").foregroundStyle(VT.amber).font(.system(size: 14, weight: .semibold))
                                ForEach(Array(Set(preview.result.warnings)).sorted().prefix(6), id: \.self) { w in
                                    Text(w).font(.system(size: 12.5)).foregroundStyle(VT.ink2)
                                }
                            }
                        }
                    }

                    Label("The file you are importing is not encrypted. After importing, delete it.", systemImage: "info.circle")
                        .font(.system(size: 12.5)).foregroundStyle(VT.ink2)
                }
                .padding(20)
            }
            .background(VT.detailBackground)
            .navigationTitle("Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.importPreview = nil; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(preview.unique.count) items") { Task { await model.confirmImport() } }
                        .disabled(preview.unique.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
    }
}
