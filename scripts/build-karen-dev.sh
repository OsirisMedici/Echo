#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_root="$repo_root/app"
voice_target="${KAREN_CARGO_TARGET_DIR:-$repo_root/karen-voice/target}"
release_app="/Applications/SpeakEasy.app"
dev_app="$app_root/Echo.app"
if [[ -f "$dev_app/Contents/MacOS/SpeakEasy" ]] && /usr/sbin/lsof -t "$dev_app/Contents/MacOS/SpeakEasy" >/dev/null 2>&1; then
    echo "Quit Echo before replacing its development bundle." >&2
    exit 1
fi
[[ -d "$release_app" ]] || { echo "Install the verified SpeakEasy 0.3.0 release first." >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$release_app/Contents/Info.plist")
[[ "$version" == "0.3.0" ]] || { echo "Expected SpeakEasy 0.3.0 resources; found $version." >&2; exit 1; }
codesign --verify --deep --strict "$release_app"
(cd "$app_root" && swift build)
cargo build --release --locked --offline --manifest-path "$repo_root/karen-voice/Cargo.toml" --target-dir "$voice_target"
# Recreating this exact disposable development bundle never touches /Applications.
[[ ! -d "$dev_app" ]] || mv "$dev_app" "$app_root/.build/karen-dev-backup-$(date +%s).app"
ditto "$release_app" "$dev_app"
cp "$app_root/.build/debug/SpeakEasy" "$dev_app/Contents/MacOS/SpeakEasy"
cp "$voice_target/release/karen-voice" "$dev_app/Contents/Helpers/karen-voice"
for resources in "$app_root"/.build/debug/*.bundle; do
    [[ -d "$resources" ]] && ditto "$resources" "$dev_app/Contents/Resources/$(basename "$resources")"
done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$dev_app/Contents/MacOS/SpeakEasy" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.osirismedici.speakeasy-karen-dev' "$dev_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Echo' "$dev_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Echo' "$dev_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.3.0-echo.1' "$dev_app/Contents/Info.plist"
codesign --force --sign - "$dev_app/Contents/Helpers/karen-voice"
codesign --force --sign - --entitlements "$app_root/SpeakEasy.entitlements" "$dev_app"
codesign --verify --deep --strict "$dev_app"
echo "Development app: $dev_app"
echo "The installed release, its settings, and its player socket are unchanged."
