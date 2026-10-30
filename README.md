# Xiaomi Sensor for macOS

A native Bluetooth monitor for Xiaomi LYWSD03MMC, with a macOS desktop widget. Requires macOS 14 Sonoma or newer. The app supports Apple silicon and Intel.

## Installation

Download the DMG from [Releases](../../releases), open it and drag Xiaomi Sensor into Applications. Open the app and grant Bluetooth access, then select your nearby sensor. To add the widget, right-click the desktop, choose **Edit Widgets**, search for **Xiaomi Sensor** and add it. Keep the app running to collect readings.

The widget displays the last recorded reading and its age. WidgetKit controls refreshes, so the widget is not continuously live. Desktop widget registration and Bluetooth connection have not been verified on physical hardware. The ad-hoc signed build is not notarized; macOS may require **System Settings → Privacy & Security → Open Anyway**. The app writes its snapshot to the widget extension's local container; access can be restricted by macOS privacy settings.

## Compatibility

Targets the original Xiaomi firmware's EBE0CCC1 measurement notifications. It does not decrypt Xiaomi advertisements or support Zigbee and custom firmware formats. Some hardware or firmware versions may require pairing or lack the characteristic. Disconnect other clients if they hold the Bluetooth connection.

Protocol references: [MiTemperature2](https://github.com/JsBergbau/MiTemperature2/blob/master/LYWSD03MMC.py), [lywsd03mmc-client](https://github.com/keks51/lywsd03mmc-client).

## Build

On a Mac with Xcode command line tools, run `bash scripts/build.sh`. The DMG is created at `build/Xiaomi-Sensor.dmg`. The app and extension are ad-hoc signed and not notarized.
