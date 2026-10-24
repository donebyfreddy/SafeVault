# SafeVault for Chrome

Fills the username and password of your SafeVault logins in Chrome. **Read-only**: it never writes to your vault.
It downloads the same encrypted `vault.db` the apps sync through Dropbox and decrypts it locally with your master
password (WebCrypto: PBKDF2-SHA256 600k, AES-256-GCM, the exact format of `VaultFile.swift` / `Crypto.swift`).

## Install

1. Chrome → `chrome://extensions` → turn on **Developer mode** → **Load unpacked** → choose this `Extension/` folder.
   The extension ID is fixed (`jlagpokkoapmkdmbcgomdfaejmafhicp`, from the `key` in `manifest.json`).
2. In the [Dropbox App Console](https://www.dropbox.com/developers/apps), open the app SafeVault already uses and add this
   **redirect URI**: `https://jlagpokkoapmkdmbcgomdfaejmafhicp.chromiumapp.org/`
3. Click the SafeVault toolbar icon, type the same Dropbox **app key** you typed in the app, and press *Connect Dropbox*.
4. Enter your master password. Open a login page, click the icon and choose the login.

Only Dropbox is supported for now (iCloud Drive and Google Drive are not).

## How it behaves

- **Match by domain**: the page host must equal the saved website or be a subdomain of it (`www.` ignored; a port saved
  in the item must match). Look-alikes such as `evil-example.com` never match. Archived items and non-logins are skipped.
- **https only** (plus `localhost` for development). Plain `http` pages are never filled.
- **Fill on click only**: nothing runs on pages until you pick a login (no content scripts, no auto-submit).
  Fields are found in the top frame; values are set with the usual `input`/`change` events so React/Vue forms notice.
- **Lock**: the vault key is kept only in `chrome.storage.session` (memory, cleared when Chrome closes, not readable by
  content scripts) and wiped after 5 minutes without use or with the *Lock* button. Decrypted items are never stored.
- **Offline**: the last downloaded (still encrypted) `vault.db` is cached in `chrome.storage.local`.
- **Stored in `chrome.storage.local`**: the Dropbox app key and tokens, and that encrypted copy. *Disconnect Dropbox* removes them.

### Permissions

| Permission | Why |
|---|---|
| `activeTab`, `scripting` | fill the tab you clicked from, once, with no access to other sites |
| `storage` | session key, Dropbox tokens, encrypted cache |
| `alarms` | inactivity lock |
| `identity` | Dropbox sign-in window (OAuth 2 PKCE, no client secret) |
| hosts `api.dropboxapi.com`, `content.dropboxapi.com` | download `vault.db` |

## Tests

```bash
npm test                      # in Extension/: node --test, no dependencies (Node 20+)
```

The tests decrypt `test/fixtures/vault.db`, written by the Swift app code. To regenerate it (the fixture and its
password are test data only):

```bash
cd Packages/MyVaultKit && SAFEVAULT_FIXTURE_DIR=../../Extension/test/fixtures swift test --filter ExtensionFixtureTests
```

## Layout

`src/crypto.js` format + decryption · `src/vault.js` item lookup and domain matching · `src/dropbox.js` OAuth/download ·
`src/fill.js` page filler · `src/session.js` key and lock · `src/popup.js` UI · `src/background.js` lock alarm.
