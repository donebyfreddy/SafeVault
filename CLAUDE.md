# SafeVault: instructions for Claude

Native SwiftUI password manager (Mac + iPhone). Project owner: Federico. Read `README.md` for the architecture.

## Giving Federico a new build (always do this, without being asked)

Use `tools/release.sh`. It runs the tests, builds the Mac DMG and the unsigned iPhone IPA into `dist/`, and **removes every stray copy**
so that searching "SafeVault" shows nothing but the fresh `dist/SafeVault.dmg`:

- no loose `.app` files, no `dist/build`, no DerivedData left over from my own builds;
- ejects mounted `SafeVault` / `My Vault` disk images;
- moves the old installed apps in `/Applications` and old downloads in `~/Downloads` to the Trash (recoverable).
  Federico asked for this explicitly. His data lives in the app container, not in the app, so it is not touched.

Rules that follow from this:

- Never leave builds in `/Applications`, on the Desktop or in scratch folders that Spotlight indexes. Build into `dist/` and let the script clean up.
- If I build for my own testing elsewhere (DerivedData in a scratch folder, simulator installs), delete it when done.
- Tell Federico to install from `~/MyVault/dist/SafeVault.dmg` **on his Mac**, not from a copy downloaded from the chat: a downloaded copy gets the
  quarantine flag and macOS shows "Apple could not verify...". The file in `dist/` has no such flag.
- Send the files with SendUserFile only when he asks for them (they are for the iPhone or another Mac). Sent copies that he downloads are what cause duplicates.

## Signing

- The Mac app is ad-hoc signed on purpose (never expires; no Touch ID). A Developer ID certificate plus notarization (paid Apple Developer
  Program) is the only way to remove the Gatekeeper warning for downloaded copies.
- Do not sign with the `Apple Development` identity found on this Mac (it belongs to another account).
  Ask first.

## Other conventions

- App name is **SafeVault**. Bundle id `com.federicomencuccini.myvault` stays as is (changing it would orphan existing app data).
- The Dropbox app key is typed into the app (stored in settings); never put the Dropbox app secret anywhere. The login uses OAuth 2 with PKCE.
- Never capture the whole screen when checking the Mac app: capture only the SafeVault window (`screencapture -l <windowid>`), because the screen has private content.
- Core tests: `cd Packages/MyVaultKit && swift test`. Debug builds accept `--demo` for fictional data.
