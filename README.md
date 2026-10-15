# ZMK Battery

A macOS menu bar app that shows the battery of **both halves** of a ZMK split keyboard,
for example `L 78% R 15%!`, and notifies you when either half drops to 20% and 10%.

It reads the battery from whichever connection is live:

| Keyboard connected by | Source |
|---|---|
| Bluetooth to this Mac | The keyboard's Battery Services. It subscribes to updates and re-reads every 5 minutes. |
| USB | The ZMK Studio serial port: a `G` `1` request, answered with a `K` battery frame. It needs [zmk-studio-log](https://github.com/rleyvasal/zmk-studio-log) firmware that handles `G`, as Totem's does. |

Every reading shows its source and age. A reading older than 15 minutes gets a `?`, a level at
or below 20% gets a `!`, and `⚡` means the left half is on USB. A charging half's cell can't be
measured, so the number shown is its last reading on battery.

## Build and run

Needs only the Xcode command line tools.

```sh
./build.sh          # builds "build/ZMK Battery.app"
./build.sh test     # runs the unit tests
open "build/ZMK Battery.app"
```

On first launch, allow Bluetooth access and notifications. Opening the app also opens a window
with the same information, in case a crowded menu bar (or the notch) hides the item.

## Notes

- **Bluetooth** works only while the keyboard is connected to this Mac. The other half's level
  is relayed by the central half, so it also needs the split link up.
- **Which half is which** comes from each level's User Description. Upstream ZMK labels the
  peripheral's level `Peripheral 0`. The Totem fork swaps the levels for Mighty Mitts and labels
  the central's `Left`. Both layouts are handled. Devices with no described level, such as
  headphones, are ignored.
- **USB** never holds the serial port. Every minute it skips the port if another app (such as
  the configurator) has it open; otherwise it opens it for about a second.
- Logs: `log stream --predicate 'subsystem == "io.github.rleyvasal.zmk-battery"'`
