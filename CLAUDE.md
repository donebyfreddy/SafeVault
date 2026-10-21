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
- The `Apple Development` identity on this Mac is Federico's own individual developer account (certificate holder: Federico Mencuccini, team
  `LNLXN9P8QU`), under his work email. It is fine to use it to put the app on his own iPhone:
  `xcodebuild -project MyVault.xcodeproj -scheme MyVault-iOS -configuration Release -destination 'id=<UDID>' -allowProvisioningUpdates DEVELOPMENT_TEAM=LNLXN9P8QU -derivedDataPath <scratch> build`,
  then `xcrun devicectl device install app --device <UDID> <scratch>/Build/Products/Release-iphoneos/SafeVault.app`. **Always Release**: Debug builds are several times slower on the phone. Delete the build folder afterwards.
- Development-signed apps stop opening after 7 days on a free account; reinstalling the same way renews it. The iPhone must be unlocked, paired
  (`devicectl manage pair`) and have Developer Mode on (only he can turn it on, in Settings).

## Sync design (do not regress)

- The cloud holds ONE file, `vault.db` (header + one sealed blob with all items). Never go back to one file per item.
- Items are compared with `canonicalBytes` and history with `mergedHistory` (millisecond tolerance), because dates that went through a
  file differ in the last bit. Comparing `Date`s or items with `==` in sync code caused phantom conflicts and endless uploads.
- A `vault.db` that cannot be read is never overwritten. Old per-item files are deleted only after vault.db is confirmed to hold everything.
- Run the suite several times after touching sync: `for i in 1 2 3 4 5; do swift test; done` (timing-dependent bugs hide in one run).

## Other conventions

- App name is **SafeVault**. Bundle id `com.federicomencuccini.myvault` stays as is (changing it would orphan existing app data).
- The Dropbox app key is typed into the app (stored in settings); never put the Dropbox app secret anywhere. The login uses OAuth 2 with PKCE.
- Never capture the whole screen when checking the Mac app: capture only the SafeVault window (`screencapture -l <windowid>`), because the screen has private content.
- Core tests: `cd Packages/MyVaultKit && swift test`. Debug builds accept `--demo` for fictional data.
