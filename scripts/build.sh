#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build
APP="build/Xiaomi Sensor.app"
EXT="$APP/Contents/PlugIns/XiaomiWidget.appex"
mkdir -p "$APP/Contents/MacOS" "$EXT/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -target "$arch-apple-macos14.0" -sdk "$SDK" Sources/XiaomiSensor.swift -o "build/XiaomiSensor-$arch"
  xcrun swiftc -O -parse-as-library -target "$arch-apple-macos14.0" -sdk "$SDK" Sources/CollectorLauncher.swift -o "build/XiaomiCollectorLauncher-$arch"
  xcrun swiftc -O -parse-as-library -application-extension -target "$arch-apple-macos14.0" -sdk "$SDK" Sources/XiaomiWidget.swift -Xlinker -e -Xlinker _NSExtensionMain -o "build/XiaomiWidget-$arch"
done
xcrun lipo -create build/XiaomiSensor-arm64 build/XiaomiSensor-x86_64 -output "$APP/Contents/MacOS/XiaomiSensor"
xcrun lipo -create build/XiaomiWidget-arm64 build/XiaomiWidget-x86_64 -output "$EXT/Contents/MacOS/XiaomiWidget"
nm -u "$APP/Contents/PlugIns/XiaomiWidget.appex/Contents/MacOS/XiaomiWidget" | grep -q _NSExtensionMain
xcrun lipo -create build/XiaomiCollectorLauncher-arm64 build/XiaomiCollectorLauncher-x86_64 -output "$APP/Contents/MacOS/XiaomiCollectorLauncher"
cp com.namak1.xiaomisensor.background.plist "$APP/Contents/Library/LaunchAgents/"
cp Info.plist "$APP/Contents/Info.plist"
cp Widget-Info.plist "$EXT/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/MacOS/XiaomiCollectorLauncher"
codesign --force --sign - --entitlements Widget.entitlements "$EXT"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Xiaomi Sensor" -srcfolder build/dmg -ov -format UDZO "build/Xiaomi-Sensor.dmg"
hdiutil imageinfo "build/Xiaomi-Sensor.dmg"
