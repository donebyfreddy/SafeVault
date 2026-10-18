#!/bin/bash
# Builds SafeVault (Mac DMG + unsigned iPhone IPA) into dist/ and leaves NO stray copies behind:
#  - the intermediate build folders and loose .app files are deleted,
#  - mounted SafeVault / My Vault disk images are ejected,
#  - installed copies in /Applications and old files in ~/Downloads are moved to the Trash (recoverable),
# so that searching "SafeVault" finds only the fresh dist/SafeVault.dmg until you install it yourself.
# Your data is not touched: it lives in the app's container, not inside the app.
#
#   tools/release.sh                  build + clean everything
#   tools/release.sh --keep-installed build + clean, but leave /Applications alone
set -euo pipefail
cd "$(dirname "$0")/.."

UNINSTALL=1
[[ "${1:-}" == "--keep-installed" ]] && UNINSTALL=0

trash() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  local dest="$HOME/.Trash/$(basename "$f")"
  [[ -e "$dest" ]] && dest="$dest $(date +%H%M%S)"
  mv "$f" "$dest" && echo "  Trash: $f"
}

echo "1/5 Tests"
(cd Packages/MyVaultKit && swift test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with" | tail -1)

echo "2/5 Build"
xcodegen generate >/dev/null
rm -rf dist && mkdir -p dist
xcodebuild -project MyVault.xcodeproj -scheme MyVault-macOS -configuration Release -destination 'platform=macOS' \
  -derivedDataPath dist/build build 2>&1 | grep -E "error:|BUILD"
xcodebuild -project MyVault.xcodeproj -scheme MyVault-iOS -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath dist/ios-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build 2>&1 | grep -E "error:|BUILD"

echo "3/5 Package"
mkdir dist/stage && cp -R dist/build/Build/Products/Release/SafeVault.app dist/stage/ && ln -s /Applications dist/stage/Applications
hdiutil create -volname "SafeVault" -srcfolder dist/stage -ov -format UDZO dist/SafeVault.dmg >/dev/null
mkdir -p dist/ipa/Payload && cp -R dist/ios-build/Build/Products/Release-iphoneos/SafeVault.app dist/ipa/Payload/
(cd dist/ipa && zip -qry ../SafeVault.ipa Payload)
xattr -cr dist/SafeVault.dmg dist/SafeVault.ipa
hdiutil verify dist/SafeVault.dmg | tail -1

echo "4/5 Remove build leftovers"
rm -rf dist/build dist/ios-build dist/stage dist/ipa

echo "5/5 Remove old copies"
for v in "SafeVault" "My Vault"; do
  [[ -d "/Volumes/$v" ]] && hdiutil detach "/Volumes/$v" -quiet && echo "  Ejected: /Volumes/$v" || true
done
if [[ $UNINSTALL == 1 ]]; then
  trash "/Applications/SafeVault.app"
  trash "/Applications/My Vault.app"
fi
for f in "$HOME"/Downloads/SafeVault*.dmg "$HOME"/Downloads/SafeVault*.ipa "$HOME"/Downloads/My\ Vault*.dmg "$HOME"/Downloads/My\ Vault*.ipa; do
  trash "$f"
done

echo
echo "Done. Install from here (not from a downloaded copy, which macOS blocks):"
ls -la dist
