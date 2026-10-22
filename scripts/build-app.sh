#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$TASK_ROOT/scripts/signing.sh"
swift build --package-path "$TASK_ROOT" -c release -j 2 --product MCCForgePublisher
TASK_BIN=$(swift build --package-path "$TASK_ROOT" -c release --show-bin-path)
TASK_FINAL="$TASK_ROOT/build/MCC Forge Publisher.app"
mkdir -p "$TASK_ROOT/build"
# Assemble beside the old bundle and swap it in, so a running copy keeps its own files.
TASK_STAGE=$(mktemp -d "$TASK_ROOT/build/.staging.XXXXXX")
trap 'rm -rf -- "$TASK_STAGE"' EXIT
TASK_APP="$TASK_STAGE/MCC Forge Publisher.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN/MCCForgePublisher" "$TASK_APP/Contents/MacOS/MCCForgePublisher"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MCC Forge Publisher</string>
<key>CFBundleDisplayName</key><string>MCC Forge Publisher</string>
<key>CFBundleIdentifier</key><string>org.mjolnir.MCCForgePublisher</string>
<key>CFBundleExecutable</key><string>MCCForgePublisher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Halo Reach Forge Map</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>org.mjolnir.reach-map-variant</string></array>
</dict><dict>
<key>CFBundleTypeName</key><string>Halo Reach Gametype</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>org.mjolnir.reach-game-variant</string></array>
</dict></array>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>org.mjolnir.reach-map-variant</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
<key>UTTypeDescription</key><string>Halo Reach Forge Map</string>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mvar</string></array></dict>
</dict><dict>
<key>UTTypeIdentifier</key><string>org.mjolnir.reach-game-variant</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
<key>UTTypeDescription</key><string>Halo Reach Gametype</string>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>bin</string><string>game</string></array></dict>
</dict></array>
</dict></plist>
PLIST
xattr -cr "$TASK_APP"
mcc_sign_app "$TASK_APP"
rm -rf "$TASK_FINAL"
mv "$TASK_APP" "$TASK_FINAL"
echo "$TASK_FINAL"
