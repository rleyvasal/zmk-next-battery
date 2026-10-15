#!/bin/sh
# Builds ZMK Battery.app into build/. Needs only the Xcode command line tools.
#   ./build.sh          build the app
#   ./build.sh test     run the unit tests
set -eu
cd "$(dirname "$0")"
FLAGS="-swift-version 5 -target arm64-apple-macos13"

if [ "${1:-}" = "test" ]; then
  mkdir -p build
  swiftc $FLAGS -o build/tests Sources/Frames.swift Sources/BatteryRoles.swift \
    Sources/BatteryModel.swift Tests/main.swift
  exec build/tests
fi

APP="build/ZMK Battery.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc $FLAGS -O -parse-as-library -o "$APP/Contents/MacOS/ZMKBattery" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: enough for Bluetooth and notification permissions on this Mac.
codesign --force --sign - "$APP"
echo "Built $APP"
