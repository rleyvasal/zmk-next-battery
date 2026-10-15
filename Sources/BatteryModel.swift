// What the menu shows: each half's last reading, where it came from and how old it is,
// plus low-battery notifications.
import Foundation
import os
import UserNotifications

/// Readable with: log stream --predicate 'subsystem == "io.github.rleyvasal.zmk-battery"'
let log = Logger(subsystem: "io.github.rleyvasal.zmk-battery", category: "battery")

enum Half: String, CaseIterable {
    case left = "Left"
    case right = "Right"
}

enum Source: String {
    case usb = "USB"
    case bluetooth = "Bluetooth"
}

struct Reading: Equatable {
    var percent: Int
    /// The left half is on USB: the percent is its last reading on battery, and it is charging.
    var charging: Bool
    var source: Source
    var updated: Date
}

/// Pure bookkeeping for low-battery alerts, kept apart from UserNotifications so it can be tested.
struct LowBatteryAlerts {
    static let thresholds = [20, 10]
    /// Re-arm a threshold once the level is this far above it again, so a reading that
    /// wobbles around 20% doesn't notify over and over.
    static let hysteresis = 5

    private var fired: [Half: Set<Int>] = [:]

    /// The lowest threshold this new level crosses for the first time, if any. One alert covers
    /// a jump past several thresholds at once.
    mutating func crossed(half: Half, percent: Int, charging: Bool) -> Int? {
        var done = fired[half, default: []]
        if charging {
            done.removeAll()
            fired[half] = done
            return nil
        }
        done = done.filter { percent <= $0 + Self.hysteresis }
        let newlyCrossed = Self.thresholds.filter { percent <= $0 && !done.contains($0) }
        done.formUnion(newlyCrossed)
        fired[half] = done
        return newlyCrossed.min()
    }
}

@MainActor
final class BatteryModel: ObservableObject {
    /// Older than this, a reading is shown as stale rather than current.
    static let staleAfter: TimeInterval = 15 * 60

    @Published private(set) var readings: [Half: Reading] = [:]
    /// False when the latest report says the right half hasn't reported over the split link.
    @Published private(set) var rightLinked = true
    @Published private(set) var usbStatus = "Not connected"
    @Published private(set) var bluetoothStatus = "Not connected"
    @Published var notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    private var alerts = LowBatteryAlerts()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func update(_ half: Half, percent: Int, charging: Bool, source: Source) {
        let reading = Reading(percent: max(0, min(100, percent)), charging: charging,
                              source: source, updated: Date())
        readings[half] = reading
        log.notice("\(half.rawValue, privacy: .public) \(reading.percent)% charging=\(charging) via \(source.rawValue, privacy: .public)")
        if half == .right { rightLinked = true }
        if let threshold = alerts.crossed(half: half, percent: reading.percent, charging: charging) {
            notifyLow(half: half, percent: reading.percent, threshold: threshold)
        }
    }

    func apply(_ snapshot: BatterySnapshot) {
        if let left = snapshot.left {
            update(.left, percent: left, charging: snapshot.leftOnUSB, source: .usb)
        } else if snapshot.leftOnUSB, var existing = readings[.left] {
            // On USB with no battery reading yet: keep the old number, but mark it charging.
            existing.charging = true
            readings[.left] = existing
        }
        if let right = snapshot.right {
            update(.right, percent: right, charging: false, source: .usb)
        } else {
            rightLinked = false
        }
    }

    /// Redraws everything that shows a reading's age or staleness.
    func tick() { objectWillChange.send() }

    func setUSBStatus(_ text: String) {
        if text != usbStatus { log.notice("USB: \(text, privacy: .public)") }
        usbStatus = text
    }

    func setBluetoothStatus(_ text: String) {
        if text != bluetoothStatus { log.notice("Bluetooth: \(text, privacy: .public)") }
        bluetoothStatus = text
    }

    /// One line per half for the menu and window, e.g. "Right: 15% · USB, 2 min ago".
    func line(for half: Half) -> String {
        guard let reading = readings[half] else { return "\(half.rawValue): no reading yet" }
        var text = "\(half.rawValue): \(reading.percent)%"
        if reading.charging { text += " (charging; last reading on battery)" }
        let age = RelativeDateTimeFormatter().localizedString(for: reading.updated, relativeTo: Date())
        text += " · \(reading.source.rawValue), \(age)"
        if isStale(reading) { text += " · stale" }
        return text
    }

    func isStale(_ reading: Reading, now: Date = Date()) -> Bool {
        now.timeIntervalSince(reading.updated) > Self.staleAfter
    }

    /// Compact menu bar text, e.g. "L 78%⚡ R 15%!". A trailing "?" marks a stale reading.
    var title: String {
        func part(_ half: Half, _ letter: String) -> String {
            guard let r = readings[half] else { return "\(letter) --" }
            var text = "\(letter) \(r.percent)%"
            if r.charging { text += "⚡" }
            if isStale(r) {
                text += "?"
            } else if !r.charging && r.percent <= LowBatteryAlerts.thresholds[0] {
                text += "!"
            }
            return text
        }
        return "\(part(.left, "L")) \(part(.right, "R"))"
    }

    private func notifyLow(half: Half, percent: Int, threshold: Int) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(half.rawValue) half at \(percent)%"
        content.body = threshold <= 10
            ? "Charge the \(half.rawValue.lowercased()) half soon; it may drop the split link."
            : "The \(half.rawValue.lowercased()) half of your keyboard is getting low."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-\(half.rawValue)-\(threshold)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
