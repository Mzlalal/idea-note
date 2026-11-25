#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
case "$(uname -m)" in
  arm64) arch=aarch64 ;;
  x86_64) arch=x64 ;;
  *) echo "Unsupported macOS architecture" >&2; exit 1 ;;
esac

npm run tauri build -- --bundles app

bundle="$PWD/src-tauri/target/release/bundle"
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
