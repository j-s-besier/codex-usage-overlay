#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"

# Native architecture by default; ARCH=universal builds Apple Silicon + Intel.
architecture="${ARCH:-$(uname -m)}"
case "$architecture" in
    arm64|x86_64) build_args=(--arch "$architecture") ;;
    universal) build_args=(--arch arm64 --arch x86_64) ;;
    *) echo "ARCH must be arm64, x86_64, or universal" >&2; exit 1 ;;
esac

swift build -c release "${build_args[@]}"
bin_dir="$(swift build -c release "${build_args[@]}" --show-bin-path)"
output_dir="$project_dir/dist"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_name="Codex Usage Menu Bar.app"
app_path="$staging_dir/$app_name"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/CodexUsageOverlay" "$app_path/Contents/MacOS/"
cp install-companion.sh uninstall-companion.sh watch-codex.sh "$app_path/Contents/Resources/"
chmod 755 "$app_path/Contents/MacOS/CodexUsageOverlay" "$app_path/Contents/Resources/"*.sh
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Codex Usage Menu Bar</string>
    <key>CFBundleDisplayName</key><string>Codex Usage Menu Bar</string>
    <key>CFBundleIdentifier</key><string>local.codex-usage-menu-bar</string>
    <key>CFBundleExecutable</key><string>CodexUsageOverlay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
# Explicit ad-hoc signing never selects a personal or company keychain identity.
/usr/bin/codesign --force --sign - "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
zip_name="CodexUsageMenuBar-$architecture.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staging_dir/$zip_name"
rm -rf "$output_dir/$app_name"
mv "$app_path" "$output_dir/$app_name"
mv -f "$staging_dir/$zip_name" "$output_dir/$zip_name"
echo "App: $output_dir/$app_name"
echo "ZIP: $output_dir/$zip_name"
echo "Ad-hoc signed; not Developer ID signed or notarized."
