# ZMK Battery

A macOS menu bar app that shows the battery of **both halves** of a ZMK split keyboard,
for example `L 78% R 15%!`, and notifies you when either half drops to 20% and 10%.

It reads the battery from whichever connection is live:

| Keyboard connected by | Source |
|---|---|
| Bluetooth to this Mac | The keyboard's Battery Services. It subscribes to updates and re-reads every 5 minutes. |
| USB | The ZMK Studio serial port: a `G` `1` request, answered with a `K` battery frame. It needs [ZMK Next](https://github.com/rleyvasal/zmk-next) firmware with the [zmk-studio-log](https://github.com/rleyvasal/zmk-studio-log) module, as in ZMK Next's quick start. |

Every reading shows its source and age. A reading older than 15 minutes gets a `?`, a level at
or below 20% gets a `!`, and `⚡` means that half is on USB. A charging half's cell can't be
measured, so the number shown is its last reading on battery.

The right half's charging state needs ZMK Next firmware with `CONFIG_ZMK_BATTERY_CHARGE_STATUS`
on both halves. The right half
publishes a Battery Level Status (0x2BED), and the left half relays it: `right=NN usb` in the `K`
frame, and a 0x2BED next to the right half's level in its Bluetooth Battery Service.

## Install

Download `ZMK-Battery-<version>.zip` from the
[Releases page](https://github.com/rleyvasal/zmk-next-battery/releases), unzip it and move
**ZMK Battery.app** to Applications. It runs on macOS 13 or later, on Apple silicon and Intel.

The app is signed ad hoc, not notarized by Apple, so macOS blocks the first launch. Open
**System Settings › Privacy & Security** and click **Open Anyway**.

## Build and run

Needs only the Xcode command line tools.

```sh
./build.sh          # builds "build/ZMK Battery.app"
./build.sh test     # runs the unit tests
./build.sh release 0.2.0   # universal app, zipped as build/ZMK-Battery-0.2.0.zip
open "build/ZMK Battery.app"
```

On first launch, allow Bluetooth access and notifications. Opening the app also opens a window
with the same information, in case a crowded menu bar (or the notch) hides the item.

## Releases

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`: tests, a universal build, and a
GitHub release with the zip attached. Bump `CFBundleShortVersionString` in `Info.plist` to match.

## Notes

- **Bluetooth** works only while the keyboard is connected to this Mac. The other half's level
  is relayed by the central half, so it also needs the split link up.
- **Which half is which** comes from each level's User Description. Upstream ZMK labels the
  peripheral's level `Peripheral 0`. ZMK Next's `CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_PROXY_SWAP`,
  which the Totem uses for Mighty Mitts, swaps the levels and labels the central's `Left`. Both layouts are handled. Devices with no described level, such as
  headphones, are ignored.
- **USB** never holds the serial port. Every 10 seconds it skips the port if another app (such as
  the configurator) has it open; otherwise it opens it for about a second.
- Logs: `log stream --predicate 'subsystem == "io.github.rleyvasal.zmk-battery"'`
