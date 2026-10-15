// Menu bar app: both halves' battery, from USB or Bluetooth, with low-battery alerts.
//
// The menu bar item is a plain AppKit NSStatusItem. SwiftUI's MenuBarExtra with a label that
// redraws itself on a timer spins forever while creating the item on this macOS, before the app
// finishes launching. The window's content is still SwiftUI.
import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = BatteryModel()
    private lazy var usb = USBSource(model: model)
    private lazy var bluetooth = BluetoothSource(model: model)
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var changes: AnyCancellable?
    private var titleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.notice("Started")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateTitle()

        // objectWillChange fires before the change lands, so read the model on the next turn.
        changes = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        // Readings turn stale ("?") and their ages change with time alone.
        titleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.tick() }
        }

        usb.start()
        bluetooth.start()
        // Opening the app shows a window too: a crowded menu bar (or the notch) can hide the item.
        showWindow()
    }

    /// Opening the app again while it runs (Finder, Spotlight) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func updateTitle() {
        statusItem?.button?.title = model.title
    }

    // MARK: Menu

    /// Rebuilt each time it opens, so it always shows current readings and ages.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for half in Half.allCases {
            menu.addItem(info(model.line(for: half)))
        }
        if !model.rightLinked {
            menu.addItem(info("Right half isn't linked to the left half"))
        }
        menu.addItem(.separator())
        menu.addItem(info("USB: \(model.usbStatus)"))
        menu.addItem(info("Bluetooth: \(model.bluetoothStatus)"))
        menu.addItem(.separator())
        let alerts = NSMenuItem(title: "Low-battery alerts (20% and 10%)",
                                action: #selector(toggleAlerts), keyEquivalent: "")
        alerts.state = model.notificationsEnabled ? .on : .off
        alerts.target = self
        menu.addItem(alerts)
        menu.addItem(action("Refresh now", #selector(refreshFromMenu), key: "r"))
        menu.addItem(action("Show window", #selector(showWindowFromMenu), key: ""))
        menu.addItem(action("Quit", #selector(quit), key: "q"))
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleAlerts() { model.notificationsEnabled.toggle() }
    @objc private func refreshFromMenu() { refresh() }
    @objc private func showWindowFromMenu() { showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    func refresh() {
        usb.pollNow()
        bluetooth.refresh()
    }

    // MARK: Window

    func showWindow() {
        if window == nil {
            let content = BatteryPanel(model: model, refresh: { [weak self] in self?.refresh() })
                .padding(16)
                .frame(minWidth: 380)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "ZMK Battery"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The same information as the menu, in a window.
struct BatteryPanel: View {
    @ObservedObject var model: BatteryModel
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
                Text(model.title).font(.title2.monospacedDigit())
                ForEach(Half.allCases, id: \.self) { half in
                    Text(model.line(for: half))
                }
                if !model.rightLinked {
                    Text("Right half isn't linked to the left half").foregroundStyle(.orange)
                }
                Divider()
                Text("USB: \(model.usbStatus)").foregroundStyle(.secondary)
                Text("Bluetooth: \(model.bluetoothStatus)").foregroundStyle(.secondary)
                Divider()
                Toggle("Low-battery alerts (20% and 10%)", isOn: $model.notificationsEnabled)
                HStack {
                    Button("Refresh now", action: refresh)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
        }
    }
}
