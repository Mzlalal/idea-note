#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
target="${1:-}"
case "${target:-$(uname -m)}" in
  arm64|aarch64-apple-darwin) arch=aarch64 ;;
  x86_64|x86_64-apple-darwin) arch=x64 ;;
  *) echo "Unsupported macOS architecture" >&2; exit 1 ;;
esac

bundle="$PWD/src-tauri/target"
if [[ -n "$target" ]]; then
  npm run tauri build -- --bundles app --target "$target"
  bundle="$bundle/$target"
else
  npm run tauri build -- --bundles app
fi
bundle="$bundle/release/bundle"
app="$bundle/macos/Lite Note.app"
plist="$app/Contents/Info.plist"
identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
requirement="identifier \"$identifier\""

codesign --force --sign - --identifier "$identifier" \
  --requirements "=designated => $requirement" "$app"
codesign --verify --deep --strict -R "=$requirement" "$app"
codesign -d -r- "$app"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Lite Note.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$bundle/dmg"
dmg="$bundle/dmg/Lite Note_${version}_${arch}.dmg"
hdiutil create -ov -volname 'Lite Note' -srcfolder "$stage" -format UDZO "$dmg"
hdiutil verify "$dmg"
