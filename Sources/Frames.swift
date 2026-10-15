// Studio raw frames and the battery snapshot line they carry.
//
// Frames use ZMK Studio's framing: SOF 0xAB, ESC 0xAC (escapes the next byte), EOF 0xAD.
// The first payload byte is the frame type:
//   'G' '1'  host -> keyboard: send a battery snapshot now
//   'K' text keyboard -> host: battery snapshot, e.g. "left=78 usb right=15"
//   'B' text keyboard -> host: the same, from Totem firmware before zmk-studio-log
import Foundation

enum Framing {
    static let sof: UInt8 = 0xAB
    static let esc: UInt8 = 0xAC
    static let eof: UInt8 = 0xAD

    static func encode(_ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [sof]
        for b in payload {
            if b == sof || b == esc || b == eof { out.append(esc) }
            out.append(b)
        }
        out.append(eof)
        return out
    }

    static let batteryRequest = encode(Array("G1".utf8))
}

/// Splits a byte stream into frame payloads. Feed it bytes as they arrive.
struct Deframer {
    private var active = false
    private var escaped = false
    private var buffer: [UInt8] = []

    mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        for b in bytes {
            if !active {
                if b == Framing.sof { active = true; escaped = false; buffer.removeAll() }
                continue
            }
            if escaped {
                buffer.append(b)
                escaped = false
            } else if b == Framing.esc {
                escaped = true
            } else if b == Framing.sof {
                buffer.removeAll()
            } else if b == Framing.eof {
                frames.append(buffer)
                active = false
            } else {
                buffer.append(b)
            }
            if buffer.count > 512 { active = false; buffer.removeAll() }
        }
        return frames
    }
}

/// One battery snapshot as the firmware reports it.
struct BatterySnapshot: Equatable {
    /// Left (central) half, in percent. While it is on USB this is the last reading taken on
    /// battery, since the cell sits at charge voltage on USB; nil if there is none yet.
    var left: Int?
    var leftOnUSB: Bool
    /// Right (peripheral) half, in percent; nil until it has reported over the split link.
    var right: Int?

    /// Parses "left=78 right=15", "left=78 usb right=--", "left=usb right=--" and so on.
    init?(line: String) {
        let tokens = line.split(separator: " ").map(String.init)
        guard let leftIndex = tokens.firstIndex(where: { $0.hasPrefix("left=") }),
              let rightToken = tokens.first(where: { $0.hasPrefix("right=") })
        else { return nil }

        let leftValue = String(tokens[leftIndex].dropFirst("left=".count))
        if leftValue == "usb" {
            left = nil
            leftOnUSB = true
        } else {
            guard let value = Int(leftValue) else { return nil }
            left = value
            leftOnUSB = tokens.count > leftIndex + 1 && tokens[leftIndex + 1] == "usb"
        }

        let rightValue = String(rightToken.dropFirst("right=".count))
        if rightValue == "--" {
            right = nil
        } else {
            guard let value = Int(rightValue) else { return nil }
            right = value
        }
    }

    init(left: Int?, leftOnUSB: Bool, right: Int?) {
        self.left = left
        self.leftOnUSB = leftOnUSB
        self.right = right
    }

    /// The snapshot in a battery frame payload ('K' or legacy 'B'), or nil for any other frame.
    init?(frame: [UInt8]) {
        guard let kind = frame.first, kind == UInt8(ascii: "K") || kind == UInt8(ascii: "B"),
              let text = String(bytes: frame.dropFirst(), encoding: .utf8)
        else { return nil }
        self.init(line: text)
    }
}
