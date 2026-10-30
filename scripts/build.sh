#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build
APP="build/Xiaomi Sensor.app"
EXT="$APP/Contents/PlugIns/XiaomiWidget.appex"
mkdir -p "$APP/Contents/MacOS" "$EXT/Contents/MacOS"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -target "$arch-apple-macos14.0" -sdk "$SDK" Sources/XiaomiSensor.swift -o "build/XiaomiSensor-$arch"
  xcrun swiftc -O -parse-as-library -application-extension -target "$arch-apple-macos14.0" -sdk "$SDK" Sources/XiaomiWidget.swift -o "build/XiaomiWidget-$arch"
done
xcrun lipo -create build/XiaomiSensor-arm64 build/XiaomiSensor-x86_64 -output "$APP/Contents/MacOS/XiaomiSensor"
xcrun lipo -create build/XiaomiWidget-arm64 build/XiaomiWidget-x86_64 -output "$EXT/Contents/MacOS/XiaomiWidget"
cp Info.plist "$APP/Contents/Info.plist"
cp Widget-Info.plist "$EXT/Contents/Info.plist"
codesign --force --sign - --entitlements Widget.entitlements "$EXT"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Xiaomi Sensor" -srcfolder build/dmg -ov -format UDZO "build/Xiaomi-Sensor.dmg"
hdiutil imageinfo "build/Xiaomi-Sensor.dmg"
