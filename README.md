<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="SafeVault icon" />

# SafeVault

**A private, zero-knowledge password manager for Mac and iPhone.** 🔐
Native SwiftUI · encrypted on your devices · synced through *your own* Dropbox · free, no limits.

![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white)
![Tests](https://img.shields.io/badge/core%20tests-63%20passing-1FB16B)
![Encryption](https://img.shields.io/badge/AES--256--GCM-zero--knowledge-2F73F2)

</div>

---

## ✨ Why

Most password managers want a subscription for the one thing that matters: using your passwords on **both** your Mac and your phone.
SafeVault does that for free. Your vault is encrypted on the device, and the only thing that ever reaches Dropbox is ciphertext. No accounts, no servers, no telemetry. 🚫📡

## 📸 A look

<div align="center">
<img src="docs/images/mac-main.png" width="49%" alt="SafeVault on macOS: item detail with a live one-time code" />
<img src="docs/images/mac-security.png" width="49%" alt="SafeVault Security Center" />
</div>

<sub>Fictional demo data.</sub>

## 🧰 Features

- 🔑 **Logins, cards, secure notes, identities and Wi-Fi**, with favorites, vaults (Personal / Work), tags and an archive
- 🔢 **Built-in 2FA codes** (TOTP, RFC 6238) with a live countdown, plus backup codes
- 🕘 **Password history** and **version history**: nothing you overwrite is lost
- 🛡️ **Security Center**: weak, reused and no-two-factor checks, computed on the device
- 🪄 **Password generator** with length and character options
- 😀 **Face ID** on iPhone and **Touch ID** on Mac (with the master password always as a fallback)
- ☁️ **Dropbox sync**, offline-first, with safe conflict handling
- 📥 **Import from Safe (SafeInCloud)**: straight from its `.db` file, or from an XML / CSV export
- 💾 **Encrypted backups** you can export and restore
- ⏱️ **Auto-lock**, hidden in the app switcher, clipboard cleared after 30 seconds

## 🔒 How it protects your data

| | |
|---|---|
| 🧂 **Key derivation** | Master password → PBKDF2-HMAC-SHA256 (600,000 rounds, random salt) |
| 🗝️ **Vault key** | A random 256-bit key, wrapped by the master password (changing the password never re-encrypts your items) |
| 🧱 **Encryption** | One AES-256-GCM record per item, bound to its id so records cannot be swapped |
| ☁️ **In Dropbox** | `header.json` and one `<uuid>.vitem` per item. Opaque names, nothing readable |
| 😀 **Biometrics** | Face ID / Touch ID guard a copy of the vault key in the Keychain (invalidated if biometrics change). The master password is asked again every 7 days |
| 🚨 **Recovery** | **There is none, on purpose.** Forget the master password and nobody can read your data. Export an encrypted backup |

## 🔄 Sync, and what happens on a conflict

Edit the same item on two devices while offline? **The most recent edit wins and the other version is kept in that item's history. Nothing is silently discarded.**
Deletions travel as scrubbed tombstones, a file removed from Dropbox by hand is uploaded again, and a record that fails to decrypt is reported and left untouched.
Sync runs after each change, when the app returns to the foreground, and every minute while open.

> ⚠️ Dropbox refuses new files when the account is over its quota. If sync shows `path/insufficient_space`, free space (or use a free second Dropbox account for the vault).

## 📥 Coming from Safe (SafeInCloud)?

In SafeVault go to **Settings → Import from Safe…** and pick either:

- 🗄️ **`SafeInCloud.db`** straight from your Dropbox folder (usually `Dropbox/Apps/Safe In Cloud/`). You type your Safe master password once, it is used to read the file and then forgotten. The original is never changed or deleted
- 📄 an **XML** (preferred) or **CSV** export. That file is *not encrypted*, so the app offers to delete it afterwards

You always get a preview before anything is imported. Duplicates are skipped and anything that does not map cleanly is kept as a plain field, with a warning.
Generic `name,url,username,password` CSVs from other managers work too.

## 🚀 Run it

```bash
git clone https://github.com/donebyfreddy/SafeVault.git
cd SafeVault
open MyVault.xcodeproj        # schemes: MyVault-macOS and MyVault-iOS
```

The Xcode project is generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`, then `xcodegen generate`).

### 📱 On your iPhone, for free

You only need a free Apple ID. The catch: apps signed with a free account **stop opening after 7 days** and need to be installed again (your data stays as long as you do not delete the app).

1. iPhone: *Settings → Privacy & Security → Developer Mode → On* (it restarts). Connect it with a cable and tap **Trust**.
2. Xcode: *Settings → Accounts → +* and sign in with your Apple ID.
3. Select the **MyVault-iOS** target → *Signing & Capabilities* → Team: your name (*Personal Team*).
4. Pick your iPhone as destination and press **Run**. The first time, trust the developer in *Settings → General → VPN & Device Management*.

If Xcode says the bundle identifier is taken, change `com.federicomencuccini.myvault` in `project.yml` to something unique and run `xcodegen generate`.

### 💻 On your Mac

Press **Run** with the **MyVault-macOS** scheme, or build a release DMG with `tools/release.sh`.
The app is ad-hoc signed and not notarized (that needs the paid Apple Developer Program), so macOS may show *"Apple could not verify…"* the first time for a downloaded copy. Click **OK**, then *System Settings → Privacy & Security → Open Anyway*, or run once:

```bash
xattr -dr com.apple.quarantine "/Applications/SafeVault.app"
```

Touch ID on the Mac needs a team-signed build (add the *Keychain Sharing* capability in Xcode). Without it the app still works with the master password.

### ☁️ Connect Dropbox (one time)

SafeVault logs in with **OAuth 2 + PKCE in your browser**. The app never sees your Dropbox password, and no client secret is used. You create a tiny Dropbox app of your own:

1. Open the [Dropbox App Console](https://www.dropbox.com/developers/apps/create) → **Create app** → *Scoped access* → **App folder** → any name.
2. *Permissions*: tick `files.metadata.read`, `files.content.read`, `files.content.write` → **Submit**.
3. *Settings*: leave *Allow public clients (PKCE)* on **Allow**. Copy the **App key** (never the App secret) and paste it into SafeVault (the *One-time Dropbox setup* box).
4. SafeVault then shows a redirect URI like `db-<APP_KEY>://2/token`. Add it under **Redirect URIs** in the console.
5. Press **Connect Dropbox**. On your second device choose *I already have a vault in Dropbox*.

## 🧱 Project layout

```
Packages/MyVaultKit    🧠 crypto, vault storage, sync engine, Dropbox client, importers, TOTP (63 unit tests)
App/Shared             🎨 SwiftUI shared by Mac and iPhone (theme, models, item views, settings, security)
App/macOS              🖥️ three-column Mac layout
App/iOS                📱 iPhone home and custom tab bar
tools/                 🛠️ release.sh (build + package + clean up), make-icon.sh (app icon, optionally from your photo)
project.yml            ⚙️ XcodeGen project definition
```

## 🧪 Tests

```bash
cd Packages/MyVaultKit && swift test
```

Covers crypto (known vectors, tampering, wrong password), TOTP (RFC 6238 vectors), vault storage, two simulated devices syncing through a fake Dropbox (offline, conflicts, deletions, damaged files), the Dropbox client with stubbed HTTP, and the Safe importers.
Debug builds accept the launch argument `--demo` to run with fictional data.

## 🗺️ Limits and what is next

- ✍️ **No autofill into Safari and other apps yet.** It needs an AutoFill credential provider extension, the natural next step
- 🧩 The Safe `.db` reader follows the documented file layout and is tested with files generated to that layout, **not yet with a large range of real Safe databases**. If a file is rejected, export XML from Safe instead and please open an issue with the error
- ☁️ Dropbox sync is verified against a simulated Dropbox and stubbed HTTP, not at scale against live accounts
- 🌙 Light mode only. No sharing, iPad, Apple Watch or attachments yet

## 🙏 Credits and notes

- Not affiliated with Safe / SafeInCloud, Dropbox or Apple. Product names belong to their owners
- The Safe database layout was learned from the open-source decrypter [evilsocket/SafeInCloud](https://github.com/evilsocket/SafeInCloud) (GPLv3). The code here is an independent implementation
- No license has been chosen yet, so by default all rights are reserved. Add one if you want others to reuse the code

<div align="center">

Made with ☕ and a lot of `swift test`.

</div>
