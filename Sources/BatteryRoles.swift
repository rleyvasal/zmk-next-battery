// Which half a Battery Level belongs to, from its User Description and its siblings'.
//
// Two layouts are in use on ZMK splits with the battery level proxy:
//   upstream ZMK:  plain level = central (left), described "Peripheral 0" = right
//   Totem fork:    plain level = right,          described "Left"         = central (left)
// (the fork swaps them so Mighty Mitts, which fills its slots in callback order, shows them in
// the right places). A plain level is therefore the other half from its described sibling.
enum BatteryRoles {
    /// The half named by a description, or nil if it names neither.
    static func named(_ description: String) -> Half? {
        let text = description.lowercased()
        if text.contains("left") || text.contains("central") { return .left }
        if text.contains("right") || text.contains("peripheral") { return .right }
        return nil
    }

    /// The half for a level with `description` (nil = no User Description), given every level's
    /// description on the same device. Nil when it can't be decided, e.g. a device whose levels
    /// have no description at all, which is not a split keyboard.
    static func half(description: String?, siblings: [String?]) -> Half? {
        if let description { return named(description) }
        let namedHalves = siblings.compactMap { $0 }.compactMap(named)
        if namedHalves.contains(.left) && !namedHalves.contains(.right) { return .right }
        if namedHalves.contains(.right) && !namedHalves.contains(.left) { return .left }
        return nil
    }
}

/// Battery Level Status (0x2BED): a flags byte, then a little-endian Power State whose bits 5-6
/// are the Battery Charge State (0 unknown, 1 charging, 2 and 3 discharging). It belongs to the
/// Battery Level in the same Battery Service. On the Totem fork that is the plain level (right).
enum BatteryLevelStatus {
    /// True while charging, false while discharging, nil if unknown or malformed.
    static func charging(_ value: [UInt8]) -> Bool? {
        guard value.count >= 3 else { return nil }
        let powerState = UInt16(value[1]) | UInt16(value[2]) << 8
        switch (powerState >> 5) & 0x3 {
        case 1: return true
        case 2, 3: return false
        default: return nil
        }
    }
}
