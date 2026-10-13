#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
stage=$(mktemp -d "${TMPDIR:-/tmp}/sharp-receiver-package.XXXXXX")
mount="$stage/mount"
cleanup() {
    if mount | grep -Fq " on $mount "; then hdiutil detach -quiet "$mount" || true; fi
    rm -rf "$stage"
}
trap cleanup EXIT
mkdir -p "$stage/files/.background"
ditto 'build/Sharp Receiver.app' "$stage/files/Sharp Receiver.app"
ln -s /Applications "$stage/files/Applications"
swift ../scripts/dmg-background.swift "$stage/files/.background/background.png"
hdiutil create -quiet -fs HFS+ -volname 'Sharp Receiver' -srcfolder "$stage/files" -format UDRW "$stage/writable.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$mount" "$stage/writable.dmg"
osascript - "$mount" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        set installer to POSIX file mountPath as alias
        open installer
        set w to container window of installer
        set current view of w to icon view
        set toolbar visible of w to false
        set statusbar visible of w to false
        set bounds of w to {100, 100, 820, 540}
        set options to icon view options of w
        set arrangement of options to not arranged
        set icon size of options to 112
        set background picture of options to (POSIX file (mountPath & "/.background/background.png") as alias)
        set position of item "Sharp Receiver.app" of installer to {185, 212}
        set position of item "Applications" of installer to {535, 212}
        close w
        update installer without registering applications
    end tell
end run
APPLESCRIPT
sync
hdiutil detach -quiet "$mount"
hdiutil convert "$stage/writable.dmg" -quiet -format UDZO -ov -o build/Sharp-Receiver-High-Sierra.dmg
hdiutil verify -quiet build/Sharp-Receiver-High-Sierra.dmg
shasum -a 256 build/Sharp-Receiver-High-Sierra.dmg > build/Sharp-Receiver-High-Sierra.dmg.sha256
