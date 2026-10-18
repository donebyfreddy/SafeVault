import AuthenticationServices
import MyVaultKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            switch model.phase {
            case .launching:
                VT.background.overlay(ProgressView())
            case .setup:
                OnboardingView()
            case .locked:
                LockView()
            case .unlocked:
                MainView()
            }
            if model.phase == .unlocked && scenePhase != .active {
                PrivacyCover()
            }
        }
        .tint(VT.blue)
        .preferredColorScheme(.light)
        .overlay(alignment: .top) { ToastView() }
        .task { await model.bootstrap() }
        .onChange(of: scenePhase) { _, new in
            #if os(iOS)
            if new == .background { model.appLeft() }
            if new == .active { model.appReturned() }
            #endif
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.appLeft() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.appReturned() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.lock() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))) { _ in model.lock() }
        #endif
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { model.importPreview != nil }, set: { if !$0 { model.importPreview = nil } })) {
            if let preview = model.importPreview { ImportPreviewSheet(preview: preview) }
        }
        .sheet(isPresented: Binding(get: { model.pendingDatabase != nil }, set: { if !$0 { model.pendingDatabase = nil } })) {
            if let pending = model.pendingDatabase { SafeDatabasePasswordSheet(pending: pending) }
        }
        .alert(
            "Delete the imported file?",
            isPresented: Binding(get: { model.importedFile != nil }, set: { if !$0 { model.importedFile = nil } })
        ) {
            Button("Delete File", role: .destructive) { model.deleteImportedFile() }
            Button("Keep", role: .cancel) { model.importedFile = nil }
        } message: {
            Text("\"\(model.importedFile?.lastPathComponent ?? "")\" has all your passwords in plain text. It is safest to delete it now.")
        }
    }
}

struct MainView: View {
    var body: some View {
        #if os(macOS)
        MacMainView()
        #else
        PhoneMainView()
        #endif
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            VT.background
            AppMark(size: 84)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.toast {
            Label(text, systemImage: "checkmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(hex: 0x1C2230), in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: model.toast)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Lock

struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            VT.background.ignoresSafeArea()
            RadialGradient(colors: [VT.blueSoft, .clear], center: .center, startRadius: 0, endRadius: 280)
                .ignoresSafeArea().opacity(0.8)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                AppMark(size: 84)
                Text("SafeVault").font(.system(size: 28, weight: .bold)).tracking(-0.6).padding(.top, 18)
                Text("Your vault is locked").font(.system(size: 14)).foregroundStyle(VT.ink2).padding(.top, 4)

                if model.biometricUnlockOffered {
                    Button {
                        Task { await model.unlockWithBiometrics() }
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: model.biometryName == "Touch ID" ? "touchid" : "faceid")
                                .font(.system(size: 52, weight: .light))
                                .foregroundStyle(VT.blue)
                                .frame(width: 112, height: 112)
                                .background(VT.surface, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(VT.line))
                                .shadow(color: VT.blue.opacity(0.18), radius: 18, y: 10)
                            Text("Unlock with \(model.biometryName)").font(.system(size: 16, weight: .semibold)).foregroundStyle(VT.ink)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 34)
                    .accessibilityLabel("Unlock with \(model.biometryName)")
                }

                VStack(spacing: 12) {
                    SecureField("Master password", text: $password)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(VT.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? VT.blue : VT.line, lineWidth: focused ? 1.5 : 1))
                        .focused($focused)
                        .onSubmit(submit)
                        .submitLabel(.go)
                    Button(action: submit) {
                        Group {
                            if model.busy { ProgressView().controlSize(.small).tint(.white) } else { Text("Unlock") }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                    .disabled(password.isEmpty || model.busy)
                    if let error = model.unlockError {
                        Text(error).font(.system(size: 12.5)).foregroundStyle(VT.red).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 320)
                .padding(.top, model.biometricUnlockOffered ? 26 : 34)

                Spacer(minLength: 0)
                Label("End-to-end encrypted", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 11.5)).foregroundStyle(VT.ink3)
                    .labelStyle(TintedIconLabelStyle(tint: VT.green))
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .task {
            guard !model.demoMode, model.biometricUnlockOffered else { focused = true; return }
            await model.unlockWithBiometrics()
        }
    }

    private func submit() {
        guard !password.isEmpty, !model.busy else { return }
        Task {
            if await model.unlock(password: password) { password = "" }
        }
    }
}

struct TintedIconLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    enum Step { case welcome, create, join }

    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var step = Step.welcome
    @State private var password = ""
    @State private var confirm = ""
    @State private var understood = false
    @State private var useBiometrics = true
    @State private var restoring = false

    var body: some View {
        ZStack {
            VT.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    switch step {
                    case .welcome: welcome
                    case .create: create
                    case .join: join
                    }
                }
                .frame(maxWidth: 400)
                .padding(.horizontal, 24)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json, .myVaultBackup, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { _ = await model.restoreBackup(from: url) } }
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            AppMark(size: 92)
            Text("SafeVault").font(.system(size: 32, weight: .bold)).tracking(-0.8).padding(.top, 6)
            Text("Your passwords, encrypted on your own devices and synced through your own Dropbox.")
                .font(.system(size: 15)).foregroundStyle(VT.ink2).multilineTextAlignment(.center).lineSpacing(2)
            VStack(spacing: 10) {
                Button { step = .create } label: { Text("Create a new vault").frame(maxWidth: .infinity) }
                    .buttonStyle(SoftButtonStyle(prominent: true))
                Button { step = .join } label: { Text("I already have a vault in Dropbox").frame(maxWidth: .infinity) }
                    .buttonStyle(SoftButtonStyle())
                Button { restoring = true } label: { Text("Restore from a backup file").frame(maxWidth: .infinity) }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(.top, 20)
            VStack(alignment: .leading, spacing: 10) {
                bullet("lock.fill", "Zero-knowledge: only encrypted data ever leaves your device.")
                bullet("arrow.triangle.2.circlepath", "Free and unlimited on Mac and iPhone.")
                bullet("square.and.arrow.down", "Bring your passwords over from Safe in a few clicks.")
            }
            .padding(.top, 18)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(VT.blue).frame(width: 20)
            Text(text).font(.system(size: 13)).foregroundStyle(VT.ink2)
        }
    }

    private var strength: PasswordStrength { StrengthEstimator.evaluate(password) }
    private var canCreate: Bool {
        password.count >= 8 && password == confirm && understood && !model.busy
    }

    private var create: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { step = .welcome } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(VT.blue)
            Text("Choose a master password").font(.system(size: 26, weight: .bold)).tracking(-0.5)
            Text("It protects everything. Use a long phrase you can remember, like four random words.")
                .font(.system(size: 14)).foregroundStyle(VT.ink2)
            VStack(spacing: 10) {
                field("Master password", text: $password)
                field("Repeat master password", text: $confirm)
            }
            if !password.isEmpty {
                StrengthBar(level: strength.level, score: strength.score)
                if password.count < 8 { hint("Use at least 8 characters.") }
                else if strength.level == .weak { hint("This one is easy to guess. You can still use it, but a longer phrase is safer.") }
                else if !confirm.isEmpty && confirm != password { hint("The passwords do not match.") }
            }
            VaultCard(padding: 14) {
                Toggle(isOn: $understood) {
                    Text("I understand that if I forget this password, nobody can recover my data, not even the app.")
                        .font(.system(size: 13)).foregroundStyle(VT.ink)
                }
                .toggleStyle(CheckboxToggleStyle())
            }
            if model.biometryAvailable {
                Toggle(isOn: $useBiometrics) {
                    Label("Unlock with \(model.biometryName)", systemImage: model.biometryName == "Touch ID" ? "touchid" : "faceid")
                        .font(.system(size: 14))
                }
                .tint(VT.green)
            }
            Button {
                Task {
                    if await model.createVault(password: password), useBiometrics, model.biometryAvailable {
                        await model.enableBiometrics()
                    }
                }
            } label: {
                Group {
                    if model.busy { ProgressView().controlSize(.small).tint(.white) } else { Text("Create vault") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
            .disabled(!canCreate)
            .opacity(canCreate ? 1 : 0.5)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(VT.ink3)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(VT.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(VT.line))
    }

    private var join: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { step = .welcome } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(VT.blue)
            Text("Connect your Dropbox").font(.system(size: 26, weight: .bold)).tracking(-0.5)
            Text("Sign in to the Dropbox where your other device keeps SafeVault. You will then unlock it with your master password.")
                .font(.system(size: 14)).foregroundStyle(VT.ink2)
            Button {
                Task {
                    if !model.dropboxLinked {
                        await model.connectDropbox { url, scheme in try await webAuth.authenticate(using: url, callbackURLScheme: scheme) }
                    }
                    if model.dropboxLinked { _ = await model.fetchVaultFromDropbox() }
                }
            } label: {
                Group {
                    if model.busy { ProgressView().controlSize(.small).tint(.white) } else { Label("Connect Dropbox", systemImage: "link") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SoftButtonStyle(prominent: true))
            .disabled(model.busy)
            if !model.dropboxConfigured { DropboxSetupCard() }
        }
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18)).foregroundStyle(configuration.isOn ? VT.blue : VT.ink3)
                configuration.label.multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - App

@main
struct MyVaultApp: App {
    @State private var model: AppModel = {
        #if DEBUG
        return DemoLaunch.makeModel()
        #else
        return AppModel()
        #endif
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                #if os(macOS)
                .frame(minWidth: 980, minHeight: 620)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Login") { model.newItemRequest = .login }.keyboardShortcut("n")
                Button("New Secure Note") { model.newItemRequest = .note }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Find Items") { model.focusSearchTick += 1 }.keyboardShortcut("k")
            }
            CommandMenu("Vault") {
                Button("Lock Vault") { model.lock() }.keyboardShortcut("l")
                Button("Sync Now") { Task { await model.syncNow() } }.keyboardShortcut("r")
            }
        }
        #endif
    }
}
