#if os(macOS)
import SwiftUI

/// A dismissible card inviting the user to install the Chrome extension. Hidden for good once dismissed.
struct ExtensionPrompt: View {
    static let dismissedKey = "chromeExtensionPromptDismissed"
    static let instructionsURL = URL(string: "https://github.com/donebyfreddy/SafeVault/tree/main/Extension#install")!

    @AppStorage(dismissedKey) private var dismissed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 20)).foregroundStyle(VT.blue)
                    .frame(width: 32, height: 32).background(VT.blueSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fill passwords in Chrome").font(.system(size: 13, weight: .semibold)).foregroundStyle(VT.ink)
                    Text("Install the SafeVault extension to sign in to websites with your vault.")
                        .font(.system(size: 12)).foregroundStyle(VT.ink2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("How to install") { openURL(Self.instructionsURL) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Don't show again") { dismissed = true }
                            .buttonStyle(.borderless).controlSize(.small).foregroundStyle(VT.ink3)
                    }
                }
                Button { dismissed = true } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(VT.ink3).accessibilityLabel("Dismiss")
            }
            .padding(12)
            .frame(width: 330)
            .background(VT.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(VT.line))
            .shadow(color: Color(hex: 0x16203F, opacity: 0.12), radius: 12, y: 4)
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
#endif
