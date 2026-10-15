#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TASK_SOURCE="$TASK_ROOT/build/MCC Forge Publisher.app"
TASK_DEST="$HOME/Applications/MCC Forge Publisher.app"
codesign --verify --deep --strict "$TASK_SOURCE"
if [ -d "$TASK_DEST" ]; then
    TASK_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TASK_DEST/Contents/Info.plist")
    if [ "$TASK_IDENTIFIER" != org.mjolnir.MCCForgePublisher ]; then
        echo 'A different application already uses this name. It was not replaced.' >&2
        exit 1
    fi
fi
mkdir -p "$HOME/Applications"
# Copy the signed build unchanged: both copies then share one code signature, so macOS
# treats them as the same app for the saved sign-in.
TASK_STAGE=$(mktemp -d "$HOME/Applications/.mcc-forge-publisher.XXXXXX")
trap 'rm -rf -- "$TASK_STAGE"' EXIT
ditto --norsrc --noextattr --noacl "$TASK_SOURCE" "$TASK_STAGE/MCC Forge Publisher.app"
xattr -cr "$TASK_STAGE/MCC Forge Publisher.app"
codesign --verify --deep --strict "$TASK_STAGE/MCC Forge Publisher.app"
rm -rf "$TASK_DEST"
mv "$TASK_STAGE/MCC Forge Publisher.app" "$TASK_DEST"
echo "$TASK_DEST"
