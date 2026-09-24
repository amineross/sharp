on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        tell disk "Sharp"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {100, 100, 820, 540}
            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set background picture of viewOptions to (POSIX file (mountPath & "/.background/background.png") as alias)
            set position of item "Sharp.app" of container window to {185, 212}
            set position of item "Applications" of container window to {535, 212}
            close
            open
            update without registering applications
        end tell
    end tell
end run
