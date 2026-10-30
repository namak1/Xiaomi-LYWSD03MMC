# Xiaomi Sensor for macOS

A native macOS monitor for the Xiaomi LYWSD03MMC Bluetooth thermometer and hygrometer. It shows temperature, humidity, battery voltage, last update time, connection status, and a floating widget. Select a nearby sensor once; the app remembers it and attempts to reconnect.

## Download and install

Download the DMG from the latest successful **Build macOS DMG** run under [Actions](../../actions) (GitHub sign-in may be required). Open the downloaded artifact ZIP, open the DMG and drag Xiaomi Sensor to Applications. On first launch, allow Bluetooth access. This build is not notarized by Apple; macOS may block it. Use System Settings → Privacy & Security → Open Anyway if offered.

Requires macOS 12 or later and Bluetooth. Apple silicon and Intel are supported. Launch the app, wait for the sensor to appear, click Connect, then choose Floating widget. Keep the app running for live readings. Drag the widget by its title bar; close it or use the button to hide it.

## Compatibility

This version targets the original Xiaomi firmware's EBE0CCC1 characteristic and reads its notification containing temperature, humidity and voltage. It does not decrypt Xiaomi advertisements or support Zigbee and custom firmware formats. Some firmware or hardware revisions may behave differently, require pairing, or not expose this characteristic. Disconnect other apps or gateways if they already hold the sensor's connection. Readings can take time to arrive. If Bluetooth access was denied, allow it in System Settings → Privacy & Security → Bluetooth, then restart the app. No sensor firmware is modified.

Protocol references: [MiTemperature2](https://github.com/JsBergbau/MiTemperature2/blob/master/LYWSD03MMC.py), [lywsd03mmc-client](https://github.com/keks51/lywsd03mmc-client).

## Build

On a Mac with Xcode command line tools: `bash scripts/build.sh`. The resulting disk image is at `build/Xiaomi-Sensor.dmg`. Builds are ad-hoc signed and not notarized. No server or cloud account is used.
