#!/bin/bash
# Optional per-user fallback for Macs that reject the bundled launch agent.
set -euo pipefail
label="com.namak1.xiaomisensor.monitor"
agent="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
case "${1:-}" in
  enable)
    if [[ ! -d "/Applications/Xiaomi Sensor.app" ]]; then
      echo "Install Xiaomi Sensor in /Applications first." >&2
      exit 1
    fi
    mkdir -p "$(dirname "$agent")"
    if [[ ! -e "$agent" ]]; then
      cat > "$agent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.namak1.xiaomisensor.monitor</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>/usr/bin/pgrep -x XiaomiSensor &gt;/dev/null || /usr/bin/open -g -a '/Applications/Xiaomi Sensor.app' --args --background</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
</dict></plist>
PLIST
    fi
    if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl bootstrap "$domain" "$agent"
    fi
    echo "Background monitor enabled. It will restart the app when it is not running."
    ;;
  disable)
    if [[ -e "$agent" ]]; then
      if launchctl print "$domain/$label" >/dev/null 2>&1; then
        launchctl bootout "$domain" "$agent"
      fi
      rm "$agent"
      echo "Background monitor disabled. Quit the app to stop monitoring."
    else
      echo "Background monitor is not installed."
    fi
    ;;
  *) echo "Usage: bash scripts/background-monitor.sh {enable|disable}" >&2; exit 2 ;;
esac
