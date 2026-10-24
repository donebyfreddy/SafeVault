#if os(macOS)
import AppKit
import SwiftUI

/// A dismissible card that explains how to install the Chrome extension. Hidden for good once dismissed.
/// Chrome does not allow installing an unpacked extension from outside, so the card walks through the steps
/// and gives one-click shortcuts for each.
struct ExtensionPrompt: View {
    static let dismissedKey = "chromeExtensionPromptDismissed"
    static let instructionsURL = URL(string: "https://github.com/donebyfreddy/SafeVault/tree/main/Extension#install")!
    static let redirectURI = "https://jlagpokkoapmkdmbcgomdfaejmafhicp.chromiumapp.org/"

    @AppStorage(dismissedKey) private var dismissed = false
    @State private var copied = false

    /// The real home folder (the app is sandboxed, so NSHomeDirectory() is its container).
    private var extensionFolder: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("MyVault/Extension", isDirectory: true)
    }

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 20)).foregroundStyle(VT.blue)
                        .frame(width: 32, height: 32).background(VT.blueSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fill passwords in Chrome").font(.system(size: 13, weight: .semibold)).foregroundStyle(VT.ink)
                        Text("Sign in to websites with your vault. Chrome can't install it automatically, so it takes four steps:")
                            .font(.system(size: 12)).foregroundStyle(VT.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Button { dismissed = true } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(VT.ink3).accessibilityLabel("Dismiss")
                }
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Open Chrome's extensions page and turn on Developer mode.") {
                        Button("Open") { openChromeExtensions() }
                    }
                    step(2, "Choose Load unpacked and pick the Extension folder.") {
                        Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([extensionFolder]) }
                    }
                    step(3, "In your Dropbox app (App Console), add this Redirect URI.") {
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.redirectURI, forType: .string)
                            copied = true
                        }
                    }
                    step(4, "Click the SafeVault icon in Chrome, enter your Dropbox app key and master password.") { EmptyView() }
                }
                HStack(spacing: 10) {
                    Link("Full instructions", destination: Self.instructionsURL)
                    Spacer()
                    Button("Don't show again") { dismissed = true }.foregroundStyle(VT.ink3)
                }
                .buttonStyle(.borderless).font(.system(size: 12))
            }
            .padding(14)
            .frame(width: 370)
            .background(VT.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(VT.line))
            .shadow(color: Color(hex: 0x16203F, opacity: 0.12), radius: 12, y: 4)
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func step<A: View>(_ n: Int, _ text: String, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(VT.blue)
                .frame(width: 18, height: 18).background(VT.blueSoft, in: Circle())
            Text(text).font(.system(size: 12)).foregroundStyle(VT.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            action().buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func openChromeExtensions() {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        guard FileManager.default.fileExists(atPath: chrome.path) else { return }
        NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }
}
#endif
