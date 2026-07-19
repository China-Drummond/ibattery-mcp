#!/usr/bin/env bash
# Assembles ibattery-ble-helper.app from the SwiftPM-built binary + Info.plist.
# Usage: Scripts/build-ble-helper-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

swift build --product ibattery-ble-helper

BIN_PATH="$(swift build --show-bin-path)/ibattery-ble-helper"
APP_DIR=".build/ibattery-ble-helper.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/ibattery-ble-helper"
cp "Resources/ibattery-ble-helper/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign -s - --force --deep "$APP_DIR"

echo "Built $APP_DIR"
