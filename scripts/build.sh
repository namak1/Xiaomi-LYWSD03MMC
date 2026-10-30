#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build
APP="build/Xiaomi Sensor.app"
mkdir -p "$APP/Contents/MacOS"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -target "$arch-apple-macos12.0" -sdk "$SDK" Sources/XiaomiSensor.swift -o "build/XiaomiSensor-$arch"
done
xcrun lipo -create build/XiaomiSensor-arm64 build/XiaomiSensor-x86_64 -output "$APP/Contents/MacOS/XiaomiSensor"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Xiaomi Sensor" -srcfolder build/dmg -ov -format UDZO "build/Xiaomi-Sensor.dmg"
hdiutil imageinfo "build/Xiaomi-Sensor.dmg"
