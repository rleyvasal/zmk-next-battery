// Reads the battery over Bluetooth while the keyboard is connected to this Mac.
//
// A ZMK split central with CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_PROXY publishes two
// Battery Services (0x180F): one plain level and one whose level carries a User Description.
// Which half is which depends on the firmware (see BatteryRoles), so levels are only shown once
// every description on the device has been read. A device with no described level is not a
// split keyboard (headphones, mice) and is ignored. The keyboard is already connected to macOS
// as a keyboard, so it is found among connected peripherals rather than by scanning. Levels are
// subscribed to, not polled, and re-read every few minutes in case a notification is missed.
// A Battery Level Status (0x2BED) in the same service says whether that level's half is charging.
import CoreBluetooth
import Foundation

final class BluetoothSource: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let batteryService = CBUUID(string: "180F")
    static let hidService = CBUUID(string: "1812")
    static let batteryLevel = CBUUID(string: "2A19")
    static let batteryLevelStatus = CBUUID(string: "2BED")
    static let userDescription = CBUUID(string: "2901")
    static let rescanInterval: TimeInterval = 30
    static let rereadInterval: TimeInterval = 5 * 60
    /// A connect still pending after this long is cancelled and started again.
    static let connectRetryAfter: TimeInterval = 20

    private let model: BatteryModel
    private var central: CBCentralManager!
    private var keyboards: [UUID: CBPeripheral] = [:]
    /// When each keyboard's latest connect was started.
    private var connectStarted: [UUID: Date] = [:]
    /// Each battery level's User Description once known; .some(nil) means it has none.
    private var descriptions: [ObjectIdentifier: String?] = [:]
    /// Latest value of each battery level, kept until its half can be decided.
    private var levels: [ObjectIdentifier: UInt8] = [:]
    /// Charging state of each battery level, from the Battery Level Status in its service.
    private var charging: [ObjectIdentifier: Bool] = [:]
    private var rescanTimer: Timer?
    private var rereadTimer: Timer?

    init(model: BatteryModel) {
        self.model = model
        super.init()
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
        rescanTimer = Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) {
            [weak self] _ in self?.findConnectedKeyboards()
        }
        rereadTimer = Timer.scheduledTimer(withTimeInterval: Self.rereadInterval, repeats: true) {
            [weak self] _ in self?.rereadAll()
        }
    }

    func refresh() {
        findConnectedKeyboards()
        rereadAll()
    }

    // MARK: Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.notice("Bluetooth: state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            findConnectedKeyboards()
        case .unauthorized:
            setStatus("Bluetooth permission denied (System Settings → Privacy & Security → Bluetooth)")
        case .poweredOff:
            setStatus("Bluetooth is off")
        default:
            setStatus("Bluetooth unavailable")
        }
    }

    private func findConnectedKeyboards() {
        guard central?.state == .poweredOn else { return }
        // Prefer devices that are Bluetooth keyboards (HID service) and report a battery. If macOS
        // hides HID from this query, fall back to every battery device; publish() still drops
        // any device without a described level, such as most headphones.
        let withBattery = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        let hid = Set(central.retrieveConnectedPeripherals(withServices: [Self.hidService])
            .map(\.identifier))
        let candidates = hid.isEmpty ? withBattery : withBattery.filter { hid.contains($0.identifier) }
        log.notice("Bluetooth: \(withBattery.count) connected with battery \(withBattery.map { $0.name ?? "?" }, privacy: .public), \(hid.count) HID, \(candidates.count) candidates")
        let now = Date()
        for peripheral in candidates {
            if let known = keyboards[peripheral.identifier] {
                // A connect started while the link couldn't encrypt (the keyboard on USB, or
                // serving another profile) can stay pending after macOS reconnects it, and the
                // levels are never read. Cancel one still not connected after a while; the next
                // scan connects afresh. (Cancelling calls didDisconnect, which forgets it.)
                if known.state != .connected,
                   now.timeIntervalSince(connectStarted[peripheral.identifier] ?? .distantPast)
                       >= Self.connectRetryAfter {
                    log.notice("Bluetooth: retrying connect to \(peripheral.name ?? "?", privacy: .public) (state \(known.state.rawValue))")
                    keyboards[peripheral.identifier] = nil
                    central.cancelPeripheralConnection(known)
                }
                continue
            }
            keyboards[peripheral.identifier] = peripheral
            peripheral.delegate = self
            connectStarted[peripheral.identifier] = now
            central.connect(peripheral)
        }
        if keyboards.isEmpty {
            setStatus("Not connected to this Mac")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.notice("Bluetooth: reading batteries on \(peripheral.name ?? "?", privacy: .public)")
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        forget(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log.notice("Bluetooth: connect failed \(peripheral.name ?? "?", privacy: .public) \(String(describing: error), privacy: .public)")
        forget(peripheral)
    }

    private func forget(_ peripheral: CBPeripheral) {
        keyboards[peripheral.identifier] = nil
        for characteristic in batteryLevels(of: peripheral) {
            descriptions[ObjectIdentifier(characteristic)] = nil
            levels[ObjectIdentifier(characteristic)] = nil
            charging[ObjectIdentifier(characteristic)] = nil
        }
        if keyboards.isEmpty { setStatus("Not connected to this Mac") }
    }

    private func batteryLevels(of peripheral: CBPeripheral) -> [CBCharacteristic] {
        (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
            .filter { $0.uuid == Self.batteryLevel }
    }

    private func batteryStatuses(of peripheral: CBPeripheral) -> [CBCharacteristic] {
        (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
            .filter { $0.uuid == Self.batteryLevelStatus }
    }

    private func rereadAll() {
        for peripheral in keyboards.values where peripheral.state == .connected {
            for characteristic in batteryLevels(of: peripheral) + batteryStatuses(of: peripheral) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    // MARK: Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log.notice("Bluetooth: \(peripheral.services?.count ?? 0) battery services on \(peripheral.name ?? "?", privacy: .public) error=\(String(describing: error), privacy: .public)")
        for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel, Self.batteryLevelStatus], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.batteryLevel {
                peripheral.discoverDescriptors(for: characteristic)
            } else if characteristic.uuid == Self.batteryLevelStatus {
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let description = characteristic.descriptors?.first(where: { $0.uuid == Self.userDescription }) {
            peripheral.readValue(for: description)
        } else {
            described(characteristic, as: nil, on: peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard descriptor.uuid == Self.userDescription, let characteristic = descriptor.characteristic
        else { return }
        let text: String?
        if let string = descriptor.value as? String {
            text = string
        } else if let data = descriptor.value as? Data {
            text = String(data: data, encoding: .utf8)
        } else {
            text = nil
        }
        log.notice("Bluetooth: level description \(text ?? "?", privacy: .public) on \(peripheral.name ?? "?", privacy: .public)")
        described(characteristic, as: text ?? "", on: peripheral)
    }

    private func described(_ characteristic: CBCharacteristic, as text: String?, on peripheral: CBPeripheral) {
        descriptions[ObjectIdentifier(characteristic)] = .some(text)
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == Self.batteryLevelStatus {
            guard error == nil, let value = characteristic.value,
                  let level = characteristic.service?.characteristics?
                      .first(where: { $0.uuid == Self.batteryLevel })
            else { return }
            let state = BatteryLevelStatus.charging(Array(value))
            log.notice("Bluetooth: level status charging=\(String(describing: state), privacy: .public)")
            charging[ObjectIdentifier(level)] = state
            publish(peripheral)
            return
        }
        guard error == nil, characteristic.uuid == Self.batteryLevel,
              let byte = characteristic.value?.first
        else {
            log.notice("Bluetooth: level read failed error=\(String(describing: error), privacy: .public)")
            return
        }
        levels[ObjectIdentifier(characteristic)] = byte
        publish(peripheral)
    }

    /// Shows every level on `peripheral` whose half can be decided, once all descriptions are in.
    private func publish(_ peripheral: CBPeripheral) {
        let characteristics = batteryLevels(of: peripheral)
        var known: [String?] = []
        for characteristic in characteristics {
            guard let description = descriptions[ObjectIdentifier(characteristic)] else { return }
            known.append(description)
        }
        var shown = false
        for (characteristic, description) in zip(characteristics, known) {
            guard let half = BatteryRoles.half(description: description, siblings: known),
                  let level = levels[ObjectIdentifier(characteristic)]
            else { continue }
            shown = true
            let isCharging = charging[ObjectIdentifier(characteristic)] ?? false
            DispatchQueue.main.async { [model] in
                model.update(half, percent: Int(level), charging: isCharging, source: .bluetooth)
            }
        }
        if shown { setStatus("Connected to \(peripheral.name ?? "keyboard")") }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [model] in model.setBluetoothStatus(text) }
    }
}
