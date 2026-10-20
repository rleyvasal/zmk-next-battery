#!/bin/sh
# Builds ZMK Battery.app into build/. Needs only the Xcode command line tools.
#   ./build.sh                  build the app for this Mac
#   ./build.sh test             run the unit tests
#   ./build.sh release 0.2.0    universal (Apple silicon + Intel) app, zipped
#                               as build/ZMK-Battery-0.2.0.zip
set -eu
cd "$(dirname "$0")"
FLAGS="-swift-version 5"
ARCH="$(uname -m)"

if [ "${1:-}" = "test" ]; then
  mkdir -p build
  swiftc $FLAGS -target "$ARCH-apple-macos13" -o build/tests Sources/Frames.swift \
    Sources/BatteryRoles.swift Sources/BatteryModel.swift Tests/main.swift
  exec build/tests
fi

APP="build/ZMK Battery.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/ZMKBattery"

if [ "${1:-}" = "release" ]; then
  VERSION="${2:?usage: ./build.sh release <version>}"
  for a in arm64 x86_64; do
    swiftc $FLAGS -target "$a-apple-macos13" -O -parse-as-library -o "build/ZMKBattery-$a" Sources/*.swift
  done
  lipo -create -output "$BIN" build/ZMKBattery-arm64 build/ZMKBattery-x86_64
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
else
  swiftc $FLAGS -target "$ARCH-apple-macos13" -O -parse-as-library -o "$BIN" Sources/*.swift
fi

# Ad-hoc signature: enough for Bluetooth and notification permissions. It is
# not a Developer ID signature, so a downloaded copy needs "Open Anyway" once.
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "release" ]; then
  ZIP="build/ZMK-Battery-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packaged $ZIP"
fi
