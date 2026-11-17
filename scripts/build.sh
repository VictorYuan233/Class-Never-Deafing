#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Class Never Deafing.app"
plist=Sources/Info.plist
guide=Sources/Resources/使用指南.html
notes=Sources/Resources/ReleaseNotes.plist
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
notes_version=$(/usr/libexec/PlistBuddy -c 'Print :version' "$notes")
if [[ "$app_version" != "$notes_version" ]] ||
    ! grep -Fq "<meta name=\"app-version\" content=\"$app_version\">" "$guide" ||
    ! grep -Fq "适用于 $app_version ·" "$guide" ||
    ! /usr/libexec/PlistBuddy -c 'Print :highlights:0' "$notes" >/dev/null; then
    printf '%s\n' '请同步更新使用指南、详情中的本版说明以及 App 版本。' >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/build/ModuleCache"
cp "$plist" "$app/Contents/Info.plist"
cp "$guide" "$notes" "$app/Contents/Resources/"
xcrun swiftc -swift-version 5 -O -parse-as-library \
    -target arm64-apple-macosx14.0 -module-cache-path "$PWD/build/ModuleCache" \
    Sources/ClassroomCaptions/*.swift -o "$app/Contents/MacOS/ClassroomCaptions"
codesign --force --sign - --identifier com.classneverdeafing.captions "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
