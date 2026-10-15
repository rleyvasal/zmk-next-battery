// Unit tests for the parts that need no hardware. Run with ./build.sh test.
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

// Framing round trip, including bytes that must be escaped.
let payload: [UInt8] = [UInt8(ascii: "K"), 0xAB, 0xAC, 0xAD, 0x41]
var deframer = Deframer()
check(deframer.feed(Framing.encode(payload)) == [payload], "escaped payload survives framing")
check(Framing.batteryRequest == [0xAB, 0x47, 0x31, 0xAD], "battery request is SOF 'G' '1' EOF")
// Split across reads, with noise and a Studio RPC response in between.
var split = Deframer()
let stream = [0x00, 0x13] + Framing.encode([0x0A, 0x02]) + Framing.encode(Array("Kleft=78 usb right=15".utf8))
var frames: [[UInt8]] = []
for chunk in stride(from: 0, to: stream.count, by: 3) {
    frames += split.feed(Array(stream[chunk..<min(chunk + 3, stream.count)]))
}
check(frames.count == 2, "two frames from a chunked stream, got \(frames.count)")
check(BatterySnapshot(frame: frames[0]) == nil, "an RPC response is not a battery frame")
check(BatterySnapshot(frame: frames[1]) == BatterySnapshot(left: 78, leftOnUSB: true, right: 15),
      "battery frame parses")

// Every snapshot form the firmware prints (totem_battery_log.c format_levels()).
let lines: [(String, BatterySnapshot?)] = [
    ("left=78 usb right=15", BatterySnapshot(left: 78, leftOnUSB: true, right: 15)),
    ("left=78 usb right=--", BatterySnapshot(left: 78, leftOnUSB: true, right: nil)),
    ("left=usb right=15", BatterySnapshot(left: nil, leftOnUSB: true, right: 15)),
    ("left=usb right=--", BatterySnapshot(left: nil, leftOnUSB: true, right: nil)),
    ("left=64 right=15", BatterySnapshot(left: 64, leftOnUSB: false, right: 15)),
    ("left=64 right=--", BatterySnapshot(left: 64, leftOnUSB: false, right: nil)),
    ("totem_log t=30s usb=1", nil),
    ("left=abc right=1", nil),
]
for (line, expected) in lines {
    check(BatterySnapshot(line: line) == expected, "parse \"\(line)\"")
}
check(BatterySnapshot(frame: Array("Bleft=50 right=40".utf8)) != nil, "legacy 'B' frames still parse")
check(BatterySnapshot(frame: Array("Lleft=50 right=40".utf8)) == nil, "log lines are not battery frames")

// Which half each Bluetooth battery level is.
check(BatteryRoles.half(description: "Left", siblings: [nil, "Left"]) == .left, "Totem: described Left")
check(BatteryRoles.half(description: nil, siblings: [nil, "Left"]) == .right, "Totem: plain level is right")
check(BatteryRoles.half(description: "Peripheral 0", siblings: [nil, "Peripheral 0"]) == .right,
      "upstream: Peripheral 0 is right")
check(BatteryRoles.half(description: nil, siblings: [nil, "Peripheral 0"]) == .left,
      "upstream: plain level is left")
check(BatteryRoles.half(description: nil, siblings: [nil]) == nil, "single plain level: not a split")
check(BatteryRoles.half(description: nil, siblings: [nil, "Case"]) == nil, "unknown description: undecided")

// Low-battery alerts: once per threshold, re-armed only after recovering past the hysteresis.
var alerts = LowBatteryAlerts()
check(alerts.crossed(half: .right, percent: 40, charging: false) == nil, "40%: no alert")
check(alerts.crossed(half: .right, percent: 20, charging: false) == 20, "20%: alert")
check(alerts.crossed(half: .right, percent: 19, charging: false) == nil, "19%: already alerted")
check(alerts.crossed(half: .right, percent: 21, charging: false) == nil, "21%: wobble, no alert")
check(alerts.crossed(half: .right, percent: 20, charging: false) == nil, "back to 20%: still no repeat")
check(alerts.crossed(half: .right, percent: 9, charging: false) == 10, "9%: 10% alert")
check(alerts.crossed(half: .left, percent: 15, charging: false) == 20, "halves are independent")
check(alerts.crossed(half: .right, percent: 30, charging: false) == nil, "30%: recovered, re-armed")
check(alerts.crossed(half: .right, percent: 18, charging: false) == 20, "18% after recovery: alert again")
check(alerts.crossed(half: .left, percent: 15, charging: true) == nil, "charging clears alerts")
check(alerts.crossed(half: .left, percent: 15, charging: false) == 20, "off the charger, low again: alert")
// Jumping straight past both thresholds gives one alert, the more urgent one.
var jump = LowBatteryAlerts()
check(jump.crossed(half: .right, percent: 8, charging: false) == 10, "8% from unknown: 10% alert")
check(jump.crossed(half: .right, percent: 15, charging: false) == nil, "15%: 20% already covered")

if failures == 0 { print("All tests passed") } else { print("\(failures) failure(s)"); exit(1) }
