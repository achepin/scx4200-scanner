#!/bin/zsh

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly APP_NAME="SCX4200Scanner"
readonly APP_BUNDLE="$PROJECT_ROOT/dist/$APP_NAME.app"
readonly EXECUTABLE="$PROJECT_ROOT/.build/release/$APP_NAME"

pkill -x "$APP_NAME" 2>/dev/null || true
swift build --package-path "$PROJECT_ROOT" -c release

mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

plutil -create xml1 "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleName -string "Сканировать SCX-4200" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || plutil -insert CFBundleName -string "Сканировать SCX-4200" "$APP_BUNDLE/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string "Сканировать SCX-4200" "$APP_BUNDLE/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "com.aleksej.scx4200-scanner" "$APP_BUNDLE/Contents/Info.plist"
plutil -insert CFBundleExecutable -string "$APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
plutil -insert CFBundlePackageType -string "APPL" "$APP_BUNDLE/Contents/Info.plist"
plutil -insert CFBundleVersion -string "1.0" "$APP_BUNDLE/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "1.0" "$APP_BUNDLE/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string "14.0" "$APP_BUNDLE/Contents/Info.plist"
plutil -insert NSPrincipalClass -string "NSApplication" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"

open -n "$APP_BUNDLE"

if [[ "${1:-}" == "--verify" ]]; then
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    print "$APP_NAME is running"
fi
