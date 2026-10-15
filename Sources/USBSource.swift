// Reads the battery over the keyboard's ZMK Studio USB serial port.
//
// Only one program should hold that port at a time, and the configurator needs it too. So this
// never keeps it open: every poll it skips the port if any other process has it open, otherwise
// opens it exclusively, sends a 'G' '1' request, waits for one battery frame and closes it.
import Darwin
import Foundation
import IOKit
import IOKit.serial

final class USBSource {
    /// ZMK's default USB IDs (the Open Source Hardware vendor ID and ZMK's product ID).
    static let zmkVendorID = 0x1D50
    static let zmkProductID = 0x615E
    static let pollInterval: TimeInterval = 60
    static let replyTimeout: TimeInterval = 1.5
    /// How long to keep reading after the first battery frame, for a fresher one behind it.
    static let settleAfterFirstReply: TimeInterval = 0.4

    private let model: BatteryModel
    private let queue = DispatchQueue(label: "zmk-battery.usb")
    private var timer: DispatchSourceTimer?

    init(model: BatteryModel) {
        self.model = model
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func pollNow() {
        queue.async { [weak self] in self?.poll() }
    }

    private func poll() {
        let ports = Self.zmkSerialPorts()
        guard !ports.isEmpty else {
            report("Not connected")
            return
        }
        for port in ports {
            if Self.otherProcessesHaveOpen(port) {
                report("In use by another app (configurator?)")
                continue
            }
            switch Self.requestSnapshot(port: port) {
            case .success(let snapshot):
                report("Connected")
                DispatchQueue.main.async { [model] in model.apply(snapshot) }
                return
            case .failure(let message):
                report(message)
            }
        }
    }

    private func report(_ status: String) {
        DispatchQueue.main.async { [model] in model.setUSBStatus(status) }
    }

    /// Callout devices (/dev/cu.*) of USB serial ports with ZMK's vendor and product IDs.
    static func zmkSerialPorts() -> [String] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let parents = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            func number(_ key: String) -> Int? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString,
                                                kCFAllocatorDefault, parents) as? Int
            }
            guard number("idVendor") == zmkVendorID, number("idProduct") == zmkProductID,
                  let path = IORegistryEntryCreateCFProperty(
                      service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? String
            else { continue }
            ports.append(path)
        }
        return ports
    }

    /// True if any process other than this one has `path` open (the same check lsof makes).
    static func otherProcessesHaveOpen(_ path: String) -> Bool {
        var pids = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, &pids,
                                      Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return false }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        let me = getpid()
        return pids.prefix(count).contains { $0 != 0 && $0 != me }
    }

    enum Outcome {
        case success(BatterySnapshot)
        case failure(String)
    }

    static func requestSnapshot(port: String, timeout: TimeInterval = replyTimeout) -> Outcome {
        let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            return .failure(errno == EBUSY ? "In use by another app (configurator?)"
                                           : "Can't open \(port): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        // Keep anyone else from opening the port during this short exchange.
        _ = ioctl(fd, TIOCEXCL)

        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &options)
        var dtr: Int32 = TIOCM_DTR
        _ = ioctl(fd, TIOCMBIS, &dtr)
        tcflush(fd, TCIOFLUSH)

        let request = Framing.batteryRequest
        guard request.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == request.count
        else { return .failure("Write to keyboard failed") }

        // The keyboard may still hold battery frames it queued before this port was last open
        // (for example from before the cable was unplugged), and they come out ahead of the
        // reply. So after the first battery frame, read a little longer and keep the last one.
        var deframer = Deframer()
        var buffer = [UInt8](repeating: 0, count: 512)
        var deadline = Date().addingTimeInterval(timeout)
        var latest: BatterySnapshot?
        while Date() < deadline {
            var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMs = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard Darwin.poll(&fds, 1, remainingMs) > 0 else { continue }
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { continue }
            for frame in deframer.feed(Array(buffer[0..<n])) {
                if let snapshot = BatterySnapshot(frame: frame) {
                    if latest == nil {
                        deadline = min(deadline, Date().addingTimeInterval(Self.settleAfterFirstReply))
                    }
                    latest = snapshot
                }
            }
        }
        if let latest { return .success(latest) }
        return .failure("No battery reply (firmware without zmk-studio-log, or Studio not on USB)")
    }
}
