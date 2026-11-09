#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
    printf 'Usage: %s [release|debug]\n' "$0" >&2
    exit 2
fi
build_options=(-c "$configuration")
if [[ "$configuration" == release ]]; then
    build_options+=(-debug-info-format none)
fi
Packaging/swift-local.sh build "${build_options[@]}" >&2
binary_path="$(Packaging/swift-local.sh build "${build_options[@]}" --show-bin-path)"

mkdir -p dist
stage="$(mktemp -d "$PWD/dist/.stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/DesktopWallpaper.app"
resources="$app/Contents/Resources"
saver="$resources/WallpaperSaver.saver"
mkdir -p "$app/Contents/MacOS" "$saver/Contents/MacOS"
cp "$binary_path/DesktopWallpaper" "$app/Contents/MacOS/DesktopWallpaper"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp Packaging/Demo.html "$resources/Demo.html"
cp Packaging/SaverInfo.plist "$saver/Contents/Info.plist"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/.build/local/clang" \
    -mmacosx-version-min=14.0 -bundle Packaging/WallpaperSaver.m \
    -framework ScreenSaver -framework AppKit -framework AVFoundation -framework WebKit -framework QuartzCore -framework ImageIO \
    -o "$saver/Contents/MacOS/WallpaperSaver"
/usr/bin/codesign --force --sign - "$saver"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
output="$PWD/dist/DesktopWallpaper.app"
rm -rf "$output"
mv "$app" "$output"
printf '%s\n' "$output"
